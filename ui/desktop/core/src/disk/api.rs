//! Blocking HTTP client for the Disk API. The File Provider extension calls
//! the engine from its own background queues, so blocking keeps the FFI plain
//! (no runtime inside the extension). The desktop app calls it from
//! `spawn_blocking`.
//!
//! Retries here are short (a few seconds): the outer loop belongs to macOS,
//! which keeps a failed change and calls again after `Offline`.

use std::time::Duration;

use rand::Rng;
use reqwest::blocking::{Client, RequestBuilder, Response};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};

use super::model::*;

/// Attempts per request before the engine reports `Offline` to macOS.
const ATTEMPTS: u32 = 3;
const BACKOFF_BASE_MS: u64 = 500;
const BACKOFF_CAP_MS: u64 = 4_000;
/// Thumbnails: one try, this long at most per request.
const THUMBNAIL_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Clone)]
pub struct DiskApi {
    base: String,
    org: String,
    token: String,
    http: Client,
}

/// Full jitter: a random wait in [0, min(cap, base * 2^attempt)].
pub fn backoff(attempt: u32, base_ms: u64, cap_ms: u64) -> Duration {
    let ceiling = cap_ms.min(base_ms.saturating_mul(1u64 << attempt.min(20)));
    Duration::from_millis(rand::thread_rng().gen_range(0..=ceiling))
}

