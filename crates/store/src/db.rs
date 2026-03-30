use anyhow::Result;
use duckdb::{params, Connection};
use std::path::Path;
use std::path::PathBuf;

use crate::types::FileEntry;

pub struct Database {
    conn: Connection,
}

impl Database {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        let db = Database { conn };
        db.init_tables()?;
        Ok(db)
    }

    fn init_tables(&self) -> Result<()> {
        // config: app-level settings — one row, written on first launch.
        // files:  indexed file metadata, path is the natural key.
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS config (
                version   TEXT    NOT NULL,
                exclude   TEXT,
                indexed   BOOLEAN DEFAULT FALSE,
                monitored BOOLEAN DEFAULT FALSE
            );

            CREATE TABLE IF NOT EXISTS files (
                name        TEXT   NOT NULL,
                path        TEXT   NOT NULL UNIQUE,
                size        BIGINT,
                create_time TEXT,
                change_time TEXT
            );

            INSERT INTO config (version, exclude, indexed, monitored)
            SELECT '1.0.0', '~/Library/Caches
/Library/Caches', false, false
            WHERE NOT EXISTS (SELECT 1 FROM config LIMIT 1);",
        )?;
        Ok(())
    }

    /// Bulk-load the files table from a CSV produced by the scan phase.
    /// This is far faster than row-by-row appending because DuckDB's COPY
    /// reader is vectorised and the CSV write during scanning is purely
    /// sequential (no disk contention with the metadata reads).
    pub fn import_from_csv(&self, csv_path: &PathBuf) -> Result<()> {
        self.conn.execute_batch("DELETE FROM files")?;
        let safe = csv_path.to_string_lossy().replace('\'', "''");
        self.conn.execute_batch(&format!(
            "COPY files (name, path, size, create_time, change_time) \
             FROM '{safe}' (FORMAT CSV, HEADER FALSE, QUOTE '\"', ESCAPE '\"');"
        ))?;
        Ok(())
    }

    /// Consume an iterator of `FileEntry` values, writing them to the files
    /// table as they arrive.  The table is cleared first.  Intended for the
    /// pipelined scan+write path where the iterator is a channel receiver.
    pub fn stream_insert(&self, entries: impl Iterator<Item = FileEntry>) -> Result<usize> {
        self.conn.execute_batch("DELETE FROM files")?;
        let mut appender = self.conn.appender("files")?;
        let mut count = 0usize;
        for e in entries {
            appender.append_row(params![
                e.name.as_str(),
                e.path.as_str(),
                e.size as i64,
                e.create_time.as_str(),
                e.change_time.as_str(),
            ])?;
            count += 1;
            if count % 10_000 == 0 {
                println!("[store] written {} files...", count);
            }
        }
        Ok(count)
    }

    /// Replace the entire files table with a fresh bulk load.
    /// Uses DuckDB's Appender for maximum throughput.
    pub fn bulk_insert(&self, entries: &[FileEntry]) -> Result<()> {
        self.conn.execute_batch("DELETE FROM files")?;
        let mut appender = self.conn.appender("files")?;
        for e in entries {
            appender.append_row(params![
                e.name.as_str(),
                e.path.as_str(),
                e.size as i64,
                e.create_time.as_str(),
                e.change_time.as_str(),
            ])?;
        }
        Ok(())
    }

    /// Insert or update a single file (used by the monitor on create/change).
    pub fn upsert_file(&self, entry: &FileEntry) -> Result<()> {
        self.conn.execute(
            "INSERT INTO files (name, path, size, create_time, change_time)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT (path) DO UPDATE SET
                 name        = excluded.name,
                 size        = excluded.size,
                 change_time = excluded.change_time",
            params![
                entry.name.as_str(),
                entry.path.as_str(),
                entry.size as i64,
                entry.create_time.as_str(),
                entry.change_time.as_str(),
            ],
        )?;
        Ok(())
    }

    /// Remove a file record by path (used by the monitor on delete).
    pub fn delete_file(&self, path: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM files WHERE path = ?", params![path])?;
        Ok(())
    }

    /// Full-text search on name and path using a LIKE pattern.
    pub fn query_files(&self, pattern: &str) -> Result<Vec<FileEntry>> {
        let like = format!("%{pattern}%");
        let mut stmt = self.conn.prepare(
            "SELECT name, path, size, create_time, change_time
             FROM files
             WHERE path LIKE ? OR name LIKE ?
             ORDER BY path",
        )?;
        let rows = stmt.query_map(params![like.as_str(), like.as_str()], |row| {
            Ok(FileEntry {
                name: row.get(0)?,
                path: row.get(1)?,
                size: row.get::<_, i64>(2)? as u64,
                create_time: row.get(3)?,
                change_time: row.get(4)?,
            })
        })?;

        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Returns the raw exclude lines stored in config (one path per line).
    pub fn get_exclude_paths(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare("SELECT exclude FROM config LIMIT 1")?;
        let mut rows = stmt.query([])?;
        let raw = rows
            .next()?
            .map(|row| row.get::<_, String>(0).unwrap_or_default())
            .unwrap_or_default();
        Ok(raw
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect())
    }

    pub fn is_indexed(&self) -> Result<bool> {
        let mut stmt = self
            .conn
            .prepare("SELECT indexed FROM config LIMIT 1")?;
        let mut rows = stmt.query([])?;
        Ok(rows
            .next()?
            .map(|row| row.get::<_, bool>(0).unwrap_or(false))
            .unwrap_or(false))
    }

    pub fn mark_indexed(&self) -> Result<()> {
        self.conn
            .execute("UPDATE config SET indexed = true", [])?;
        Ok(())
    }
}
