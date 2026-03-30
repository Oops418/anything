use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub create_time: String,
    pub change_time: String,
}

/// Sent by the UI to search indexed files.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryRequest {
    pub way: QueryWay,
    pub pattern: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum QueryWay {
    #[serde(rename = "duckdb")]
    DuckDb,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryResponse {
    pub files: Vec<FileEntry>,
}

/// Sent by the monitor when a file system event occurs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModifyRequest {
    pub direction: ModifyDirection,
    pub data: FileEntry,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ModifyDirection {
    #[serde(rename = "insert")]
    Insert,
    #[serde(rename = "delete")]
    Delete,
    #[serde(rename = "change")]
    Change,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModifyResponse {
    pub success: bool,
}
