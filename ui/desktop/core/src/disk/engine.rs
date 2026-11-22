//! The Disk sync engine (docs/Disk-Sync.md). One instance per process: the
//! File Provider extension and the desktop app each open their own, over the
//! same `disk.db` and `config.json` in the App Group container.
//!
//! Remote → Mac: `sync` pulls the server feed into the store; macOS asks for
//! `changes_since(anchor)`. Mac → remote: macOS calls create / modify / delete
//! and retries them itself after an `Offline` error, so the only state kept
//! here for writes is the upload in flight (to resume its parts).

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::api::DiskApi;
use super::keys::{ScopeKeys, SealedRecord};
use super::model::*;
use super::store::{DiskStore, NodeRow};

/// Written by the desktop app when Disk in Finder is turned on; read by both
/// processes. Lives in the App Group container, readable only by apps signed
/// by our team (macOS 15 group container protection).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DiskConfig {
    pub api_base: String,
    pub web_base: String,
    pub org: String,
    /// The signed-in member (user id): another member is another tree.
    #[serde(default)]
    pub member_id: String,
    pub token: String,
    /// Shown in conflicted copy names.
    pub member_name: String,
    /// The member's X25519 identity key pair (base64). The app writes it only
    /// when the startup disk has FileVault on, since sealed files opened in
    /// Finder sit decrypted in ~/Library/CloudStorage. Opens sealed shares.
    pub identity_secret: Option<String>,
    pub identity_public: Option<String>,
    /// "Keep on this Mac" for new files: drive roots ask macOS to download
    /// everything beneath them and keep it.
    #[serde(default)]
    pub keep_downloaded: bool,
    /// Drives left out of Finder ("c" or a share id).
    #[serde(default)]
    pub hidden_drives: Vec<String>,
    /// KiB per second, 0 for no limit.
    #[serde(default)]
    pub upload_kbps: u32,
    #[serde(default)]
    pub download_kbps: u32,
}

pub const CONFIG_FILE: &str = "config.json";
pub const DB_FILE: &str = "disk.db";
const STAGING_DIR: &str = "staging";
const CHANGES_PAGE: usize = 500;
const CHANGES_KEPT: i64 = 50_000;
const HYDRATE_BATCH: usize = 200;
const PARTS_PER_CALL: usize = 100;

/// Reports transfer progress and asks whether macOS cancelled it.
pub trait Progress: Send + Sync {
    fn progress(&self, done: u64, total: u64);
    fn is_cancelled(&self) -> bool;
}

