//! On-demand model download: resumable, sha256-verified, atomic install, with
//! progress + state events over the engine's event bus. Free models are never
//! bundled — they land here on first use and unpack into a per-id directory that
//! reads only ever see complete.
//!
//! Layout under `<data_dir>/models/`:
//!   - `<id>/`            the installed model (a `.complete` marker is the last write)
//!   - `.partial/<id>/`   in-flight bytes; renamed onto `<id>/` after verify
//!
//! Progress flows through [`EventSink`] as `("model-download", payload)` so the
//! host renders it without a new FFI streaming primitive (UniFFI async is deferred).

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures_util::StreamExt;
use parking_lot::{Mutex, RwLock};
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use super::ModelEntry;
use crate::sync::events::EventSink;

const COMPLETE_MARKER: &str = ".complete";

/// Download lifecycle states emitted in the `model-download` event's `state`
/// field. These are the wire contract the host UI reads (iOS `ModelDownload`:
/// `state == "installed"`, `["downloading","verifying","installing"]`), so the
/// strings are byte-stable. Single source per the "no duplicated enums" rule.
mod state {
    /// Not present on disk (after a delete).
    pub const ABSENT: &str = "absent";
    /// Fully downloaded, verified, and installed.
    pub const INSTALLED: &str = "installed";
    /// The download/install failed (carries an error).
    pub const FAILED: &str = "failed";
    /// Bytes are streaming in.
    pub const DOWNLOADING: &str = "downloading";
    /// Verifying a downloaded file's sha256.
    pub const VERIFYING: &str = "verifying";
    /// Unpacking / swapping the verified files into place.
    pub const INSTALLING: &str = "installing";
}

pub struct DownloadManager {
    models_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    inflight: Mutex<HashSet<String>>,
    http: reqwest::Client,
    /// HuggingFace access token for gated repos (none in the current manifest). In-memory only; the host
    /// persists it (Keychain) and re-pushes it via `set_hf_token` after launch.
    hf_token: RwLock<Option<String>>,
}