impl DiskApi {
    pub fn new(api_base: &str, org: &str, token: &str) -> Self {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(120))
            .build()
            .unwrap_or_default();
        Self { base: api_base.trim_end_matches('/').to_string(), org: org.to_string(), token: token.to_string(), http }
    }

    fn url(&self, path: &str) -> String {
        format!("{}/orgs/{}/disk/{}", self.base, self.org, path.trim_start_matches('/'))
    }

    /// Sends with short retries on network errors, 5xx and 429.
    fn send(&self, build: impl Fn() -> RequestBuilder) -> DiskResult<Response> {
        let mut last = String::new();
        for attempt in 0..ATTEMPTS {
            if attempt > 0 {
                std::thread::sleep(backoff(attempt, BACKOFF_BASE_MS, BACKOFF_CAP_MS));
            }
            match build().send() {
                Ok(r) if r.status().is_server_error() || r.status().as_u16() == 429 => {
                    last = format!("server answered {}", r.status());
                }
                Ok(r) => return Ok(r),
                Err(e) => last = e.to_string(),
            }
        }
        Err(DiskError::Offline(last))
    }

    fn call<T: DeserializeOwned>(&self, build: impl Fn() -> RequestBuilder) -> DiskResult<T> {
        let r = self.send(build)?;
        let status = r.status().as_u16();
        if (200..300).contains(&status) {
            return r.json().map_err(|e| DiskError::Other(format!("bad response: {e}")));
        }
        let body: Value = r.json().unwrap_or(Value::Null);
        Err(error_for(status, &body))
    }

    fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, String)]) -> DiskResult<T> {
        self.call(|| self.http.get(self.url(path)).query(query).bearer_auth(&self.token))
    }

    fn post<T: DeserializeOwned>(&self, path: &str, body: &Value) -> DiskResult<T> {
        self.call(|| self.http.post(self.url(path)).json(body).bearer_auth(&self.token))
    }

    fn patch<T: DeserializeOwned>(&self, path: &str, body: &Value) -> DiskResult<T> {
        self.call(|| self.http.patch(self.url(path)).json(body).bearer_auth(&self.token))
    }

    fn delete<T: DeserializeOwned>(&self, path: &str) -> DiskResult<T> {
        self.call(|| self.http.delete(self.url(path)).bearer_auth(&self.token))
    }

    // ── feed ──

    pub fn pull(&self, since: &str) -> DiskResult<PullPage> {
        self.get("sync/pull", &[("since", since.to_string()), ("limit", "500".into())])
    }

    pub fn keys(&self, after: &str) -> DiskResult<KeysPage> {
        self.get("sync/keys", &[("after", after.to_string())])
    }

    pub fn nodes(&self, ids: &[String]) -> DiskResult<Vec<ApiNode>> {
        let q: Vec<(&str, String)> = ids.iter().map(|i| ("ids[]", i.clone())).collect();
        Ok(self.get::<NodesPage>("sync/nodes", &q)?.nodes)
    }

    /// `GET scopes/:id` answers `{ scope: {...} }`.
    pub fn scope(&self, node_id: &str) -> DiskResult<ApiScope> {
        let v: Value = self.get(&format!("scopes/{node_id}"), &[])?;
        serde_json::from_value(v["scope"].clone()).map_err(|e| DiskError::Other(format!("scope: {e}")))
    }

    // ── writes ──

    pub fn create_folder(&self, body: &Value) -> DiskResult<Value> {
        self.post("nodes", body)
    }

    pub fn rename(&self, id: &str, body: &Value) -> DiskResult<Value> {
        self.patch(&format!("nodes/{id}"), body)
    }

    pub fn move_node(&self, id: &str, target_id: &str) -> DiskResult<Value> {
        self.post(&format!("nodes/{id}/move"), &json!({ "target_id": target_id }))
    }

    pub fn trash(&self, id: &str) -> DiskResult<Value> {
        self.delete(&format!("nodes/{id}"))
    }

    // ── transfers ──

    /// A presigned GET for the version's bytes.
    pub fn download_url(&self, version_id: &str) -> DiskResult<String> {
        let v: Value = self.get(&format!("versions/{version_id}/download"), &[])?;
        v["download"]["url"].as_str().map(str::to_string).ok_or_else(|| DiskError::Other("no download url".into()))
    }

    /// One attempt with a short timeout: Finder waits on thumbnails, and a missed
    /// one costs nothing (Finder asks again later).
    fn send_once(&self, req: RequestBuilder) -> DiskResult<Response> {
        req.timeout(THUMBNAIL_TIMEOUT).send().map_err(|e| DiskError::Offline(e.to_string()))
    }

    /// A presigned GET for the version's server thumbnail. `NotFound` when it has none.
    pub fn thumbnail_url(&self, version_id: &str) -> DiskResult<String> {
        let req = self.http.get(self.url(&format!("versions/{version_id}/download"))).query(&[("variant", "thumbnail")]).bearer_auth(&self.token);
        let r = self.send_once(req)?;
        let status = r.status().as_u16();
        let v: Value = r.json().unwrap_or(Value::Null);
        if !(200..300).contains(&status) {
            return Err(error_for(status, &v));
        }
        v["download"]["url"].as_str().map(str::to_string).ok_or_else(|| DiskError::Other("no thumbnail url".into()))
    }

    /// A small object (a thumbnail), at most `max` bytes. A short timeout, unlike
    /// file downloads: Finder waits on it.
    pub fn get_small(&self, url: &str, max: u64) -> DiskResult<Vec<u8>> {
        use std::io::Read;
        let r = self.send_once(self.http.get(url))?;
        match r.status().as_u16() {
            200..=299 => {
                let mut buf = Vec::new();
                r.take(max).read_to_end(&mut buf).map_err(|e| DiskError::Offline(e.to_string()))?;
                Ok(buf)
            }
            404 => Err(DiskError::NotFound),
            403 => Err(DiskError::Offline("thumbnail URL expired".into())),
            s => Err(DiskError::Other(format!("storage answered {s}"))),
        }
    }

    /// The item's link in the inbox2 web app, as the signed-in member sees it.
    pub fn link(&self, node_id: &str) -> DiskResult<String> {
        let v: Value = self.get(&format!("nodes/{node_id}/link"), &[])?;
        v["link"]["url"].as_str().map(str::to_string).ok_or_else(|| DiskError::Other("no link".into()))
    }

    pub fn reserve(&self, body: &Value) -> DiskResult<ApiUpload> {
        let v: Value = self.post("uploads", body)?;
        serde_json::from_value(v["upload"].clone()).map_err(|e| DiskError::Other(format!("upload: {e}")))
    }

    /// The upload and the part numbers storage already holds. `None` once the
    /// reservation is gone (expired, aborted or completed elsewhere).
    pub fn upload_state(&self, id: &str) -> DiskResult<Option<(ApiUpload, Vec<u32>)>> {
        match self.get::<Value>(&format!("uploads/{id}"), &[]) {
            Ok(v) => {
                let up: ApiUpload = serde_json::from_value(v["upload"].clone()).map_err(|e| DiskError::Other(e.to_string()))?;
                let parts: Vec<StoredPart> = serde_json::from_value(v["parts"].clone()).unwrap_or_default();
                Ok(Some((up, parts.into_iter().map(|p| p.number).collect())))
            }
            Err(DiskError::NotFound) => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn part_urls(&self, id: &str, numbers: &[u32]) -> DiskResult<Vec<PartUrl>> {
        let v: Value = self.post(&format!("uploads/{id}/parts"), &json!({ "numbers": numbers }))?;
        serde_json::from_value(v["parts"].clone()).map_err(|e| DiskError::Other(e.to_string()))
    }

    pub fn complete(&self, id: &str, body: &Value) -> DiskResult<ApiNode> {
        let v: Value = self.post(&format!("uploads/{id}/complete"), body)?;
        serde_json::from_value(v["node"].clone()).map_err(|e| DiskError::Other(format!("complete: {e}")))
    }

    pub fn abort(&self, id: &str) -> DiskResult<()> {
        let _: Value = self.delete(&format!("uploads/{id}"))?;
        Ok(())
    }

    /// PUT one part straight to storage. Retries like any request; the caller
    /// resumes from the stored parts after an `Offline`.
    pub fn put_part(&self, url: &str, bytes: Vec<u8>) -> DiskResult<()> {
        let r = self.send(|| self.http.put(url).body(bytes.clone()))?;
        match r.status().as_u16() {
            200..=299 => Ok(()),
            403 => Err(DiskError::Offline("part URL expired".into())),
            s => Err(DiskError::Other(format!("storage answered {s}"))),
        }
    }

    /// A ranged GET from `offset` to the end; storage honours Range.
    pub fn get_from(&self, url: &str, offset: u64) -> DiskResult<Response> {
        let r = self.send(|| {
            let req = self.http.get(url).timeout(Duration::from_secs(3600));
            if offset > 0 { req.header("Range", format!("bytes={offset}-")) } else { req }
        })?;
        match r.status().as_u16() {
            200 | 206 => Ok(r),
            403 => Err(DiskError::Offline("download URL expired".into())),
            404 => Err(DiskError::NotFound),
            416 => Err(DiskError::Other("range not satisfiable".into())),
            s => Err(DiskError::Other(format!("storage answered {s}"))),
        }
    }
}

/// Maps an API error onto what the extension can tell macOS.
pub fn error_for(status: u16, body: &Value) -> DiskError {
    // ErrorSerializer: { errors: [{ message }], status, ...extra (code) }.
    let msg = body["errors"][0]["message"].as_str().unwrap_or("").to_string();
    let code = body["code"].as_str().unwrap_or("");
    match status {
        401 => DiskError::SignedOut,
        404 => DiskError::NotFound,
        403 if code == "disk_read_only" => DiskError::NoPermission(msg),
        403 => DiskError::NoPermission(msg),
        409 if code == "version_conflict" => DiskError::Other("version_conflict".into()),
        409 if code == "rotation_required" => DiskError::NoPermission(msg),
        409 if msg.contains("already exists") || msg.contains("already taken") => DiskError::NameTaken(msg),
        409 => DiskError::Other(if code.is_empty() { msg } else { code.to_string() }),
        413 | 507 => DiskError::StorageFull,
        422 if msg.contains("quota") || msg.contains("storage") => DiskError::StorageFull,
        422 => DiskError::NameNotAllowed(msg),
        _ => DiskError::Other(format!("{status} {msg}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_stays_under_its_cap() {
        for a in 0..30 {
            assert!(backoff(a, 500, 4_000) <= Duration::from_millis(4_000));
        }
        assert!(backoff(0, 500, 4_000) <= Duration::from_millis(500));
    }

    #[test]
    fn errors_map_to_what_finder_can_show() {
        assert_eq!(error_for(401, &Value::Null), DiskError::SignedOut);
        assert_eq!(error_for(404, &Value::Null), DiskError::NotFound);
        assert_eq!(error_for(507, &Value::Null), DiskError::StorageFull);
        let taken = json!({"errors": [{"message": "An item named \"a\" already exists here"}]});
        assert!(matches!(error_for(409, &taken), DiskError::NameTaken(_)));
        let conflict = json!({"errors": [{"message": "x"}], "code": "version_conflict"});
        assert_eq!(error_for(409, &conflict), DiskError::Other("version_conflict".into()));
    }
}
