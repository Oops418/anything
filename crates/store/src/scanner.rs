use anyhow::Result;
use jwalk::WalkDir;
use std::path::{Path, PathBuf};
use std::sync::{mpsc::SyncSender, Arc};
use std::time::UNIX_EPOCH;

use crate::types::FileEntry;

/// Walk `root` recursively, skipping any path that starts with an entry in
/// `exclude`.  Excluded directories are pruned before jwalk recurses into
/// them, so they are never traversed at all.
pub fn scan_directory(root: &Path, exclude: &[PathBuf]) -> Result<Vec<FileEntry>> {
    let exclude = Arc::new(exclude.to_vec());

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

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

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

        entries.push(FileEntry {
            name,
            path: path.to_string_lossy().into_owned(),
            size: metadata.len(),
            create_time: metadata.created().map(secs).unwrap_or_default(),
            change_time: metadata.modified().map(secs).unwrap_or_default(),
        });

        if entries.len() % LOG_INTERVAL == 0 {
            println!("[store] indexing... {} files", entries.len());
        }
    }

    Ok(entries)
}

/// Walk `root` and send each `FileEntry` through `tx` as it is discovered.
/// Returns the number of entries sent.  Stops early if the receiver is dropped.
pub fn scan_to_sender(root: &Path, exclude: &[PathBuf], tx: &SyncSender<FileEntry>) -> Result<usize> {
    let exclude = Arc::new(exclude.to_vec());

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

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

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

        let file_entry = FileEntry {
            name,
            path: path.to_string_lossy().into_owned(),
            size: metadata.len(),
            create_time: metadata.created().map(secs).unwrap_or_default(),
            change_time: metadata.modified().map(secs).unwrap_or_default(),
        };

        if tx.send(file_entry).is_err() {
            break; // writer dropped, stop early
        }
        count += 1;
    }

    Ok(count)
}
