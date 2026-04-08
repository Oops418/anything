use anyhow::Result;
use duckdb::{Connection, params};
use std::collections::BTreeMap;
use std::path::Path;
use std::path::PathBuf;

use crate::types::{ConfigRow, FileEntry, TreemapNodeData, TreemapNodeKind};

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
                version      TEXT    NOT NULL,
                exclude      TEXT,
                last_indexed TIMESTAMP,
                total_files  BIGINT  DEFAULT 0,
                indexing     BOOLEAN DEFAULT FALSE,
                monitoring   BOOLEAN DEFAULT FALSE
            );

            CREATE TABLE IF NOT EXISTS files (
                name        TEXT   NOT NULL,
                path        TEXT   NOT NULL UNIQUE,
                size        BIGINT,
                create_time TEXT,
                change_time TEXT
            );",
        )?;
        self.conn.execute(
            "INSERT INTO config (version, exclude, last_indexed, total_files, indexing, monitoring)
             SELECT ?, '~/Library/Caches
/Library/Caches
/Volumes
/System/Volumes/Data', NULL, 0, false, false
             WHERE NOT EXISTS (SELECT 1 FROM config LIMIT 1)",
            params![env!("CARGO_PKG_VERSION")],
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

    /// Search files by name using a LIKE pattern.
    pub fn query_files(&self, pattern: &str) -> Result<Vec<FileEntry>> {
        let like = format!("%{pattern}%");
        let mut stmt = self.conn.prepare(
            "SELECT name, path, size, create_time, change_time
             FROM files
             WHERE name LIKE ?
             ORDER BY path",
        )?;
        let rows = stmt.query_map(params![like.as_str()], |row| {
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

    /// Returns all config fields as a single row.
    pub fn get_config(&self) -> Result<ConfigRow> {
        let mut stmt = self.conn.prepare(
            "SELECT version, exclude,
                    epoch(last_indexed)::BIGINT,
                    total_files, indexing, monitoring
             FROM config LIMIT 1",
        )?;
        let mut rows = stmt.query([])?;
        let row = rows
            .next()?
            .ok_or_else(|| anyhow::anyhow!("config table is empty"))?;
        Ok(ConfigRow {
            version: row.get(0)?,
            exclude: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            last_indexed_secs: row.get(2)?,
            total_files: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
            indexing: row.get::<_, Option<bool>>(4)?.unwrap_or(false),
            monitoring: row.get::<_, Option<bool>>(5)?.unwrap_or(false),
        })
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
            .prepare("SELECT last_indexed IS NOT NULL FROM config LIMIT 1")?;
        let mut rows = stmt.query([])?;
        Ok(rows
            .next()?
            .map(|row| row.get::<_, bool>(0).unwrap_or(false))
            .unwrap_or(false))
    }

    pub fn mark_indexed(&self, total_files: usize) -> Result<()> {
        self.conn.execute(
            "UPDATE config SET last_indexed = NOW(), total_files = ?",
            params![total_files as i64],
        )?;
        Ok(())
    }

    pub fn is_indexing(&self) -> Result<bool> {
        let mut stmt = self
            .conn
            .prepare("SELECT indexing FROM config LIMIT 1")?;
        let mut rows = stmt.query([])?;
        Ok(rows
            .next()?
            .map(|row| row.get::<_, bool>(0).unwrap_or(false))
            .unwrap_or(false))
    }

    pub fn set_indexing(&self, value: bool) -> Result<()> {
        self.conn
            .execute("UPDATE config SET indexing = ?", params![value])?;
        Ok(())
    }

    pub fn is_monitoring(&self) -> Result<bool> {
        let mut stmt = self
            .conn
            .prepare("SELECT monitoring FROM config LIMIT 1")?;
        let mut rows = stmt.query([])?;
        Ok(rows
            .next()?
            .map(|row| row.get::<_, bool>(0).unwrap_or(false))
            .unwrap_or(false))
    }

    pub fn set_monitoring(&self, value: bool) -> Result<()> {
        self.conn
            .execute("UPDATE config SET monitoring = ?", params![value])?;
        Ok(())
    }

    pub fn get_treemap(&self, root_path: &str, depth: u32) -> Result<TreemapNodeData> {
        let normalized_root = normalize_treemap_root(root_path);
        self.build_treemap_node(&normalized_root, depth.max(1))
    }

    fn build_treemap_node(&self, root_path: &str, depth: u32) -> Result<TreemapNodeData> {
        let subtree_files = self.query_subtree_files(root_path)?;

        if root_path != "/" {
            if let Some((_, size)) = subtree_files.iter().find(|(path, _)| path == root_path) {
                return Ok(TreemapNodeData {
                    path: root_path.to_string(),
                    name: treemap_node_name(root_path),
                    kind: TreemapNodeKind::File,
                    size: *size,
                    has_children: false,
                    children: Vec::new(),
                });
            }
        }

        let mut children = immediate_children_from_rows(root_path, &subtree_files);

        if depth > 1 {
            for child in &mut children {
                if child.kind == TreemapNodeKind::Directory && child.has_children {
                    *child = self.build_treemap_node(&child.path, depth - 1)?;
                }
            }
        }

        let total_size = children.iter().map(|child| child.size).sum();
        let has_children = !children.is_empty();

        Ok(TreemapNodeData {
            path: root_path.to_string(),
            name: treemap_node_name(root_path),
            kind: TreemapNodeKind::Directory,
            size: total_size,
            has_children,
            children,
        })
    }

    fn query_subtree_files(&self, root_path: &str) -> Result<Vec<(String, u64)>> {
        if root_path == "/" {
            let mut stmt = self
                .conn
                .prepare("SELECT path, size FROM files ORDER BY path")?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64))
            })?;
            return rows.collect::<Result<Vec<_>, _>>().map_err(Into::into);
        }

        let like = format!("{root_path}/%");
        let mut stmt = self.conn.prepare(
            "SELECT path, size
             FROM files
             WHERE path = ? OR path LIKE ?
             ORDER BY path",
        )?;
        let rows = stmt.query_map(params![root_path, like.as_str()], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64))
        })?;

        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }
}

