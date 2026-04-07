pub mod db;
pub mod proto;
pub mod scanner;
pub mod service;
pub mod types;

pub use proto::store::v1::{FileInfo, MethodEnum, QueryRequest, QueryResponse};
pub use service::{StoreClients, StoreServiceClient};

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use directories::ProjectDirs;
use tokio::sync::Mutex;

use db::Database;
use scanner::scan_to_sender;
use service::{StoreServer, socket_path, spawn_server};

/// Returns (and creates) the platform-appropriate app data directory.
///
/// | Platform | Example path                                        |
/// |----------|-----------------------------------------------------|
/// | macOS    | `~/Library/Application Support/io.oops418.anything` |
/// | Linux    | `~/.local/share/anything`                           |
/// | Windows  | `%APPDATA%\oops418\anything\data`                   |
pub fn data_dir() -> Result<PathBuf> {
    let dirs = ProjectDirs::from("io", "oops418", "anything")
        .ok_or_else(|| anyhow::anyhow!("cannot determine app data directory"))?;
    let dir = dirs.data_local_dir().to_path_buf();
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Expand a leading `~/` or bare `~` to the user's home directory.
fn expand_tilde(s: &str) -> PathBuf {
    if s == "~" {
        return PathBuf::from(std::env::var("HOME").unwrap_or_default());
    }
    if let Some(rest) = s.strip_prefix("~/") {
        let home = std::env::var("HOME").unwrap_or_default();
        return PathBuf::from(format!("{home}/{rest}"));
    }
    PathBuf::from(s)
}

/// Scan `monitored_paths` (default: `/`), skip paths listed in the config
/// `exclude` field, populate DuckDB, then spawn the UDS-backed ConnectRPC
/// server. Returns client handles for the UI and monitor crates.
pub async fn start(monitored_paths: Vec<PathBuf>) -> Result<StoreClients> {
    let db_path = data_dir()?.join("store.db");
    println!("[store] database at {}", db_path.display());

    let db = Arc::new(Mutex::new(Database::open(&db_path)?));

    // ── establish UDS connection before other services begin ──────────────────
    //
    // Bind the socket and start accepting connections immediately after the
    // database is opened, so the RPC server is reachable during (and after)
    // the initial scan phase. The server and scan share the same
    // Arc<Mutex<Database>>; callers that connect early will wait on the
    // async mutex until the scan releases it.
    let socket_path = socket_path()?;
    println!("[store] rpc socket at {}", socket_path.display());
    let clients = spawn_server(StoreServer::new(Arc::clone(&db)), socket_path).await?;

    // ── initial scan (skipped if already indexed) ─────────────────────────────
    //
    // The db lock is held only for brief bookkeeping windows; the long
    // filesystem scan + CSV write runs with no lock held so that the RPC
    // server can serve getconfig (and reject searches) concurrently.

    // ── lock window 1: check state, collect config, mark indexing start ───────
    let needs_scan = {
        let db_guard = db.lock().await;
        if db_guard.is_indexed()? {
            println!("[store] already indexed, skipping scan");
            false
        } else {
            db_guard.set_indexing(true)?;
            true
        }
    };

    if needs_scan {
        let exclude: Vec<PathBuf> = {
            let db_guard = db.lock().await;
            db_guard
                .get_exclude_paths()?
                .iter()
                .map(|s| expand_tilde(s))
                .collect()
        };

        if !exclude.is_empty() {
            println!("[store] excluding: {:?}", exclude);
        }

        // ── phase 1: scan + CSV write — lock-free ────────────────────────────
        //
        // The scanner reads filesystem metadata (random disk reads) while the
        // writer appends CSV lines (sequential disk write to a staging file).
        // The db mutex is NOT held here, so getconfig remains responsive and
        // querydb can return a "indexing in progress" error immediately.
        let csv_path = data_dir()?.join("files_staging.csv");
        let (tx, rx) = std::sync::mpsc::sync_channel::<types::FileEntry>(50_000);

        let roots = monitored_paths.clone();
        let exclude_clone = exclude.clone();
        let total_start = std::time::Instant::now();

        // Scanner runs on a dedicated OS thread.
        let scanner = std::thread::spawn(move || {
            for root in &roots {
                println!("[store] scanning {}", root.display());
                match scan_to_sender(&root, &exclude_clone, &tx) {
                    Ok(n) => println!("[store]   {} files found in {}", n, root.display()),
                    Err(e) => eprintln!("[store] scan error for {}: {e}", root.display()),
                }
            }
            // tx drops here, closing the channel
        });

        // CSV writer: sequential append, 8 MB write buffer.
        let csv_file = std::fs::File::create(&csv_path)?;
        let mut w = std::io::BufWriter::with_capacity(8 * 1024 * 1024, csv_file);
        let mut count = 0usize;

        for entry in rx {
            write_csv_row(&mut w, &entry)?;
            count += 1;
            if count % 10_000 == 0 {
                println!("[store] written {} files...", count);
            }
        }
        w.flush()?;
        drop(w); // close file before DuckDB reads it

        scanner.join().ok();
        let phase1_elapsed = total_start.elapsed();

        // ── lock window 2: DuckDB import + finalise ──────────────────────────
        //
        // DuckDB's bulk CSV reader is orders of magnitude faster than
        // row-by-row appending because it processes data in columnar batches.
        let db_guard = db.lock().await;
        if count > 0 {
            println!(
                "[store] scan+csv in {:.2}s — importing {} files into DuckDB...",
                phase1_elapsed.as_secs_f64(),
                count,
            );
            let import_start = std::time::Instant::now();
            db_guard.import_from_csv(&csv_path)?;
            db_guard.mark_indexed(count)?;
            std::fs::remove_file(&csv_path).ok();
            println!(
                "[store] indexing complete — {} files in {:.2}s (scan+csv {:.2}s + import {:.2}s)",
                count,
                total_start.elapsed().as_secs_f64(),
                phase1_elapsed.as_secs_f64(),
                import_start.elapsed().as_secs_f64(),
            );
        }
        db_guard.set_indexing(false)?;
    }

    Ok(clients)
}

/// Write one CSV row. Fields containing `"`, `,`, or newlines are quoted.
fn write_csv_row(w: &mut impl std::io::Write, e: &types::FileEntry) -> std::io::Result<()> {
    write_csv_field(w, &e.name)?;
    w.write_all(b",")?;
    write_csv_field(w, &e.path)?;
    write!(w, ",{},", e.size)?;
    write_csv_field(w, &e.create_time)?;
    w.write_all(b",")?;
    write_csv_field(w, &e.change_time)?;
    w.write_all(b"\n")
}

fn write_csv_field(w: &mut impl std::io::Write, s: &str) -> std::io::Result<()> {
    if s.contains(['"', ',', '\n', '\r']) {
        w.write_all(b"\"")?;
        for b in s.bytes() {
            if b == b'"' {
                w.write_all(b"\"\"")?;
            } else {
                w.write_all(&[b])?;
            }
        }
        w.write_all(b"\"")
    } else {
        w.write_all(s.as_bytes())
    }
}