impl DownloadManager {
    pub fn new(models_dir: PathBuf, sink: Arc<dyn EventSink>) -> Self {
        DownloadManager {
            models_dir,
            sink,
            inflight: Mutex::new(HashSet::new()),
            // Timeouts are load-bearing: without a read timeout, a connection that
            // dies mid-stream (mobile app suspension, network switch) hangs the
            // chunk await FOREVER — progress freezes, the id stays in `inflight`,
            // and retaps are ignored until an app restart. With it, a stall
            // surfaces as a failed download the user can retry (resumed by ranges).
            http: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(15))
                .read_timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("reqwest client builds"),
            hf_token: RwLock::new(None),
        }
    }

    /// Set (or clear, with `None`/empty) the HuggingFace token used to authenticate
    /// gated downloads.
    pub fn set_hf_token(&self, token: Option<String>) {
        *self.hf_token.write() = token
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
    }

    pub fn install_dir(&self, id: &str) -> PathBuf {
        self.models_dir.join(id)
    }
    fn partial_dir(&self, id: &str) -> PathBuf {
        self.models_dir.join(".partial").join(id)
    }

    /// A model is installed once its directory holds the `.complete` marker.
    pub fn is_installed(&self, entry: &ModelEntry) -> bool {
        self.install_dir(&entry.id).join(COMPLETE_MARKER).is_file()
    }

    pub fn is_downloading(&self, id: &str) -> bool {
        self.inflight.lock().contains(id)
    }

    /// Delete an installed (or partial) model, reclaiming its disk.
    pub fn delete(&self, entry: &ModelEntry) -> Result<(), String> {
        let _ = std::fs::remove_dir_all(self.partial_dir(&entry.id));
        let dir = self.install_dir(&entry.id);
        if dir.exists() {
            std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
        }
        self.emit(&entry.id, entry, state::ABSENT, 0, entry.total_bytes, None);
        Ok(())
    }

    /// Download every file of `entry`, verify, and atomically install. Resumes from
    /// any partial bytes already on disk. Emits progress/state throughout. Idempotent
    /// per id: a second call while one is in flight is a no-op.
    pub async fn run(&self, entry: ModelEntry) {
        let id = entry.id.clone();
        if !self.inflight.lock().insert(id.clone()) {
            return; // already downloading
        }
        let result = self.run_inner(&entry).await;
        self.inflight.lock().remove(&id);
        match result {
            Ok(()) => self.emit(&id, &entry, state::INSTALLED, entry.total_bytes, entry.total_bytes, None),
            Err(e) => {
                // Keep the partial dir: a transport failure (timeout, network
                // switch) retries with HTTP range-resume instead of refetching
                // hundreds of MB. Corrupt bytes can't be resumed into — the
                // verify step deletes the offending file itself before erroring.
                log::error!("[models] download {id} failed: {e}");
                self.emit(&id, &entry, state::FAILED, 0, entry.total_bytes, Some(&e));
            }
        }
    }

    async fn run_inner(&self, entry: &ModelEntry) -> Result<(), String> {
        let partial = self.partial_dir(&entry.id);
        tokio::fs::create_dir_all(&partial).await.map_err(|e| e.to_string())?;
        self.emit(&entry.id, entry, state::DOWNLOADING, 0, entry.total_bytes, None);

        let mut received: u64 = 0;
        for file in &entry.files {
            let name = filename_for(&file.url)?;
            let dest = partial.join(&name);
            received += self.fetch_file(entry, file, &dest, received).await?;
            if !file.sha256.is_empty() {
                self.emit(&entry.id, entry, state::VERIFYING, received, entry.total_bytes, None);
                if let Err(e) = verify_sha256(&dest, &file.sha256).await {
                    // Corrupt bytes must not survive as a resume base — drop this
                    // file (other files' partials stay resumable) and fail.
                    let _ = tokio::fs::remove_file(&dest).await;
                    return Err(e);
                }
            } else {
                log::warn!(
                    "[models] {} file {} has no sha256 — install unverified (pin before shipping)",
                    entry.id,
                    name
                );
            }
            // Unpack distributed bundles (e.g. sherpa-onnx `.tar.bz2`) in place, then
            // drop the archive so only the model files install.
            if let Some(fmt) = &file.archive {
                self.emit(&entry.id, entry, state::INSTALLING, received, entry.total_bytes, None);
                let partial = partial.clone();
                let dest2 = dest.clone();
                let fmt = fmt.clone();
                tokio::task::spawn_blocking(move || extract_archive(&dest2, &partial, &fmt))
                    .await
                    .map_err(|e| e.to_string())??;
                let _ = std::fs::remove_file(&dest);
            }
        }

        // Atomic install: mark the partial dir complete, then swap it onto <id>/.
        self.emit(&entry.id, entry, state::INSTALLING, received, entry.total_bytes, None);
        tokio::fs::write(partial.join(COMPLETE_MARKER), b"")
            .await
            .map_err(|e| e.to_string())?;
        let install = self.install_dir(&entry.id);
        let _ = std::fs::remove_dir_all(&install);
        if let Some(parent) = install.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::rename(&partial, &install).map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Fetch one file with HTTP range-resume. Returns its byte length. `prior` is the
    /// cumulative bytes of earlier files (for the aggregate progress payload).
    async fn fetch_file(
        &self,
        entry: &ModelEntry,
        file: &super::ModelFile,
        dest: &PathBuf,
        prior: u64,
    ) -> Result<u64, String> {
        let existing = tokio::fs::metadata(dest).await.map(|m| m.len()).unwrap_or(0);
        let mut req = self.http.get(&file.url);
        // Gated HuggingFace repos 401 without a bearer token.
        if file.url.contains("huggingface.co") {
            if let Some(token) = self.hf_token.read().clone() {
                req = req.bearer_auth(token);
            }
        }
        if existing > 0 {
            req = req.header(reqwest::header::RANGE, format!("bytes={existing}-"));
        }
        let resp = req.send().await.map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {} fetching {}", resp.status().as_u16(), file.url));
        }
        // 206 ⇒ server honored the range and we append; anything else ⇒ start fresh.
        let resume = resp.status() == reqwest::StatusCode::PARTIAL_CONTENT && existing > 0;
        let mut out = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(resume)
            .truncate(!resume)
            .open(dest)
            .await
            .map_err(|e| e.to_string())?;

        let mut count = if resume { existing } else { 0 };
        let mut since_emit: u64 = 0;
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            out.write_all(&chunk).await.map_err(|e| e.to_string())?;
            count += chunk.len() as u64;
            since_emit += chunk.len() as u64;
            if since_emit >= 1_000_000 {
                since_emit = 0;
                self.emit(&entry.id, entry, state::DOWNLOADING, prior + count, entry.total_bytes, None);
            }
        }
        out.flush().await.map_err(|e| e.to_string())?;
        Ok(count)
    }

    fn emit(
        &self,
        id: &str,
        entry: &ModelEntry,
        state: &str,
        received: u64,
        total: u64,
        error: Option<&str>,
    ) {
        self.sink.emit(
            "model-download",
            json!({
                "id": id,
                "capability": entry.capability.as_str(),
                "lane": entry.lane.as_str(),
                "state": state,
                "received_bytes": received,
                "total_bytes": total,
                "error": error,
            }),
        );
    }
}

/// The on-disk filename for a download URL (last path segment, query stripped).
fn filename_for(url: &str) -> Result<String, String> {
    let parsed = url::Url::parse(url).map_err(|e| e.to_string())?;
    parsed
        .path_segments()
        .and_then(|mut s| s.next_back())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("no filename in url: {url}"))
}

/// Unpack `archive` into `dest_dir`, stripping the single top-level directory the
/// bundle carries (sherpa-onnx tarballs wrap everything in one folder) so the model
/// files land directly under the install dir. Only `tar.bz2` is supported today.
fn extract_archive(archive: &Path, dest_dir: &Path, fmt: &str) -> Result<(), String> {
    if fmt != "tar.bz2" {
        return Err(format!("unsupported archive format: {fmt}"));
    }
    let file = std::fs::File::open(archive).map_err(|e| e.to_string())?;
    let decoder = bzip2_rs::DecoderReader::new(std::io::BufReader::new(file));
    unpack_tar_stripped(decoder, dest_dir)
}