pub struct NoProgress;
impl Progress for NoProgress {
    fn progress(&self, _: u64, _: u64) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

pub struct DiskEngine {
    dir: PathBuf,
    config: Mutex<(DiskConfig, Option<std::time::SystemTime>)>,
    api: Mutex<DiskApi>,
    store: Mutex<DiskStore>,
    keys: Mutex<ScopeKeys>,
    /// One pull at a time per process.
    syncing: Mutex<()>,
    /// One fetch per version at a time: they share the staging files.
    fetching: Mutex<std::collections::HashMap<String, std::sync::Arc<Mutex<()>>>>,
}

fn tree_identity(config: &DiskConfig) -> String {
    format!("{}|{}|{}", config.api_base, config.org, config.member_id)
}

/// Empties the store for another server, org or member. Done in place, with
/// every removal logged, because the other process may have `disk.db` open
/// and macOS must drop the old items.
fn reset_store(dir: &Path, store: &mut DiskStore, config: &DiskConfig) -> DiskResult<()> {
    let _ = fs::remove_dir_all(dir.join(STAGING_DIR));
    store.reset(&tree_identity(config))
}

fn config_mtime(dir: &Path) -> Option<std::time::SystemTime> {
    fs::metadata(dir.join(CONFIG_FILE)).and_then(|m| m.modified()).ok()
}

pub fn read_config(dir: &Path) -> DiskResult<DiskConfig> {
    let raw = fs::read_to_string(dir.join(CONFIG_FILE)).map_err(|_| DiskError::SignedOut)?;
    serde_json::from_str(&raw).map_err(|e| DiskError::Other(format!("config: {e}")))
}

/// Writes the config atomically and only readable by this user.
pub fn write_config(dir: &Path, config: &DiskConfig) -> DiskResult<()> {
    fs::create_dir_all(dir)?;
    // One writer at a time in this process; a unique temp file per write, so
    // even writers in two processes never share one before the atomic rename.
    static WRITE: Mutex<()> = Mutex::new(());
    let _one = WRITE.lock().unwrap_or_else(|p| p.into_inner());
    let tmp = dir.join(format!("{CONFIG_FILE}.{}.{}.tmp", std::process::id(), rand::random::<u64>()));
    {
        let mut f = File::create(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            f.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        f.write_all(serde_json::to_string(config).map_err(|e| DiskError::Other(e.to_string()))?.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(tmp, dir.join(CONFIG_FILE))?;
    Ok(())
}

impl DiskEngine {
    pub fn open(dir: &Path) -> DiskResult<Self> {
        let config = read_config(dir)?;
        Self::with_config(dir, config)
    }

    pub fn with_config(dir: &Path, config: DiskConfig) -> DiskResult<Self> {
        let mut store = DiskStore::open(&dir.join(DB_FILE))?;
        // A different server, org or member means a different tree: start over.
        if store.get_state("identity")?.as_deref() != Some(tree_identity(&config).as_str()) {
            reset_store(dir, &mut store, &config)?;
        }
        Self::build(dir, config, store)
    }

    fn build(dir: &Path, config: DiskConfig, store: DiskStore) -> DiskResult<Self> {
        let api = DiskApi::new(&config.api_base, &config.org, &config.token);
        let keys = ScopeKeys::new(config.identity_secret.clone(), config.identity_public.clone());
        let mtime = config_mtime(dir);
        Ok(Self {
            dir: dir.to_path_buf(),
            config: Mutex::new((config, mtime)),
            api: Mutex::new(api),
            store: Mutex::new(store),
            keys: Mutex::new(keys),
            syncing: Mutex::new(()),
            fetching: Mutex::new(Default::default()),
        })
    }

    #[cfg(test)]
    pub fn config_for_test(&self) -> DiskConfig {
        self.cfg().clone()
    }

    #[cfg(test)]
    pub fn open_with(dir: &Path, config: DiskConfig) -> DiskResult<Self> {
        Self::with_config(dir, config)
    }

    /// The current config. The app rewrites `config.json` (a new token, keys
    /// or settings); a changed file is read again here, in either process.
    pub fn cfg(&self) -> DiskConfig {
        let mut guard = self.config.lock().unwrap_or_else(|p| p.into_inner());
        let mtime = config_mtime(&self.dir);
        if mtime.is_some() && mtime != guard.1 {
            if let Ok(fresh) = read_config(&self.dir) {
                // Another server, org or member is another tree: start the store over.
                if tree_identity(&fresh) != tree_identity(&guard.0) {
                    let mut store = self.store.lock().unwrap_or_else(|p| p.into_inner());
                    if let Err(e) = reset_store(&self.dir, &mut store, &fresh) {
                        // Keep the old account's config with its own tree; try again next call.
                        log::warn!("[disk] reset: {e}");
                        return guard.0.clone();
                    }
                }
                *self.api.lock().unwrap_or_else(|p| p.into_inner()) = DiskApi::new(&fresh.api_base, &fresh.org, &fresh.token);
                let identity_changed = fresh.identity_secret != guard.0.identity_secret;
                if identity_changed {
                    *self.keys.lock().unwrap_or_else(|p| p.into_inner()) =
                        ScopeKeys::new(fresh.identity_secret.clone(), fresh.identity_public.clone());
                }
                *guard = (fresh, mtime);
            }
        }
        guard.0.clone()
    }

    fn api(&self) -> DiskApi {
        self.cfg();
        self.api.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }

    fn store(&self) -> std::sync::MutexGuard<'_, DiskStore> {
        self.store.lock().unwrap_or_else(|p| p.into_inner())
    }

    // ── reading ──────────────────────────────────────────────────────────

    /// Hidden drives read as absent; drive roots carry "Keep on this Mac".
    fn present(&self, row: &NodeRow, cfg: &DiskConfig) -> Option<DiskItem> {
        if row.drive.as_ref().is_some_and(|d| cfg.hidden_drives.contains(d)) {
            return None;
        }
        let mut item = row.item();
        item.keep_downloaded = cfg.keep_downloaded && row.parent_id == ROOT_ID;
        Some(item)
    }

    pub fn item(&self, id: &str) -> DiskResult<DiskItem> {
        let cfg = self.cfg();
        let row = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        self.present(&row, &cfg).ok_or(DiskError::NotFound)
    }

    pub fn children(&self, parent_id: &str) -> DiskResult<Vec<DiskItem>> {
        let cfg = self.cfg();
        Ok(self.store().children(parent_id)?.iter().filter_map(|r| self.present(r, &cfg)).collect())
    }

    pub fn anchor(&self) -> DiskResult<u64> {
        self.store().anchor()
    }

    /// `Err(NotFound)` when the anchor is older than the change log: macOS then
    /// drops its copy of the listing and enumerates again.
    pub fn changes_since(&self, anchor: u64) -> DiskResult<DiskChanges> {
        let cfg = self.cfg();
        let store = self.store();
        let oldest = store.oldest_rev()?;
        if anchor > 0 && oldest > 0 && anchor + 1 < oldest {
            return Err(DiskError::NotFound);
        }
        let mut c = store.changes_since(anchor, CHANGES_PAGE)?;
        let mut updated = Vec::with_capacity(c.updated.len());
        for item in c.updated.drain(..) {
            match store.node(&item.id)?.and_then(|r| self.present(&r, &cfg)) {
                Some(i) => updated.push(i),
                None => c.deleted.push(item.id),
            }
        }
        c.updated = updated;
        Ok(c)
    }

    /// After the app changed which drives show or "Keep on this Mac": makes
    /// macOS read the affected items again.
    pub fn settings_changed(&self, drives: &[String], roots: bool) -> DiskResult<()> {
        self.store().touch(drives, roots)
    }

    /// Sealed files to evict when sealed shares stop being allowed here.
    pub fn sealed_file_ids(&self) -> DiskResult<Vec<String>> {
        self.store().sealed_file_ids()
    }

    /// Locks every sealed node here and now, without the server: names go,
    /// content can't be fetched. For when the key leaves this Mac.
    pub fn lock_sealed(&self) -> DiskResult<()> {
        self.store().lock_sealed()
    }

    /// Re-reads every sealed node with the keys now on this Mac, so they lock
    /// (or open) right away instead of on their next change.
    pub fn reopen_sealed(&self) -> DiskResult<()> {
        // Folders too: their names were opened with the same key.
        let ids = self.store().sealed_ids()?;
        for batch in ids.chunks(HYDRATE_BATCH) {
            let nodes = self.api().nodes(batch)?;
            let rows: Vec<NodeRow> = nodes.iter().map(|n| self.ingest(n)).collect::<DiskResult<_>>()?;
            self.store().transaction(|s| rows.iter().try_for_each(|r| s.upsert(r).map(|_| ())))?;
        }
        Ok(())
    }

    pub fn status(&self) -> DiskStatus {
        // Config first: reading it may reset the store, which takes the store lock.
        let signed_in = !self.cfg().token.is_empty();
        let store = self.store();
        DiskStatus {
            items: store.count().unwrap_or(0),
            uploading: store.uploads_in_flight().unwrap_or(0),
            last_sync_at: store.get_state("last_sync_at").ok().flatten().and_then(|v| v.parse().ok()),
            last_error: store.get_state("last_error").ok().flatten().filter(|s| !s.is_empty()),
            signed_in,
        }
    }

    // ── remote → Mac ─────────────────────────────────────────────────────

    /// Pulls every change since the stored cursor. Returns whether anything
    /// macOS shows changed (the caller then signals the enumerator).
    pub fn sync(&self) -> DiskResult<bool> {
        let _one = self.syncing.lock().unwrap_or_else(|p| p.into_inner());
        let result = self.sync_inner();
        let store = self.store();
        match &result {
            Ok(_) => {
                store.set_state("last_sync_at", &chrono::Utc::now().timestamp().to_string())?;
                store.set_state("last_error", "")?;
            }
            Err(e) => store.set_state("last_error", &e.to_string())?,
        }
        result
    }

    fn sync_inner(&self) -> DiskResult<bool> {
        // A changed config may reset the store: read it before the cursor, and
        // pin this client for the whole pull.
        let cfg = self.cfg();
        let api = self.api();
        let tree = tree_identity(&cfg);
        let before = self.anchor()?;
        let mut cursor = self.store().get_state("cursor")?.unwrap_or_default();
        // A reconcile owed by an earlier pull that failed before finishing it.
        // A reconcile owed by an earlier pull that failed before finishing it
        // ("full" after an access change).
        let pending = self.store().get_state("reconcile_pending")?;
        let mut reconcile = pending.as_deref().is_some_and(|p| p != "0");
        let mut full = pending.as_deref() == Some("full");
        let reconcile_after = std::cell::RefCell::new(false);
        loop {
            let page = api.pull(&cursor)?;
            reconcile |= page.reconcile || page.cursor_expired;
            full |= page.reconcile || page.cursor_expired;
            let rows: Vec<NodeRow> = page.nodes.iter().map(|n| self.ingest(n)).collect::<DiskResult<_>>()?;
            let mut store = self.store();
            store.transaction(|s| {
                // The account changed mid-pull: this page belongs to the old tree.
                if s.get_state("identity")?.as_deref() != Some(tree.as_str()) {
                    return Err(DiskError::Offline("the account changed during a pull".into()));
                }
                for r in &rows {
                    s.upsert(r)?;
                }
                for id in &page.deleted {
                    // A folder that left view may hold a child granted on its
                    // own: the reconcile below brings such children back.
                    if s.has_children(id)? {
                        *reconcile_after.borrow_mut() = true;
                    }
                    s.delete_subtree(id)?;
                }
                // The cursor moves past this page only with the reconcile it
                // asks for recorded, so a failed reconcile runs again next time.
                if page.reconcile || page.cursor_expired {
                    s.set_state("reconcile_pending", "full")?;
                } else if *reconcile_after.borrow() && s.get_state("reconcile_pending")?.as_deref() != Some("full") {
                    s.set_state("reconcile_pending", "1")?;
                }
                s.set_state("cursor", &page.cursor)
            })?;
            drop(store);
            cursor = page.cursor;
            if !page.has_more {
                break;
            }
        }
        if reconcile || reconcile_after.into_inner() {
            self.reconcile(full)?;
            self.store().set_state("reconcile_pending", "0")?;
        }
        self.store().rehome_orphans()?;
        self.store().trim_changes(CHANGES_KEPT)?;
        self.store().prune_done_uploads()?;
        Ok(self.anchor()? != before)
    }

    /// Brings the store level with every node the member can see now: drops
    /// what went out of view and fetches what came into view or changed.
    /// `full` after an access change: roles (`can_write`) can change without a
    /// node's sequence moving, so every node still in view is fetched again.
    pub fn reconcile(&self, full: bool) -> DiskResult<()> {
        let mut remote = std::collections::HashMap::new();
        let mut after = String::new();
        loop {
            let page = self.api().keys(&after)?;
            for (k, seq) in page.keys {
                remote.insert(k, seq);
            }
            match page.next {
                Some(n) => after = n,
                None => break,
            }
        }
        let local = self.store().all_ids()?;
        let local_map: std::collections::HashMap<_, _> = local.iter().cloned().collect();
        let gone: Vec<String> = local.iter().filter(|(id, _)| id != SHARED_ID && !remote.contains_key(id)).map(|(id, _)| id.clone()).collect();
        let stale: Vec<String> =
            remote.iter().filter(|(id, seq)| full || local_map.get(*id) != Some(*seq)).map(|(id, _)| id.clone()).collect();
        for batch in stale.chunks(HYDRATE_BATCH) {
            let nodes = self.api().nodes(batch)?;
            let rows: Vec<NodeRow> = nodes.iter().map(|n| self.ingest(n)).collect::<DiskResult<_>>()?;
            self.store().transaction(|s| rows.iter().try_for_each(|r| s.upsert(r).map(|_| ())))?;
        }
        // Only what left view goes; a child still granted under a parent that
        // left stays, and rehome_orphans puts it under Shared with me.
        self.store().transaction(|s| gone.iter().try_for_each(|id| s.delete_one(id)))?;
        Ok(())
    }

    /// Turns an API node into a store row, opening sealed names where the key
    /// is on this Mac.
    fn ingest(&self, n: &ApiNode) -> DiskResult<NodeRow> {
        let parent_id = n.parent_id.clone().unwrap_or_else(|| ROOT_ID.to_string());
        let root_name = || match n.drive.as_deref() {
            Some("c") | Some("C") => MY_FILES.to_string(),
            _ => n.share_name.clone().or_else(|| n.name.clone()).unwrap_or_else(|| "Shared".into()),
        };
        let ts = n.content_modified_at.as_deref().or(n.updated_at.as_deref());
        let modified_at = ts.and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok()).map(|t| t.timestamp()).unwrap_or(0);
        let v = n.current_version.as_ref();
        let mut row = NodeRow {
            id: n.id.clone(),
            parent_id: parent_id.clone(),
            kind: n.kind.clone(),
            name: if n.parent_id.is_none() { Some(root_name()) } else { n.name.clone() },
            mime: n.mime.clone(),
            sealed: n.sealed,
            scope_id: n.seal_scope_id.clone(),
            meta_ct: n.metadata_ciphertext.clone(),
            key_epoch: n.key_epoch,
            size: v.map(|v| v.size_bytes).unwrap_or(n.size_bytes),
            stored_size: v.map(|v| v.size_bytes).unwrap_or(0),
            modified_at,
            version_id: v.map(|v| v.id.clone()),
            wrapped_key: v.and_then(|v| v.wrapped_key.clone()),
            manifest_ct: v.and_then(|v| v.manifest_ciphertext.clone()),
            version_epoch: v.and_then(|v| v.key_epoch),
            can_write: n.can_write,
            change_seq: n.change_seq,
            locked: false,
            drive: n.drive.as_ref().map(|d| if d.eq_ignore_ascii_case("c") { "c".to_string() } else { d.clone() }),
        };
        if n.sealed && n.parent_id.is_some() {
            let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
            match keys.open_node(&api, &row) {
                Ok(opened) => {
                    row.name = Some(opened.name);
                    row.mime = opened.mime;
                    if let Some(size) = opened.size {
                        row.size = size;
                    }
                }
                // No network: fail the pull so the cursor stays and it runs again.
                Err(e) if e.is_transient() => return Err(e),
                Err(_) => {
                    row.name = None;
                    row.locked = true;
                }
            }
        }
        Ok(row)
    }

    // ── downloads ────────────────────────────────────────────────────────

    fn staging(&self) -> DiskResult<PathBuf> {
        let d = self.dir.join(STAGING_DIR);
        fs::create_dir_all(&d)?;
        Ok(d)
    }

    /// Downloads the item's current content to a file macOS takes over, and
    /// returns its path. A dropped connection keeps the partial file, so the
    /// next call continues with a Range request from where it stopped.
    /// The server's thumbnail for a file Finder shows, without downloading the
    /// file. `None` for folders, sealed files (their thumbnails are sealed too)
    /// and types the server does not thumbnail.
    pub fn thumbnail(&self, id: &str) -> DiskResult<Option<Vec<u8>>> {
        let node = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        if node.sealed || node.locked || node.is_folder() || node.kind == KIND_PAGE {
            return Ok(None);
        }
        let Some(version) = node.version_id.as_deref() else { return Ok(None) };
        if !has_server_thumbnail(node.name.as_deref().unwrap_or("")) {
            return Ok(None);
        }
        let api = self.api();
        let url = match api.thumbnail_url(version) {
            Ok(u) => u,
            Err(DiskError::NotFound) => return Ok(None),
            Err(e) => return Err(e),
        };
        match api.get_small(&url, MAX_THUMBNAIL_BYTES) {
            Ok(b) => Ok(Some(b)),
            Err(DiskError::NotFound) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// The item's inbox2 link, for "Copy inbox2 link" in Finder.
    pub fn link(&self, id: &str) -> DiskResult<String> {
        self.store().node(id)?.ok_or(DiskError::NotFound)?;
        self.api().link(id)
    }

    pub fn fetch(&self, id: &str, progress: &dyn Progress) -> DiskResult<PathBuf> {
        let node = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        if node.kind == KIND_PAGE {
            return self.page_stub(&node);
        }
        if node.is_folder() {
            return Err(DiskError::Other("folders have no content".into()));
        }
        if node.locked {
            return Err(DiskError::Locked);
        }
        let version = node.version_id.clone().ok_or(DiskError::NotFound)?;
        let gate = self.fetching.lock().unwrap_or_else(|p| p.into_inner()).entry(version.clone()).or_default().clone();
        let _one = gate.lock().unwrap_or_else(|p| p.into_inner());
        // Version objects never change, so a partial file is safe to continue.
        let partial = self.staging()?.join(format!("{version}.part"));
        let ciphertext_total = self.download_resumable(&version, &partial, node.sealed, node.size, node.stored_size, progress)?;
        let out = self.staging()?.join(format!("{version}.done"));
        if node.sealed {
            let len = fs::metadata(&partial)?.len();
            if node.stored_size > 0 && len != node.stored_size {
                // Kept: the next call continues it with a Range request.
                return Err(DiskError::Offline(format!("download ended at {len} of {} bytes", node.stored_size)));
            }
            let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
            keys.decrypt_file(&api, &node, &partial, &out)?;
            let _ = fs::remove_file(&partial);
        } else {
            let len = fs::metadata(&partial)?.len();
            if len != ciphertext_total {
                let _ = fs::remove_file(&partial);
                return Err(DiskError::Offline(format!("download ended at {len} of {ciphertext_total} bytes")));
            }
            fs::rename(&partial, &out)?;
        }
        Ok(out)
    }

    fn download_resumable(&self, version: &str, partial: &Path, sealed: bool, size: u64, stored_size: u64, progress: &dyn Progress) -> DiskResult<u64> {
        let mut have = fs::metadata(partial).map(|m| m.len()).unwrap_or(0);
        // A download that finished before the last step was cut off: nothing
        // left to ask storage for (a range at the end would answer 416).
        if stored_size > 0 && have == stored_size {
            return Ok(stored_size);
        }
        if have > stored_size && stored_size > 0 {
            let _ = fs::remove_file(partial);
            have = 0;
        }
        let url = self.api().download_url(version)?;
        let mut resp = self.api().get_from(&url, have)?;
        if have > 0 && resp.status().as_u16() == 200 {
            // Storage ignored the range: start over.
            have = 0;
        }
        let total = match resp.headers().get("content-range").and_then(|v| v.to_str().ok()) {
            Some(cr) => cr.rsplit('/').next().and_then(|t| t.parse().ok()).unwrap_or(0),
            None => resp.content_length().unwrap_or(0) + have,
        };
        let total = if total == 0 && !sealed { size } else { total };
        let mut f = OpenOptions::new().create(true).write(true).truncate(have == 0).open(partial)?;
        f.seek(SeekFrom::Start(have))?;
        let mut buf = vec![0u8; 256 * 1024];
        let mut done = have;
        let limit = Throttle::new(self.cfg().download_kbps);
        loop {
            if progress.is_cancelled() {
                return Err(DiskError::Other("cancelled".into()));
            }
            let n = match resp.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => {
                    f.sync_all()?;
                    return Err(DiskError::Offline(format!("download stopped: {e}")));
                }
            };
            f.write_all(&buf[..n])?;
            limit.wait(n as u64);
            done += n as u64;
            progress.progress(done, total);
        }
        f.sync_all()?;
        Ok(total)
    }

    /// A Disk page in Finder: a small file that opens the page in inbox2.
    fn page_stub(&self, node: &NodeRow) -> DiskResult<PathBuf> {
        let out = self.staging()?.join(format!("{}.page", node.id));
        let body = json!({
            "inbox2_page": node.id,
            "org": self.cfg().org,
            // The web app finds a node by its short id alone (lib/disk/model.js, parseDiskPath).
            "url": format!("{}/disk/shared/{}", self.cfg().web_base.trim_end_matches('/'), node.id.trim_start_matches("dnd_")),
        });
        fs::write(&out, serde_json::to_vec_pretty(&body).unwrap_or_default())?;
        Ok(out)
    }

    // ── Mac → remote ─────────────────────────────────────────────────────

    /// A retry after a lost answer must not make a second folder: a sealed
    /// folder keeps its proposed id before the request and is looked up by it;
    /// an unsealed one that clashes is the folder already there.
    /// `op_id` names this one create (macOS's identifier for the new item) and
    /// stays the same when macOS retries it.
    pub fn create_folder(&self, parent_id: &str, name: &str, op_id: &str) -> DiskResult<DiskItem> {
        let parent = self.writable_parent(parent_id)?;
        // op → folder id, kept: a retry of this create (sealed or not) returns
        // the folder it made. ponytail: one small state row per folder made.
        let made_key = format!("made:{op_id}");
        let made = self.store().get_state(&made_key)?.filter(|v| !v.is_empty());
        if let Some(id) = &made {
            match self.refresh(id) {
                Ok(item) => return Ok(item),
                Err(DiskError::NotFound) => {}
                Err(e) => return Err(e),
            }
        }
        let body = if parent.sealed {
            // The proposed id is saved before the request, so a lost answer is found by it.
            let id = made.unwrap_or_else(|| super::sealed::new_proposed_id("dnd"));
            self.store().set_state(&made_key, &id)?;
            let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
            keys.sealed_folder_body(&api, &parent, name, &id)?
        } else {
            json!({ "parent_id": parent_id, "name": name })
        };
        let scope = parent.scope_id.as_deref().or(Some(parent.id.as_str())).filter(|_| parent.sealed);
        let created = match self.epoch_retry(scope, self.api().create_folder(&body)) {
            // ponytail: a same-name folder is merged into, as Dropbox does, whoever
            // made it; that also covers a retry after a lost answer.
            Err(DiskError::NameTaken(_)) if !parent.sealed => {
                self.sync()?;
                let existing = self.store().children(parent_id)?.into_iter()
                    .find(|c| c.is_folder() && c.name.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(name)));
                let existing = existing.ok_or_else(|| DiskError::NameTaken(name.to_string()))?;
                self.store().set_state(&made_key, &existing.id)?;
                return Ok(existing.item());
            }
            other => other?,
        };
        let id = created["node"]["id"].as_str().or_else(|| created["id"].as_str()).ok_or(DiskError::Other("no id".into()))?;
        self.store().set_state(&made_key, id)?;
        self.refresh(id)
    }

    /// `op_id` as for `create_folder`: a retried create finds its own upload.
    pub fn create_file(&self, parent_id: &str, name: &str, src: &Path, op_id: &str, progress: &dyn Progress) -> DiskResult<DiskItem> {
        let parent = self.writable_parent(parent_id)?;
        let local_key = format!("new:{op_id}");
        let node = self.upload(&local_key, Target::New { parent: &parent, name }, None, src, progress)?;
        match self.refresh(&node.id) {
            Ok(item) => {
                // Kept, marked done: a create macOS retries (its reply was lost)
                // finds this reservation done and gets the same node.
                self.store().mark_upload_done(&local_key)?;
                Ok(item)
            }
            // The earlier file is gone (deleted since): this is a new create.
            Err(DiskError::NotFound) => {
                self.abandon(&local_key)?;
                let node = self.upload(&local_key, Target::New { parent: &parent, name }, None, src, progress)?;
                let item = self.refresh(&node.id)?;
                self.store().mark_upload_done(&local_key)?;
                Ok(item)
            }
            Err(e) => Err(e),
        }
    }

    /// New content for an existing file. `base_version` is the version macOS
    /// says the edit started from; when the server has moved on, the server's
    /// file stays and the Mac's copy is uploaded next to it.
    pub fn modify_contents(&self, id: &str, base_version: &str, src: &Path, progress: &dyn Progress) -> DiskResult<DiskWrite> {
        let node = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        if node.kind == KIND_PAGE {
            return Err(DiskError::NoPermission("pages open in inbox2".into()));
        }
        if !node.can_write || node.locked {
            return Err(DiskError::NoPermission(String::new()));
        }
        let base = (!base_version.is_empty()).then_some(base_version);
        // One key per edit (the file and the version it started from): a retry
        // macOS sends after losing the reply finds the finished upload.
        let edit_key = format!("edit:{id}:{}", base.unwrap_or(""));
        let copy_key = format!("copy:{id}:{}", base.unwrap_or(""));
        let conflicted = self.store().upload_for(&copy_key)?.is_some();
        let result = if conflicted { Err(DiskError::Other("version_conflict".into())) } else { self.upload(&edit_key, Target::Version { node: &node }, base, src, progress) };
        match result {
            Ok(_) => {
                let item = self.refresh(id)?;
                self.store().mark_upload_done(&edit_key)?;
                Ok(DiskWrite { item, conflict_copy: None })
            }
            Err(DiskError::Other(code)) if code == "version_conflict" => {
                let parent = self.conflict_folder(&node)?;
                let name = conflicted_name(node.name.as_deref().unwrap_or("File"), &self.cfg().member_name, chrono::Local::now().date_naive());
                let copy = self.upload(&copy_key, Target::New { parent: &parent, name: &name }, None, src, progress)?;
                let copy = self.refresh(&copy.id)?;
                let item = self.refresh(id)?;
                self.store().mark_upload_done(&copy_key)?;
                Ok(DiskWrite { item, conflict_copy: Some(copy) })
            }
            Err(e) => Err(e),
        }
    }

    /// Where a conflicted copy goes: beside the file, or in My files when the
    /// file's folder is "Shared with me" or read-only for this member.
    fn conflict_folder(&self, node: &NodeRow) -> DiskResult<NodeRow> {
        let store = self.store();
        if let Some(p) = store.node(&node.parent_id)?.filter(|p| p.id != SHARED_ID && p.can_write && !p.locked) {
            return Ok(p);
        }
        store
            .children(ROOT_ID)?
            .into_iter()
            .find(|r| r.drive.as_deref() == Some("c") && r.can_write)
            .ok_or_else(|| DiskError::NoPermission("no folder to keep a conflicted copy in".into()))
    }

    pub fn rename(&self, id: &str, name: &str) -> DiskResult<DiskItem> {
        let node = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        let name = name.strip_suffix(&format!(".{PAGE_EXTENSION}")).filter(|_| node.kind == KIND_PAGE).unwrap_or(name);
        let body = if node.sealed {
            let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
            keys.sealed_rename_body(&api, &node, name)?
        } else {
            json!({ "name": name })
        };
        self.epoch_retry(node.scope_id.as_deref().filter(|_| node.sealed), self.api().rename(id, &body))?;
        self.refresh(id)
    }

    pub fn move_to(&self, id: &str, parent_id: &str) -> DiskResult<DiskItem> {
        let target = self.writable_parent(parent_id)?;
        let node = self.store().node(id)?.ok_or(DiskError::NotFound)?;
        // Into, out of or between sealed scopes the keys change, and the server
        // takes that only with every name and version key re-wrapped: do it in inbox2.
        let scope_of = |n: &NodeRow| n.sealed.then(|| n.scope_id.clone().unwrap_or_else(|| n.id.clone()));
        // A sealed folder's root keeps its own key wherever it sits among
        // ordinary folders; only crossing into or out of a scope changes keys.
        let root_among_plain = scope_of(&node).as_deref() == Some(node.id.as_str()) && !target.sealed;
        if scope_of(&node) != scope_of(&target) && !root_among_plain {
            return Err(DiskError::NoPermission("move sealed items in inbox2".into()));
        }
        self.api().move_node(id, parent_id)?;
        self.refresh(id)
    }

    /// Moves the item to the inbox2 trash, where it can be restored.
    pub fn delete(&self, id: &str) -> DiskResult<()> {
        if id == ROOT_ID || self.store().node(id)?.is_some_and(|n| n.parent_id == ROOT_ID) {
            return Err(DiskError::NoPermission("drives can't be deleted".into()));
        }
        match self.api().trash(id) {
            Ok(_) | Err(DiskError::NotFound) => {}
            Err(e) => return Err(e),
        }
        let store = self.store();
        // Children granted on their own stay visible: the next pull reconciles
        // and they come back under Shared with me.
        if store.has_children(id)? && store.get_state("reconcile_pending")?.as_deref() != Some("full") {
            store.set_state("reconcile_pending", "1")?;
        }
        store.delete_subtree(id)
    }

    fn writable_parent(&self, parent_id: &str) -> DiskResult<NodeRow> {
        if parent_id == ROOT_ID {
            return Err(DiskError::NoPermission("add files inside My files or a share".into()));
        }
        let p = self.store().node(parent_id)?.ok_or(DiskError::NotFound)?;
        if !p.can_write || p.locked {
            return Err(DiskError::NoPermission(String::new()));
        }
        Ok(p)
    }

    /// Fetches one node from the feed's shape and stores it.
    fn refresh(&self, id: &str) -> DiskResult<DiskItem> {
        let nodes = self.api().nodes(&[id.to_string()])?;
        let n = nodes.first().ok_or(DiskError::NotFound)?;
        let row = self.ingest(n)?;
        self.store().upsert(&row)?;
        Ok(row.item())
    }

    /// The resumable upload. The reservation id is kept in the store against
    /// `local_key` with a fingerprint of the source, so a retry after a lost
    /// connection or a restart continues with the parts storage lacks.
    ///
    /// Sealed: reserve first (the manifest binds the version id the server
    /// hands out), then seal to a staging file with a fresh version key. The
    /// wrapped key and prefix are kept with the reservation, so a resume
    /// re-seals to the same bytes.
    fn upload(&self, local_key: &str, target: Target, base: Option<&str>, src: &Path, progress: &dyn Progress) -> DiskResult<ApiNode> {
        let (sealed, scope_id, mime) = match &target {
            Target::New { parent, name } => {
                (parent.sealed, parent.scope_id.clone().unwrap_or_else(|| parent.id.clone()), mime_for(name))
            }
            Target::Version { node } => (node.sealed, node.scope_id.clone().unwrap_or_default(), node.mime.clone().unwrap_or_else(|| mime_for(""))),
        };
        let fingerprint = fingerprint(src)?;
        let plain_size = fs::metadata(src)?.len();
        let chunk_bytes = super::sealed::chunk_bytes_for(Some(&mime)) as u64;
        let size = if sealed { super::sealed::cipher_size(plain_size, chunk_bytes) } else { plain_size };

        let mut resumed: Option<(ApiUpload, Vec<u32>, Option<SealedRecord>)> = None;
        if let Some((upload_id, fp, rec)) = self.store().upload_for(local_key)? {
            if fp == fingerprint {
                let rec = rec.and_then(|r| serde_json::from_str::<SealedRecord>(&r).ok());
                // A sealed reservation resumes only with its record: without it the
                // bytes can't be sealed the same way (and plaintext must never go).
                if !sealed || rec.is_some() {
                    // "completing" and "done" count too: a lost answer to complete leaves them so.
                    resumed = self.api().upload_state(&upload_id)?.filter(|(u, _)| u.state != "aborted").map(|(u, p)| (u, p, rec));
                }
            }
            if resumed.is_none() {
                let _ = self.api().abort(&upload_id);
                self.abandon(local_key)?;
            }
        }
        let (upload, have, rec) = match resumed {
            Some(r) => r,
            None => {
                let mut body = match &target {
                    Target::New { parent, name } => {
                        let name = if sealed { self.free_sealed_name(&parent.id, name)? } else { name.to_string() };
                        json!({ "parent_id": parent.id, "name": if sealed { Value::Null } else { json!(name) },
                                "on_conflict": "keep_both", "_name": name })
                    }
                    Target::Version { node } => json!({ "node_id": node.id }),
                };
                body["size_bytes"] = json!(size);
                // The attempt moves on whenever a reservation is abandoned, so the
                // next reserve is a new one rather than the dead one handed back.
                body["idempotency_key"] = json!(format!("{local_key}|{fingerprint}|{}", self.attempt(local_key)?));
                let mut seal = None;
                if sealed {
                    let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
                    let new_name = matches!(target, Target::New { .. }).then(|| body["_name"].as_str().unwrap_or("").to_string());
                    let (fields, kv, prefix) = keys.reserve_fields(&api, &scope_id, new_name.as_deref().map(|n| (n, mime.as_str())), chunk_bytes)?;
                    merge(&mut body, &fields);
                    seal = Some((kv, prefix));
                }
                if let Some(o) = body.as_object_mut() {
                    o.remove("_name");
                    if sealed {
                        o.remove("name");
                        o.remove("on_conflict");
                    }
                }
                let up = self.epoch_retry(Some(scope_id.as_str()).filter(|_| sealed), self.api().reserve(&body))?;
                let rec = match seal {
                    Some((kv, prefix)) => {
                        let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
                        Some(keys.record(&api, &scope_id, &up, &kv, &prefix, chunk_bytes)?)
                    }
                    None => None,
                };
                let rec_json = rec.as_ref().map(|r| serde_json::to_string(r).unwrap_or_default());
                self.store().save_upload(local_key, &up.id, &fingerprint, rec_json.as_deref())?;
                (up, Vec::new(), rec)
            }
        };

        // The same idempotency key can hand back a reservation already finished.
        // The caller forgets the reservation once it has read the item back.
        if upload.state == "done" {
            let id = upload.node_id.clone().ok_or(DiskError::NotFound)?;
            return self.api().nodes(&[id])?.into_iter().next().ok_or(DiskError::NotFound);
        }
        let completing = upload.state == "completing";

        let staged = self.staging()?.join(format!("{}.sealed", upload.id));
        let (path, complete) = match &rec {
            Some(rec) => {
                let api = self.api();
            let mut keys = self.keys.lock().unwrap_or_else(|p| p.into_inner());
                (staged.clone(), keys.seal_to(&api, &scope_id, rec, src, &staged)?)
            }
            None if sealed => return Err(DiskError::Other("sealed upload without its record".into())),
            None => (src.to_path_buf(), json!({ "sha256": sha256_file(src)? })),
        };
        let size = fs::metadata(&path)?.len();

        // A completing upload has all its parts; only the completion is retried.
        let missing: Vec<u32> = if completing { Vec::new() } else { (1..=upload.part_count).filter(|n| !have.contains(n)).collect() };
        let mut done = have.len() as u64 * upload.part_bytes;
        let mut file = File::open(&path)?;
        let limit = Throttle::new(self.cfg().upload_kbps);
        for batch in missing.chunks(PARTS_PER_CALL) {
            for part in self.api().part_urls(&upload.id, batch)?.into_iter().filter(|p| batch.contains(&p.number)) {
                if progress.is_cancelled() {
                    return Err(DiskError::Other("cancelled".into()));
                }
                let offset = (part.number as u64 - 1) * upload.part_bytes;
                let len = upload.part_bytes.min(size - offset) as usize;
                let mut buf = vec![0u8; len];
                file.seek(SeekFrom::Start(offset))?;
                file.read_exact(&mut buf)?;
                self.api().put_part(&part.url, buf)?;
                limit.wait(len as u64);
                done += len as u64;
                progress.progress(done.min(size), size);
            }
        }

        let mut body = complete;
        if let Some(b) = base {
            body["base_version"] = json!(b);
        }
        let result = self.api().complete(&upload.id, &body);
        if rec.is_some() {
            let _ = fs::remove_file(&staged);
        }
        match result {
            Err(DiskError::Other(code)) if code == "version_conflict" || code == "epoch_changed" => {
                let _ = self.api().abort(&upload.id);
                self.abandon(local_key)?;
                if code == "epoch_changed" {
                    self.keys.lock().unwrap_or_else(|p| p.into_inner()).forget(&scope_id);
                    // A rotation happened mid-upload: macOS retries with the new key.
                    return Err(DiskError::Offline("the sealed folder's key changed".into()));
                }
                Err(DiskError::Other(code))
            }
            Err(e) => Err(e),
            // Kept until the caller has read the item back, so a retry after a
            // failed read finds this reservation done instead of making a copy.
            Ok(node) => Ok(node),
        }
    }

    /// A sealed write refused because the scope's key rotated: drop the cached
    /// key and answer retryable, so macOS calls again and the new epoch is used.
    fn epoch_retry<T>(&self, scope: Option<&str>, result: DiskResult<T>) -> DiskResult<T> {
        match (scope, result) {
            (Some(scope), Err(DiskError::Other(code))) if code == "epoch_changed" => {
                self.keys.lock().unwrap_or_else(|p| p.into_inner()).forget(scope);
                Err(DiskError::Offline("the sealed folder's key changed".into()))
            }
            (_, r) => r,
        }
    }

    fn attempt(&self, local_key: &str) -> DiskResult<u64> {
        Ok(self.store().get_state(&format!("attempt:{local_key}"))?.and_then(|v| v.parse().ok()).unwrap_or(0))
    }

    /// Forgets a reservation and moves the attempt on (see the idempotency key).
    fn abandon(&self, local_key: &str) -> DiskResult<()> {
        let next = self.attempt(local_key)? + 1;
        let store = self.store();
        store.drop_upload(local_key)?;
        store.set_state(&format!("attempt:{local_key}"), &next.to_string())
    }

    /// Names in a sealed folder are unique only because clients check
    /// (build guide 10): pick "a (1).pdf" the way the server would.
    /// ponytail: two devices saving the same name in the same second can still
    /// both win, as on the web; the server can't compare sealed names.
    fn free_sealed_name(&self, parent_id: &str, name: &str) -> DiskResult<String> {
        // Names another device added since the last pull count too.
        self.sync()?;
        let taken: std::collections::HashSet<String> =
            self.store().children(parent_id)?.iter().filter_map(|c| c.name.as_ref().map(|n| n.to_lowercase())).collect();
        let (stem, ext) = match name.rfind('.') {
            Some(i) if i > 0 => (&name[..i], &name[i..]),
            _ => (name, ""),
        };
        let mut candidate = name.to_string();
        let mut n = 0;
        while taken.contains(&candidate.to_lowercase()) {
            n += 1;
            candidate = format!("{stem} ({n}){ext}");
        }
        Ok(candidate)
    }
}

/// A MIME type from the file name, for sealed metadata and chunk size.
fn mime_for(name: &str) -> String {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "heic" => "image/heic",
        "txt" | "md" => "text/plain",
        "csv" => "text/csv",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "zip" => "application/zip",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Keeps a transfer at or under a KiB/s limit by sleeping between writes.
struct Throttle {
    kbps: u64,
    start: std::time::Instant,
    sent: std::cell::Cell<u64>,
}

impl Throttle {
    fn new(kbps: u32) -> Self {
        Self { kbps: kbps as u64, start: std::time::Instant::now(), sent: std::cell::Cell::new(0) }
    }

    fn wait(&self, bytes: u64) {
        if self.kbps == 0 {
            return;
        }
        self.sent.set(self.sent.get() + bytes);
        let due = std::time::Duration::from_secs_f64(self.sent.get() as f64 / (self.kbps as f64 * 1024.0));
        if let Some(rest) = due.checked_sub(self.start.elapsed()) {
            std::thread::sleep(rest);
        }
    }
}

/// Where an upload goes.
pub enum Target<'a> {
    New { parent: &'a NodeRow, name: &'a str },
    Version { node: &'a NodeRow },
}

fn merge(into: &mut Value, from: &Value) {
    if let (Some(a), Some(b)) = (into.as_object_mut(), from.as_object()) {
        for (k, v) in b {
            a.insert(k.clone(), v.clone());
        }
    }
}

/// The content's SHA-256: other bytes start a new upload, the same bytes
/// resume (or find the finished one) whatever their timestamp.
fn fingerprint(p: &Path) -> DiskResult<String> {
    sha256_file(p)
}

pub fn sha256_file(p: &Path) -> DiskResult<String> {
    let mut f = File::open(p)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex(&h.finalize()))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// "Offer.docx" → "Offer (Waseem's conflicted copy 2026-11-22).docx"
/// Thumbnails are 480 px JPEGs; anything past this is not one.
const MAX_THUMBNAIL_BYTES: u64 = 4 * 1024 * 1024;

/// The types api/app/services/disk/thumbnailer.rb makes thumbnails for, so
/// Finder never asks the server about a file that cannot have one.
const THUMBNAIL_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", // images
    "cr2", "cr3", "nef", "nrw", "arw", "dng", "raf", "orf", "rw2", "pef", "srw", // camera RAW
    "mp4", "m4v", "mov", "mkv", "webm", "avi", // video
    "pdf",
];

pub fn has_server_thumbnail(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, ext)| THUMBNAIL_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

pub fn conflicted_name(name: &str, who: &str, day: chrono::NaiveDate) -> String {
    let who = if who.trim().is_empty() { "My".to_string() } else { format!("{}'s", who.trim()) };
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    format!("{stem} ({who} conflicted copy {}){ext}", day.format("%Y-%m-%d"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflicted_copy_names() {
        let d = chrono::NaiveDate::from_ymd_opt(2026, 11, 22).unwrap();
        assert_eq!(conflicted_name("Offer.docx", "Waseem", d), "Offer (Waseem's conflicted copy 2026-11-22).docx");
        assert_eq!(conflicted_name("README", "", d), "README (My conflicted copy 2026-11-22)");
        assert_eq!(conflicted_name(".env", "Ali", d), ".env (Ali's conflicted copy 2026-11-22)");
    }

    #[test]
    fn thumbnails_only_for_types_the_server_makes() {
        assert!(has_server_thumbnail("Logo.PNG"));
        assert!(has_server_thumbnail("clip.mov"));
        assert!(has_server_thumbnail("Offer.pdf"));
        assert!(!has_server_thumbnail("Offer.docx"));
        assert!(!has_server_thumbnail("png"));
    }

    #[test]
    fn config_roundtrips_and_is_private() {
        let dir = tempfile::tempdir().unwrap();
        let c = DiskConfig { api_base: "http://x/api/v1".into(), org: "org_a".into(), token: "t".into(), ..Default::default() };
        write_config(dir.path(), &c).unwrap();
        assert_eq!(read_config(dir.path()).unwrap().org, "org_a");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(dir.path().join(CONFIG_FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }
}

#[cfg(test)]
mod throttle_tests {
    use super::Throttle;

    #[test]
    fn throttle_holds_the_rate() {
        let t = Throttle::new(100); // 100 KiB/s
        let start = std::time::Instant::now();
        t.wait(20 * 1024);
        assert!(start.elapsed() >= std::time::Duration::from_millis(190));
        let free = Throttle::new(0);
        let s = std::time::Instant::now();
        free.wait(1 << 30);
        assert!(s.elapsed() < std::time::Duration::from_millis(5));
    }
}