#[derive(Debug)]
struct ChildAccumulator {
    path: String,
    name: String,
    kind: TreemapNodeKind,
    size: u64,
    has_children: bool,
}

fn immediate_children_from_rows(
    root_path: &str,
    subtree_files: &[(String, u64)],
) -> Vec<TreemapNodeData> {
    let mut children = BTreeMap::<String, ChildAccumulator>::new();

    for (path, size) in subtree_files {
        let Some(relative_path) = relative_path(root_path, path) else {
            continue;
        };

        let Some((first_component, remainder)) = split_first_component(relative_path) else {
            continue;
        };

        if remainder.is_empty() {
            if *size == 0 {
                continue;
            }

            children.insert(
                path.clone(),
                ChildAccumulator {
                    path: path.clone(),
                    name: first_component.to_string(),
                    kind: TreemapNodeKind::File,
                    size: *size,
                    has_children: false,
                },
            );
            continue;
        }

        let child_path = join_treemap_path(root_path, first_component);
        let entry = children.entry(child_path.clone()).or_insert_with(|| ChildAccumulator {
            path: child_path.clone(),
            name: first_component.to_string(),
            kind: TreemapNodeKind::Directory,
            size: 0,
            has_children: true,
        });
        entry.size = entry.size.saturating_add(*size);
        entry.has_children = true;
    }

    let mut nodes = children
        .into_values()
        .filter(|child| child.size > 0)
        .map(|child| TreemapNodeData {
            path: child.path,
            name: child.name,
            kind: child.kind,
            size: child.size,
            has_children: child.has_children,
            children: Vec::new(),
        })
        .collect::<Vec<_>>();

    nodes.sort_by(|lhs, rhs| rhs.size.cmp(&lhs.size).then_with(|| lhs.path.cmp(&rhs.path)));
    nodes
}

fn normalize_treemap_root(root_path: &str) -> String {
    let trimmed = root_path.trim();
    if trimmed.is_empty() {
        return "/".to_string();
    }

    let mut normalized = trimmed.to_string();
    if !normalized.starts_with('/') {
        normalized.insert(0, '/');
    }

    while normalized.len() > 1 && normalized.ends_with('/') {
        normalized.pop();
    }

    if normalized.is_empty() {
        "/".to_string()
    } else {
        normalized
    }
}

fn relative_path<'a>(root_path: &str, file_path: &'a str) -> Option<&'a str> {
    if root_path == "/" {
        return file_path.strip_prefix('/');
    }

    let remainder = file_path.strip_prefix(root_path)?;
    if remainder.is_empty() {
        return None;
    }

    remainder.strip_prefix('/')
}

fn split_first_component(path: &str) -> Option<(&str, &str)> {
    if path.is_empty() {
        return None;
    }

    match path.split_once('/') {
        Some((first, remainder)) => Some((first, remainder)),
        None => Some((path, "")),
    }
}

fn join_treemap_path(root_path: &str, child_name: &str) -> String {
    if root_path == "/" {
        format!("/{child_name}")
    } else {
        format!("{root_path}/{child_name}")
    }
}

fn treemap_node_name(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.rsplit('/').next().unwrap_or(path).to_string()
    }
}
