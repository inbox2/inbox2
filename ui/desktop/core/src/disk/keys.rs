//! Sealed scope keys on this Mac (docs/plans/disk-build.md section 6).
//!
//! The member's identity secret comes from `config.json`, which the desktop
//! app writes only while FileVault is on. Scope keys are opened from the
//! member's key grants on demand and held in memory for this process only.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufReader, BufWriter};
use std::path::Path;

use base64::Engine as _;
use serde_json::{json, Value};

use super::api::DiskApi;
use super::model::*;
use super::sealed::{self as x, Key};
use super::store::NodeRow;

const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

pub struct Opened {
    pub name: String,
    pub mime: Option<String>,
    pub size: Option<u64>,
}

/// What a sealed upload needs to resume with the same bytes: the version key
/// travels wrapped, the prefix is not secret (build guide 6.6, "Resume").
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SealedRecord {
    pub node_id: String,
    pub version_id: String,
    pub epoch: i64,
    pub chunk_bytes: u64,
    pub prefix: String,
    pub wrapped_key: String,
}

struct Scope {
    epoch: i64,
    keys: HashMap<i64, Key>,
}

pub struct ScopeKeys {
    identity: Option<Key>,
    scopes: HashMap<String, Scope>,
}

fn unb64(s: &str) -> DiskResult<Vec<u8>> {
    B64.decode(s).map_err(|_| DiskError::Other("bad base64".into()))
}

fn sealed_err(e: x::SealError) -> DiskError {
    log::warn!("[disk] sealed: {e}");
    DiskError::Locked
}

