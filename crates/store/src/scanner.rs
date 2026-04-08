use anyhow::Result;
use jwalk::WalkDir;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc::SyncSender};
use std::time::UNIX_EPOCH;

use crate::types::FileEntry;

#[cfg(unix)]
type InodeKey = (u64, u64);
#[cfg(not(unix))]
type InodeKey = ();

/// Walk `root` recursively, skipping any path that starts with an entry in
/// `exclude`.  Excluded directories are pruned before jwalk recurses into
/// them, so they are never traversed at all.
pub fn scan_directory(root: &Path, exclude: &[PathBuf]) -> Result<Vec<FileEntry>> {
    let exclude = Arc::new(exclude.to_vec());
    let seen_inodes = Arc::new(Mutex::new(HashSet::new()));

    let walker = WalkDir::new(root).process_read_dir(move |_, _, _, children| {
        children.retain(|entry_result| {
            entry_result
                .as_ref()
                .map(|e| !exclude.iter().any(|excl| e.path().starts_with(excl)))
                .unwrap_or(true) // keep on read error; let the main loop handle it
        });
    });

    let mut entries = Vec::new();
    const LOG_INTERVAL: usize = 10_000;

    for result in walker {
        let entry = match result {
            Ok(e) => e,
            Err(_) => continue,
        };

        let Some(file_entry) = build_file_entry(&entry, &seen_inodes) else {
            continue;
        };

        entries.push(file_entry);

        if entries.len() % LOG_INTERVAL == 0 {
            println!("[store] indexing... {} files", entries.len());
        }
    }

    Ok(entries)
}

/// Walk `root` and send each `FileEntry` through `tx` as it is discovered.
/// Returns the number of entries sent.  Stops early if the receiver is dropped.
pub fn scan_to_sender(
    root: &Path,
    exclude: &[PathBuf],
    tx: &SyncSender<FileEntry>,
) -> Result<usize> {
    let exclude = Arc::new(exclude.to_vec());
    let seen_inodes = Arc::new(Mutex::new(HashSet::new()));

    let walker = WalkDir::new(root).process_read_dir(move |_, _, _, children| {
        children.retain(|entry_result| {
            entry_result
                .as_ref()
                .map(|e| !exclude.iter().any(|excl| e.path().starts_with(excl)))
                .unwrap_or(true)
        });
    });

    let mut count = 0usize;

    for result in walker {
        let entry = match result {
            Ok(e) => e,
            Err(_) => continue,
        };

        let Some(file_entry) = build_file_entry(&entry, &seen_inodes) else {
            continue;
        };

        if tx.send(file_entry).is_err() {
            break; // writer dropped, stop early
        }
        count += 1;
    }

    Ok(count)
}

fn build_file_entry(
    entry: &jwalk::DirEntry<((), ())>,
    seen_inodes: &Arc<Mutex<HashSet<InodeKey>>>,
) -> Option<FileEntry> {
    let file_type = entry.file_type();

    if file_type.is_symlink() || !file_type.is_file() {
        return None;
    }

    let path = entry.path();
    let metadata = entry.metadata().ok()?;

    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    let secs = |t: std::time::SystemTime| -> String {
        t.duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs().to_string())
            .unwrap_or_default()
    };

    Some(FileEntry {
        name,
        path: path.to_string_lossy().into_owned(),
        size: effective_size(&metadata, seen_inodes),
        create_time: metadata.created().map(secs).unwrap_or_default(),
        change_time: metadata.modified().map(secs).unwrap_or_default(),
    })
}

#[cfg(unix)]
fn effective_size(
    metadata: &std::fs::Metadata,
    seen_inodes: &Arc<Mutex<HashSet<InodeKey>>>,
) -> u64 {
    let key = (metadata.dev(), metadata.ino());
    let mut seen = seen_inodes.lock().unwrap_or_else(|poisoned| poisoned.into_inner());

    if seen.insert(key) {
        allocated_size(metadata)
    } else {
        0
    }
}

#[cfg(unix)]
fn allocated_size(metadata: &std::fs::Metadata) -> u64 {
    metadata.blocks().saturating_mul(512)
}

#[cfg(not(unix))]
fn effective_size(
    metadata: &std::fs::Metadata,
    _seen_inodes: &Arc<Mutex<HashSet<InodeKey>>>,
) -> u64 {
    metadata.len()
}