/// Unpack a tar stream into `dest_dir`, stripping the single leading path component
/// each entry carries (sherpa-onnx bundles wrap everything in one folder).
fn unpack_tar_stripped<R: std::io::Read>(reader: R, dest_dir: &Path) -> Result<(), String> {
    let mut tar = tar::Archive::new(reader);
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path().map_err(|e| e.to_string())?.into_owned();
        let stripped: PathBuf = path.components().skip(1).collect();
        if stripped.as_os_str().is_empty() {
            continue;
        }
        let out = dest_dir.join(&stripped);
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        entry.unpack(&out).map_err(|e| e.to_string())?;
    }
    Ok(())
}

async fn verify_sha256(path: &PathBuf, expected_hex: &str) -> Result<(), String> {
    let bytes = tokio::fs::read(path).await.map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let got = hex_lower(&hasher.finalize());
    if got.eq_ignore_ascii_case(expected_hex) {
        Ok(())
    } else {
        Err(format!("sha256 mismatch: expected {expected_hex}, got {got}"))
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn entry_with(url: String, sha: String, bytes: u64) -> ModelEntry {
        ModelEntry {
            id: "test-model".into(),
            capability: super::super::Capability::Tts,
            lane: super::super::Lane::Free,
            engine: super::super::Engine::SherpaOnnx,
            files: vec![super::super::ModelFile { url, sha256: sha, bytes, archive: None }],
            total_bytes: bytes,
            license: "Apache-2.0".into(),
            platforms: vec!["ios".into()],
            availability_reqs: Default::default(),
            langs: vec![],
            voices: vec![],
        }
    }

    #[tokio::test]
    async fn downloads_verifies_and_installs() {
        let server = MockServer::start().await;
        let body = b"hello kokoro weights".to_vec();
        // sha256 of the body.
        let sha = {
            let mut h = Sha256::new();
            h.update(&body);
            hex_lower(&h.finalize())
        };
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(body.clone()))
            .mount(&server)
            .await;

        let tmp = tempfile::tempdir().unwrap();
        let mgr = DownloadManager::new(tmp.path().to_path_buf(), Arc::new(NullSink));
        let url = format!("{}/model.onnx", server.uri());
        let entry = entry_with(url, sha, body.len() as u64);

        assert!(!mgr.is_installed(&entry));
        mgr.run(entry.clone()).await;
        assert!(mgr.is_installed(&entry), "model should be installed after run");
        let installed = mgr.install_dir(&entry.id).join("model.onnx");
        assert_eq!(std::fs::read(installed).unwrap(), body);

        // Delete reclaims it.
        mgr.delete(&entry).unwrap();
        assert!(!mgr.is_installed(&entry));
    }

    #[tokio::test]
    async fn sha_mismatch_does_not_install() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"corrupt".to_vec()))
            .mount(&server)
            .await;

        let tmp = tempfile::tempdir().unwrap();
        let mgr = DownloadManager::new(tmp.path().to_path_buf(), Arc::new(NullSink));
        let url = format!("{}/model.onnx", server.uri());
        let entry = entry_with(url, "deadbeef".repeat(8), 7);

        mgr.run(entry.clone()).await;
        assert!(!mgr.is_installed(&entry), "mismatched sha must not install");
    }

    #[test]
    fn filename_extraction() {
        assert_eq!(filename_for("https://h/a/b/model.onnx").unwrap(), "model.onnx");
        assert_eq!(filename_for("https://h/v/voices.bin?x=1").unwrap(), "voices.bin");
        assert!(filename_for("not a url").is_err());
    }

    #[test]
    fn unpack_strips_top_level_dir() {
        // A tar with everything under one wrapper folder (the sherpa-onnx layout).
        let mut tar_bytes = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar_bytes);
            let mut add = |name: &str, data: &[u8]| {
                let mut h = tar::Header::new_gnu();
                h.set_size(data.len() as u64);
                h.set_mode(0o644);
                h.set_cksum();
                builder.append_data(&mut h, name, data).unwrap();
            };
            add("kokoro-v1/model.onnx", b"onnx-weights");
            add("kokoro-v1/data/tokens.txt", b"a b c");
            builder.finish().unwrap();
        }
        let tmp = tempfile::tempdir().unwrap();
        let dest = tmp.path().join("out");
        std::fs::create_dir_all(&dest).unwrap();
        unpack_tar_stripped(&tar_bytes[..], &dest).unwrap();
        // The wrapper dir is gone; model files sit directly under the install dir.
        assert_eq!(std::fs::read(dest.join("model.onnx")).unwrap(), b"onnx-weights");
        assert_eq!(std::fs::read(dest.join("data/tokens.txt")).unwrap(), b"a b c");
        assert!(!dest.join("kokoro-v1").exists());
    }
}
