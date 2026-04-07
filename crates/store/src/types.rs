use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub create_time: String,
    pub change_time: String,
}

#[derive(Debug, Clone)]
pub struct ConfigRow {
    pub version: String,
    pub exclude: String,
    /// Unix epoch seconds of the last completed index, or `None` if never indexed.
    pub last_indexed_secs: Option<i64>,
    pub total_files: i64,
    pub indexing: bool,
    pub monitoring: bool,
}
