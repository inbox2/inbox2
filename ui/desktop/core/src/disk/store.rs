//! `disk.db`: the remote tree as last pulled, the change log macOS enumerates
//! from, and the uploads in flight. Lives in the App Group container so the
//! desktop app and the File Provider extension open the same file.
//!
//! With a replicated File Provider the OS owns the local tree and hands back
//! the content version an edit started from, so the merge base needs no table
//! of its own: `modify_contents` sends it to the server as `base_version`.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension, Row};

use super::model::*;

const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  name TEXT,
  mime TEXT,
  sealed INTEGER NOT NULL DEFAULT 0,
  scope_id TEXT,
  meta_ct TEXT,
  key_epoch INTEGER,
  size INTEGER NOT NULL DEFAULT 0,
  modified_at INTEGER NOT NULL DEFAULT 0,
  version_id TEXT,
  wrapped_key TEXT,
  manifest_ct TEXT,
  version_epoch INTEGER,
  can_write INTEGER NOT NULL DEFAULT 1,
  change_seq INTEGER NOT NULL DEFAULT 0,
  locked INTEGER NOT NULL DEFAULT 0,
  remote_parent TEXT,
  drive TEXT,
  stored_size INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS nodes_parent ON nodes(parent_id);
CREATE TABLE IF NOT EXISTS changes (
  rev INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS uploads (
  local_key TEXT PRIMARY KEY,
  upload_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  sealed_json TEXT,
  created_at INTEGER NOT NULL,
  done INTEGER NOT NULL DEFAULT 0
);
"#;

/// A node row with what the engine needs beyond the `DiskItem`.
#[derive(Debug, Clone, Default)]
pub struct NodeRow {
    pub id: String,
    pub parent_id: String,
    pub kind: String,
    pub name: Option<String>,
    pub mime: Option<String>,
    pub sealed: bool,
    pub scope_id: Option<String>,
    pub meta_ct: Option<String>,
    pub key_epoch: Option<i64>,
    pub size: u64,
    pub modified_at: i64,
    pub version_id: Option<String>,
    pub wrapped_key: Option<String>,
    pub manifest_ct: Option<String>,
    pub version_epoch: Option<i64>,
    pub can_write: bool,
    pub change_seq: i64,
    pub locked: bool,
    /// "c" or the share id (the feed's `drive`).
    pub drive: Option<String>,
    /// The current version's bytes in storage (ciphertext for sealed files).
    pub stored_size: u64,
}

impl NodeRow {
    fn from_row(r: &Row) -> rusqlite::Result<Self> {
        Ok(NodeRow {
            id: r.get("id")?,
            parent_id: r.get("parent_id")?,
            kind: r.get("kind")?,
            name: r.get("name")?,
            mime: r.get("mime")?,
            sealed: r.get::<_, i64>("sealed")? != 0,
            scope_id: r.get("scope_id")?,
            meta_ct: r.get("meta_ct")?,
            key_epoch: r.get("key_epoch")?,
            size: r.get::<_, i64>("size")? as u64,
            modified_at: r.get("modified_at")?,
            version_id: r.get("version_id")?,
            wrapped_key: r.get("wrapped_key")?,
            manifest_ct: r.get("manifest_ct")?,
            version_epoch: r.get("version_epoch")?,
            can_write: r.get::<_, i64>("can_write")? != 0,
            change_seq: r.get("change_seq")?,
            locked: r.get::<_, i64>("locked")? != 0,
            drive: r.get("drive")?,
            stored_size: r.get::<_, i64>("stored_size")? as u64,
        })
    }

    pub fn is_folder(&self) -> bool {
        self.kind == KIND_FOLDER
    }

    /// What macOS shows. Drive roots carry their display name in `name`.
    pub fn item(&self) -> DiskItem {
        let base = match (&self.name, self.locked) {
            (Some(n), false) => n.clone(),
            // A name we can't open still needs a stable, unique filename.
            _ => format!("Sealed item {}", short(&self.id)),
        };
        let filename = if self.kind == KIND_PAGE { format!("{base}.{PAGE_EXTENSION}") } else { base };
        // A file with no version yet is "none" (the server's NO_VERSION), so an
        // edit of it is still checked; folders and pages have no content version.
        let content_version = match (&self.version_id, self.kind == KIND_FILE) {
            (Some(v), _) => v.clone(),
            (None, true) => NO_VERSION.to_string(),
            (None, false) => self.id.clone(),
        };
        DiskItem {
            id: self.id.clone(),
            parent_id: self.parent_id.clone(),
            filename,
            kind: self.kind.clone(),
            mime: self.mime.clone(),
            size: if self.kind == KIND_FILE { self.size } else { 0 },
            modified_at: self.modified_at,
            content_version,
            metadata_version: self.change_seq.to_string(),
            can_write: self.can_write && !self.locked,
            sealed: self.sealed,
            locked: self.locked,
            keep_downloaded: false,
        }
    }
}

fn short(id: &str) -> &str {
    let tail = id.rsplit('_').next().unwrap_or(id);
    &tail[..tail.len().min(6)]
}

pub struct DiskStore {
    conn: Connection,
}

impl DiskStore {
    pub fn open(path: &Path) -> DiskResult<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn })
    }

    #[cfg(test)]
    pub fn in_memory() -> Self {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        Self { conn }
    }

    pub fn get_state(&self, k: &str) -> DiskResult<Option<String>> {
        Ok(self.conn.query_row("SELECT v FROM state WHERE k = ?1", [k], |r| r.get(0)).optional()?)
    }

    pub fn set_state(&self, k: &str, v: &str) -> DiskResult<()> {
        self.conn.execute("INSERT INTO state (k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [k, v])?;
        Ok(())
    }

    pub fn node(&self, id: &str) -> DiskResult<Option<NodeRow>> {
        Ok(self.conn.query_row("SELECT * FROM nodes WHERE id = ?1", [id], NodeRow::from_row).optional()?)
    }

    pub fn children(&self, parent_id: &str) -> DiskResult<Vec<NodeRow>> {
        let mut st = self.conn.prepare("SELECT * FROM nodes WHERE parent_id = ?1 ORDER BY name")?;
        let rows = st.query_map([parent_id], NodeRow::from_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn all_ids(&self) -> DiskResult<Vec<(String, i64)>> {
        let mut st = self.conn.prepare("SELECT id, change_seq FROM nodes")?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Logs every node of these drives (and the drive roots), so macOS reads
    /// them again after a Settings change: shown, hidden or kept downloaded.
    pub fn touch(&self, drives: &[String], roots: bool) -> DiskResult<()> {
        let mut ids: Vec<String> = Vec::new();
        for d in drives {
            let mut st = self.conn.prepare("SELECT id FROM nodes WHERE drive = ?1")?;
            ids.extend(st.query_map([d], |r| r.get(0))?.collect::<rusqlite::Result<Vec<String>>>()?);
        }
        if roots {
            let mut st = self.conn.prepare("SELECT id FROM nodes WHERE parent_id = ?1")?;
            ids.extend(st.query_map([ROOT_ID], |r| r.get(0))?.collect::<rusqlite::Result<Vec<String>>>()?);
        }
        for id in ids {
            self.log(&id, false)?;
        }
        Ok(())
    }

    /// Every sealed node, files and folders.
    pub fn sealed_ids(&self) -> DiskResult<Vec<String>> {
        let mut st = self.conn.prepare("SELECT id FROM nodes WHERE sealed = 1 AND parent_id != ?1")?;
        let rows = st.query_map([ROOT_ID], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn lock_sealed(&self) -> DiskResult<()> {
        for id in self.sealed_ids()? {
            self.conn.execute("UPDATE nodes SET name = NULL, mime = NULL, locked = 1 WHERE id = ?1", [&id])?;
            self.log(&id, false)?;
        }
        Ok(())
    }

    pub fn has_children(&self, id: &str) -> DiskResult<bool> {
        Ok(self.conn.query_row("SELECT EXISTS(SELECT 1 FROM nodes WHERE parent_id = ?1)", [id], |r| r.get::<_, i64>(0))? == 1)
    }

    /// Removes one node and logs it; its children stay.
    pub fn delete_one(&self, id: &str) -> DiskResult<()> {
        if self.conn.execute("DELETE FROM nodes WHERE id = ?1", [id])? > 0 {
            self.log(id, true)?;
        }
        Ok(())
    }

    /// Every sealed file, for evicting their downloaded copies.
    pub fn sealed_file_ids(&self) -> DiskResult<Vec<String>> {
        let mut st = self.conn.prepare("SELECT id FROM nodes WHERE sealed = 1 AND kind = 'file'")?;
        let rows = st.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn count(&self) -> DiskResult<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM nodes", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// Writes the node and logs the change, unless nothing macOS shows changed.
    pub fn upsert(&self, n: &NodeRow) -> DiskResult<bool> {
        if let Some(old) = self.node(&n.id)? {
            if old.item() == n.item() && old.change_seq == n.change_seq {
                return Ok(false);
            }
        }
        self.conn.execute(
            "INSERT INTO nodes (id, parent_id, kind, name, mime, sealed, scope_id, meta_ct, key_epoch, size, modified_at,
               version_id, wrapped_key, manifest_ct, version_epoch, can_write, change_seq, locked, drive, stored_size)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
             ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, kind = excluded.kind, name = excluded.name,
               mime = excluded.mime, sealed = excluded.sealed, scope_id = excluded.scope_id, meta_ct = excluded.meta_ct,
               key_epoch = excluded.key_epoch, size = excluded.size, modified_at = excluded.modified_at,
               version_id = excluded.version_id, wrapped_key = excluded.wrapped_key, manifest_ct = excluded.manifest_ct,
               version_epoch = excluded.version_epoch, can_write = excluded.can_write, change_seq = excluded.change_seq,
               locked = excluded.locked, drive = excluded.drive, stored_size = excluded.stored_size",
            params![
                n.id, n.parent_id, n.kind, n.name, n.mime, n.sealed as i64, n.scope_id, n.meta_ct, n.key_epoch,
                n.size as i64, n.modified_at, n.version_id, n.wrapped_key, n.manifest_ct, n.version_epoch,
                n.can_write as i64, n.change_seq, n.locked as i64, n.drive, n.stored_size as i64
            ],
        )?;
        self.log(&n.id, false)?;
        Ok(true)
    }

    /// Removes the node and everything beneath it, logging each removal.
    pub fn delete_subtree(&self, id: &str) -> DiskResult<()> {
        let ids: Vec<String> = {
            let mut st = self.conn.prepare(
                "WITH RECURSIVE t(id) AS (SELECT id FROM nodes WHERE id = ?1
                   UNION ALL SELECT n.id FROM nodes n JOIN t ON n.parent_id = t.id) SELECT id FROM t",
            )?;
            let ids = st.query_map([id], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            ids
        };
        for i in &ids {
            self.conn.execute("DELETE FROM nodes WHERE id = ?1", [i])?;
            self.log(i, true)?;
        }
        Ok(())
    }

    fn log(&self, id: &str, deleted: bool) -> DiskResult<()> {
        self.conn.execute("INSERT INTO changes (node_id, deleted) VALUES (?1, ?2)", params![id, deleted as i64])?;
        Ok(())
    }

    /// The File Provider sync anchor: the newest change rev.
    pub fn anchor(&self) -> DiskResult<u64> {
        Ok(self.conn.query_row("SELECT COALESCE(MAX(rev), 0) FROM changes", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// Changes after `anchor`, newest state per node, at most `limit` nodes.
    pub fn changes_since(&self, anchor: u64, limit: usize) -> DiskResult<DiskChanges> {
        let mut st = self.conn.prepare(
            "SELECT node_id, MAX(rev) AS rev FROM changes WHERE rev > ?1 GROUP BY node_id ORDER BY rev LIMIT ?2",
        )?;
        let rows: Vec<(String, i64)> =
            st.query_map(params![anchor as i64, limit as i64 + 1], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
        let more = rows.len() > limit;
        let rows = &rows[..rows.len().min(limit)];
        let mut out = DiskChanges { anchor, more, ..Default::default() };
        for (id, rev) in rows {
            match self.node(id)? {
                Some(n) => out.updated.push(n.item()),
                None => out.deleted.push(id.clone()),
            }
            out.anchor = out.anchor.max(*rev as u64);
        }
        // Only revs actually listed move the anchor: a write from the other
        // process after the read above must still be reported next time.
        Ok(out)
    }

    /// Keeps the change log short: macOS only ever asks from a recent anchor,
    /// and an anchor older than the log gets "sync anchor expired" and a re-list.
    pub fn trim_changes(&self, keep: i64) -> DiskResult<()> {
        self.conn.execute("DELETE FROM changes WHERE rev < (SELECT COALESCE(MAX(rev), 0) - ?1 FROM changes)", [keep])?;
        Ok(())
    }

    pub fn oldest_rev(&self) -> DiskResult<u64> {
        Ok(self.conn.query_row("SELECT COALESCE(MIN(rev), 0) FROM changes", [], |r| r.get::<_, i64>(0))? as u64)
    }

    pub fn upload_for(&self, local_key: &str) -> DiskResult<Option<(String, String, Option<String>)>> {
        Ok(self
            .conn
            .query_row(
                "SELECT upload_id, fingerprint, sealed_json FROM uploads WHERE local_key = ?1",
                [local_key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?)
    }

    pub fn save_upload(&self, local_key: &str, upload_id: &str, fingerprint: &str, sealed_json: Option<&str>) -> DiskResult<()> {
        self.conn.execute(
            "INSERT INTO uploads (local_key, upload_id, fingerprint, sealed_json, created_at) VALUES (?1, ?2, ?3, ?4, strftime('%s','now'))
             ON CONFLICT(local_key) DO UPDATE SET upload_id = excluded.upload_id, fingerprint = excluded.fingerprint,
               sealed_json = excluded.sealed_json, created_at = excluded.created_at",
            params![local_key, upload_id, fingerprint, sealed_json],
        )?;
        Ok(())
    }

    pub fn drop_upload(&self, local_key: &str) -> DiskResult<()> {
        self.conn.execute("DELETE FROM uploads WHERE local_key = ?1", [local_key])?;
        Ok(())
    }

    pub fn uploads_in_flight(&self) -> DiskResult<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM uploads WHERE done = 0", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// A finished create keeps its record (done) so a retried create returns
    /// the same node; a day later it goes.
    pub fn mark_upload_done(&self, local_key: &str) -> DiskResult<()> {
        self.conn.execute("UPDATE uploads SET done = 1, created_at = strftime('%s','now') WHERE local_key = ?1", [local_key])?;
        Ok(())
    }

    pub fn prune_done_uploads(&self) -> DiskResult<()> {
        self.conn.execute("DELETE FROM uploads WHERE done = 1 AND created_at < strftime('%s','now') - 86400", [])?;
        Ok(())
    }

    /// Nodes granted from someone else's C:\\ arrive without their parent
    /// (it isn't visible). They go under one "Shared with me" folder, and move
    /// back under their real parent once that one is here.
    pub fn rehome_orphans(&self) -> DiskResult<()> {
        let back: Vec<String> = {
            let mut st = self.conn.prepare(
                "SELECT id FROM nodes WHERE parent_id = ?1 AND remote_parent IN (SELECT id FROM nodes)")?;
            let v = st.query_map([SHARED_ID], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            v
        };
        for id in &back {
            self.conn.execute("UPDATE nodes SET parent_id = remote_parent WHERE id = ?1", [id])?;
            self.log(id, false)?;
        }
        let orphans: Vec<String> = {
            let mut st = self.conn.prepare(
                "SELECT id FROM nodes WHERE parent_id NOT IN (?1, ?2) AND parent_id NOT IN (SELECT id FROM nodes)")?;
            let v = st.query_map([ROOT_ID, SHARED_ID], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
            v
        };
        for id in &orphans {
            self.conn.execute("UPDATE nodes SET remote_parent = parent_id, parent_id = ?2 WHERE id = ?1", [id, SHARED_ID])?;
            self.log(id, false)?;
        }
        let used: i64 = self.conn.query_row("SELECT COUNT(*) FROM nodes WHERE parent_id = ?1", [SHARED_ID], |r| r.get(0))?;
        let have = self.node(SHARED_ID)?.is_some();
        if used > 0 && !have {
            self.upsert(&NodeRow { id: SHARED_ID.into(), parent_id: ROOT_ID.into(), kind: KIND_FOLDER.into(),
                name: Some(SHARED_WITH_ME.into()), can_write: false, ..Default::default() })?;
        } else if used == 0 && have {
            self.conn.execute("DELETE FROM nodes WHERE id = ?1", [SHARED_ID])?;
            self.log(SHARED_ID, true)?;
        }
        Ok(())
    }

    /// Starts the tree over in place: every node goes (each removal logged, so
    /// macOS drops it), uploads and state are cleared, and the new identity set.
    pub fn reset(&mut self, identity: &str) -> DiskResult<()> {
        self.transaction(|s| {
            let ids: Vec<String> = {
                let mut st = s.conn.prepare("SELECT id FROM nodes")?;
                let v = st.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
                v
            };
            s.conn.execute("DELETE FROM nodes", [])?;
            for id in &ids {
                s.log(id, true)?;
            }
            s.conn.execute("DELETE FROM uploads", [])?;
            s.conn.execute("DELETE FROM state", [])?;
            s.set_state("identity", identity)
        })
    }

    pub fn transaction<T>(&mut self, f: impl FnOnce(&DiskStore) -> DiskResult<T>) -> DiskResult<T> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        match f(self) {
            Ok(v) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, parent: &str, name: &str) -> NodeRow {
        NodeRow { id: id.into(), parent_id: parent.into(), kind: KIND_FILE.into(), name: Some(name.into()), can_write: true, ..Default::default() }
    }

    #[test]
    fn changes_dedupe_per_node_and_report_deletes() {
        let s = DiskStore::in_memory();
        s.upsert(&row("dnd_a", ROOT_ID, "a")).unwrap();
        let start = s.anchor().unwrap();
        s.upsert(&row("dnd_b", "dnd_a", "b")).unwrap();
        s.upsert(&NodeRow { name: Some("b2".into()), change_seq: 2, ..row("dnd_b", "dnd_a", "b") }).unwrap();
        s.delete_subtree("dnd_a").unwrap();
        let c = s.changes_since(start, 100).unwrap();
        assert!(c.updated.is_empty());
        assert_eq!(c.deleted.len(), 2);
        assert_eq!(c.anchor, s.anchor().unwrap());
        assert!(!c.more);
    }

    #[test]
    fn granted_items_without_a_visible_parent_go_under_shared_with_me() {
        let s = DiskStore::in_memory();
        s.upsert(&row("dnd_g", "dnd_hidden", "Granted")).unwrap();
        s.rehome_orphans().unwrap();
        assert_eq!(s.node("dnd_g").unwrap().unwrap().parent_id, SHARED_ID);
        assert_eq!(s.node(SHARED_ID).unwrap().unwrap().item().filename, SHARED_WITH_ME);
        // The parent comes into view: the item moves back and the virtual folder goes.
        s.upsert(&row("dnd_hidden", ROOT_ID, "Theirs")).unwrap();
        s.rehome_orphans().unwrap();
        assert_eq!(s.node("dnd_g").unwrap().unwrap().parent_id, "dnd_hidden");
        assert!(s.node(SHARED_ID).unwrap().is_none());
    }

    #[test]
    fn a_parent_leaving_view_keeps_a_child_still_granted() {
        let s = DiskStore::in_memory();
        s.upsert(&row("dnd_p", ROOT_ID, "Parent")).unwrap();
        s.upsert(&row("dnd_c", "dnd_p", "Child")).unwrap();
        assert!(s.has_children("dnd_p").unwrap());
        s.delete_one("dnd_p").unwrap();
        s.rehome_orphans().unwrap();
        assert_eq!(s.node("dnd_c").unwrap().unwrap().parent_id, SHARED_ID);
    }

    #[test]
    fn reset_drops_every_node_for_macos_and_keeps_the_log_going() {
        let mut s = DiskStore::in_memory();
        s.upsert(&row("dnd_a", ROOT_ID, "a")).unwrap();
        s.set_state("cursor", "9.0").unwrap();
        let before = s.anchor().unwrap();
        s.reset("other").unwrap();
        assert_eq!(s.count().unwrap(), 0);
        assert!(s.get_state("cursor").unwrap().is_none());
        assert_eq!(s.get_state("identity").unwrap().as_deref(), Some("other"));
        assert_eq!(s.changes_since(before, 10).unwrap().deleted, vec!["dnd_a".to_string()]);
    }

    #[test]
    fn lock_sealed_hides_names_and_content() {
        let s = DiskStore::in_memory();
        s.upsert(&row("dnd_r", ROOT_ID, "Board")).unwrap();
        s.upsert(&NodeRow { sealed: true, kind: KIND_FOLDER.into(), ..row("dnd_f", "dnd_r", "Plans") }).unwrap();
        s.upsert(&NodeRow { sealed: true, ..row("dnd_x", "dnd_f", "Budget.xlsx") }).unwrap();
        s.lock_sealed().unwrap();
        for id in ["dnd_f", "dnd_x"] {
            let item = s.node(id).unwrap().unwrap().item();
            assert!(item.locked && item.filename.starts_with("Sealed item"), "{id}");
        }
        assert_eq!(s.node("dnd_r").unwrap().unwrap().item().filename, "Board");
    }

    #[test]
    fn unchanged_upsert_logs_nothing() {
        let s = DiskStore::in_memory();
        assert!(s.upsert(&row("dnd_a", ROOT_ID, "a")).unwrap());
        let a = s.anchor().unwrap();
        assert!(!s.upsert(&row("dnd_a", ROOT_ID, "a")).unwrap());
        assert_eq!(s.anchor().unwrap(), a);
    }

    #[test]
    fn changes_page_and_pages_get_extension() {
        let s = DiskStore::in_memory();
        for i in 0..5 {
            s.upsert(&row(&format!("dnd_{i}"), ROOT_ID, &format!("f{i}"))).unwrap();
        }
        let c = s.changes_since(0, 2).unwrap();
        assert_eq!(c.updated.len(), 2);
        assert!(c.more);
        let page = NodeRow { kind: KIND_PAGE.into(), ..row("dnd_p", ROOT_ID, "Notes") };
        assert_eq!(page.item().filename, "Notes.page");
        let locked = NodeRow { locked: true, name: None, ..row("dnd_abcdefgh", ROOT_ID, "") };
        assert_eq!(locked.item().filename, "Sealed item abcdef");
        assert!(!locked.item().can_write);
    }
}