impl ScopeKeys {
    pub fn new(secret: Option<String>, _public: Option<String>) -> Self {
        let identity = secret.and_then(|s| B64.decode(s).ok()).and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok()).map(Key::new);
        Self { identity, scopes: HashMap::new() }
    }

    pub fn has_identity(&self) -> bool {
        self.identity.is_some()
    }

    /// Opens every grant this member holds on the scope and walks the epoch
    /// chain back from the newest, so older versions open too.
    fn load(&mut self, api: &DiskApi, scope_id: &str) -> DiskResult<()> {
        let identity = self.identity.as_ref().ok_or(DiskError::Locked)?;
        let scope = api.scope(scope_id)?;
        let newest = scope.grants.iter().max_by_key(|g| g.epoch).ok_or(DiskError::Locked)?;
        let top = x::open_key_grant(&unb64(&newest.sealed_key)?, identity).map_err(sealed_err)?;
        let chain: HashMap<u64, Vec<u8>> =
            scope.epochs.iter().filter_map(|e| Some((e.epoch as u64, B64.decode(&e.previous_key_wrapped).ok()?))).collect();
        let mut keys = HashMap::new();
        for e in 1..=newest.epoch {
            if let Ok(k) = x::walk_epochs(&top, newest.epoch as u64, e as u64, scope_id, |n| chain.get(&n).cloned()) {
                keys.insert(e, k);
            }
        }
        self.scopes.insert(scope_id.to_string(), Scope { epoch: scope.epoch, keys });
        Ok(())
    }

    /// `K_s[epoch]`, fetching the scope again once when the epoch is newer
    /// than what this process holds (a rotation since).
    fn key(&mut self, api: &DiskApi, scope_id: &str, epoch: i64) -> DiskResult<x::ScopeKeys> {
        if !self.scopes.get(scope_id).is_some_and(|s| s.keys.contains_key(&epoch)) {
            self.load(api, scope_id)?;
        }
        let ks = self.scopes.get(scope_id).and_then(|s| s.keys.get(&epoch)).ok_or(DiskError::Locked)?;
        Ok(x::ScopeKeys::derive(ks))
    }

    /// The scope's current epoch and its keys, for writes.
    fn current(&mut self, api: &DiskApi, scope_id: &str) -> DiskResult<(i64, x::ScopeKeys)> {
        if !self.scopes.contains_key(scope_id) {
            self.load(api, scope_id)?;
        }
        let epoch = self.scopes[scope_id].epoch;
        Ok((epoch, self.key(api, scope_id, epoch)?))
    }

    /// Drops cached keys so the next use fetches the scope again (after a
    /// 409 epoch_changed).
    pub fn forget(&mut self, scope_id: &str) {
        self.scopes.remove(scope_id);
    }

    fn version_key(&mut self, api: &DiskApi, n: &NodeRow) -> DiskResult<(Key, x::Manifest)> {
        let scope = n.scope_id.as_deref().ok_or(DiskError::Locked)?;
        let version = n.version_id.as_deref().ok_or(DiskError::NotFound)?;
        let w = self.key(api, scope, n.version_epoch.or(n.key_epoch).ok_or(DiskError::Locked)?)?;
        let kv = x::unwrap_version_key(&w.w, &n.id, version, &unb64(n.wrapped_key.as_deref().ok_or(DiskError::Locked)?)?)
            .map_err(sealed_err)?;
        let vk = x::VersionKeys::derive(&kv);
        let manifest = x::open_manifest(&vk.f, &n.id, version, &unb64(n.manifest_ct.as_deref().ok_or(DiskError::Locked)?)?)
            .map_err(sealed_err)?;
        Ok((kv, manifest))
    }

    pub fn open_node(&mut self, api: &DiskApi, n: &NodeRow) -> DiskResult<Opened> {
        let scope = n.scope_id.as_deref().ok_or(DiskError::Locked)?;
        let m = self.key(api, scope, n.key_epoch.ok_or(DiskError::Locked)?)?;
        let meta = x::open_meta(&m.m, &n.id, &unb64(n.meta_ct.as_deref().ok_or(DiskError::Locked)?)?).map_err(sealed_err)?;
        let size = if n.kind == KIND_FILE && n.version_id.is_some() { Some(self.version_key(api, n)?.1.size) } else { None };
        Ok(Opened { name: meta.name, mime: meta.mime, size })
    }

    /// Decrypts a downloaded sealed object into `dst`. Any failure removes the
    /// half-written plaintext.
    pub fn decrypt_file(&mut self, api: &DiskApi, n: &NodeRow, src: &Path, dst: &Path) -> DiskResult<()> {
        let (kv, manifest) = self.version_key(api, n)?;
        let opener = x::ChunkOpener::new(&kv, manifest).map_err(sealed_err)?;
        let tmp = dst.with_extension("opening");
        let res = (|| {
            let out = BufWriter::new(File::create(&tmp)?);
            opener.open(BufReader::new(File::open(src)?), out).map_err(sealed_err)?;
            fs::rename(&tmp, dst)?;
            Ok(())
        })();
        if res.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        res
    }

    /// `id` is the proposed id, kept by the caller so a retry reuses it.
    pub fn sealed_folder_body(&mut self, api: &DiskApi, parent: &NodeRow, name: &str, id: &str) -> DiskResult<Value> {
        let scope = parent.scope_id.clone().unwrap_or_else(|| parent.id.clone());
        let (epoch, k) = self.current(api, &scope)?;
        let meta = x::seal_meta(&k.m, id, name, None).map_err(sealed_err)?;
        Ok(json!({ "parent_id": parent.id, "sealed": true, "id": id, "metadata_ciphertext": B64.encode(meta), "key_epoch": epoch }))
    }

    pub fn sealed_rename_body(&mut self, api: &DiskApi, n: &NodeRow, name: &str) -> DiskResult<Value> {
        let scope = n.scope_id.as_deref().ok_or(DiskError::Locked)?;
        let (epoch, k) = self.current(api, scope)?;
        let mime = if n.kind == KIND_FILE { n.mime.as_deref() } else { None };
        let meta = x::seal_meta(&k.m, &n.id, name, mime).map_err(sealed_err)?;
        Ok(json!({ "metadata_ciphertext": B64.encode(meta), "key_epoch": epoch }))
    }

    /// Reserve fields for a sealed upload: a new file brings its proposed id
    /// and sealed name. Returns the fields, the fresh version key and prefix.
    pub fn reserve_fields(&mut self, api: &DiskApi, scope_id: &str, new_name: Option<(&str, &str)>, chunk_bytes: u64)
        -> DiskResult<(Value, Key, [u8; 16])> {
        let (epoch, k) = self.current(api, scope_id)?;
        let mut v = json!({ "sealed": true, "chunk_bytes": chunk_bytes, "key_epoch": epoch });
        if let Some((name, mime)) = new_name {
            let id = x::new_proposed_id("dnd");
            v["metadata_ciphertext"] = json!(B64.encode(x::seal_meta(&k.m, &id, name, Some(mime)).map_err(sealed_err)?));
            v["id"] = json!(id);
        }
        Ok((v, x::new_key(), x::new_prefix()))
    }

    pub fn record(&mut self, api: &DiskApi, scope_id: &str, up: &ApiUpload, kv: &Key, prefix: &[u8; 16], chunk_bytes: u64)
        -> DiskResult<SealedRecord> {
        let node_id = up.node_id.clone().ok_or(DiskError::Other("no node id".into()))?;
        let version_id = up.version_id.clone().ok_or(DiskError::Other("no version id".into()))?;
        let epoch = up.key_epoch.ok_or(DiskError::Other("no key epoch".into()))?;
        let w = self.key(api, scope_id, epoch)?;
        let wrapped = x::wrap_version_key(&w.w, &node_id, &version_id, kv).map_err(sealed_err)?;
        Ok(SealedRecord { node_id, version_id, epoch, chunk_bytes, prefix: B64.encode(prefix), wrapped_key: B64.encode(wrapped) })
    }

    /// Seals `src` into `dst` for the reserved version and returns the
    /// complete fields. Deterministic for one record, so a resume re-seals to
    /// the same bytes and the parts storage already holds stay valid.
    pub fn seal_to(&mut self, api: &DiskApi, scope_id: &str, rec: &SealedRecord, src: &Path, dst: &Path) -> DiskResult<Value> {
        let w = self.key(api, scope_id, rec.epoch)?;
        let kv = x::unwrap_version_key(&w.w, &rec.node_id, &rec.version_id, &unb64(&rec.wrapped_key)?).map_err(sealed_err)?;
        let prefix: [u8; 16] = unb64(&rec.prefix)?.try_into().map_err(|_| DiskError::Other("bad prefix".into()))?;
        let manifest = x::ChunkSealer::new(&kv, prefix, rec.chunk_bytes as usize)
            .seal(&rec.node_id, &rec.version_id, BufReader::new(File::open(src)?), BufWriter::new(File::create(dst)?))
            .map_err(sealed_err)?;
        let f = x::VersionKeys::derive(&kv).f;
        let manifest_ct = x::seal_manifest(&f, &manifest).map_err(sealed_err)?;
        Ok(json!({ "wrapped_key": rec.wrapped_key, "manifest_ciphertext": B64.encode(manifest_ct) }))
    }
}
