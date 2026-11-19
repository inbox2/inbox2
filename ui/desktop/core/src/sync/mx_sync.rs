//! MX sync client — fills the local mirror from the Rails API (docs/MX-Sync.md).
//!
//! One entry point, [`SyncEngine::mx_sync`]: a single bounded, resumable pass.
//! Callers (desktop on a cable hint, mobile on push wake / foreground, everyone on
//! a poll timer) just call it again; every stage picks up from `mx_sync_state`.
//!
//!   head       first run only — park the delta cursor at "now" *before* reading
//!              history, so nothing that changes during backfill is missed
//!   directory  domains, members, tags, spaces, labels, views, the org — re-listed
//!   delta      `sync/pull` until drained; the cursor is saved after each page is
//!              applied, so a crash replays a page rather than skipping one
//!   backfill   `sync/backfill`, newest first, a few pages per pass
//!   reconcile  `sync/keys` against what is held (hourly, when asked, or when the
//!              server says the cursor outlived its tombstones). Removal runs even
//!              mid-backfill — revoked mail must not wait for history to finish
//!   hydrate    `sync/threads` for whatever the stages above flagged
//!
//! Writes go the other way through [`SyncEngine::mx_action`]: applied locally at
//! once, queued, and replayed by [`SyncEngine::mx_drain`] against the real bulk
//! endpoint (validation, activity, broadcasts all stay server-side). The engine's
//! run loop calls [`SyncEngine::mx_tick`] for every org mirrored on this device.
//!
//! All correctness rules (version guard, settle guard, pruning) live in the store;
//! this file only moves pages.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use base64::Engine as _;
use zeroize::Zeroizing;

use crate::sync::engine::SyncEngine;
use crate::sync::model::ApiContext;
use crate::sync::error::{Result, SyncError};
use crate::sync::store::mx::{MxDeleted, MxRecords};
use crate::sync::store::SyncStore;

/// History pages fetched per pass — keeps one pass short so fresh mail is never
/// stuck behind a long backfill. The next pass continues from the saved token.
const BACKFILL_PAGES_PER_PASS: usize = 5;
/// Delta pages per pass. Far more than a normal pass needs; bounds a device that
/// was offline for months.
const PULL_PAGES_PER_PASS: usize = 50;
const HYDRATE_BATCH: usize = 50;
const HYDRATE_BATCHES_PER_PASS: usize = 10;
const REFRESH_AFTER: chrono::Duration = chrono::Duration::hours(1);
/// Busy upload (docs/Calendar.md "External busy"): how far ahead, how often an
/// unchanged set is re-sent, and where this device's stable source id lives.
const BUSY_HORIZON: chrono::Duration = chrono::Duration::days(56);
const BUSY_RESEND_AFTER: chrono::Duration = chrono::Duration::hours(6);
const BUSY_SOURCE_KEY: &str = "mx_busy_source";
/// 5000 keys a page: ten million threads. Past that the server is looping.
const KEYS_PAGES_MAX: usize = 2000;

/// A server that pages without advancing would otherwise burn every pass forever.
fn stuck(what: &str) -> SyncError {
    SyncError::Other(format!("mx {what}: the server returned the same position twice"))
}

/// `(path under orgs/:id, response key, mx_directory type)`. Members carry their
/// mailboxes. A listing the member isn't allowed is skipped, not fatal.
const DIRECTORY: &[(&str, &str, &str)] = &[
    ("domains", "domains", "domains"),
    ("members", "members", "members"),
    ("tags", "tags", "tags"),
    ("spaces", "spaces", "spaces"),
    ("triage-labels", "triage_labels", "triage_labels"),
    ("views", "views", "views"),
];

#[derive(Debug, Clone, Copy, Default)]
pub struct MxSyncOptions {
    /// Re-list the directory now (a `scope: "directory"` hint) instead of hourly.
    pub directory: bool,
    /// Reconcile now (own membership/domain scope may have changed).
    pub reconcile: bool,
}

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
pub struct MxSyncReport {
    pub pulled: usize,
    pub deleted: usize,
    pub backfilled: usize,
    pub hydrated: usize,
    pub removed: usize,
    pub backfill_done: bool,
    /// More work is queued (history, hydration, an undrained delta): call again soon.
    pub more: bool,
}

#[derive(Deserialize)]
struct PullPage {
    cursor: String,
    #[serde(default)]
    has_more: bool,
    #[serde(default)]
    cursor_expired: bool,
    #[serde(default)]
    records: MxRecords,
    #[serde(default)]
    deleted: Vec<MxDeleted>,
}

#[derive(Deserialize)]
struct BackfillPage {
    next: Option<String>,
    #[serde(default)]
    records: MxRecords,
}

#[derive(Deserialize)]
struct KeysPage {
    keys: Vec<(String, i64)>,
    next: Option<String>,
}

#[derive(Deserialize)]
struct ThreadsPage {
    #[serde(default)]
    records: MxRecords,
    #[serde(default)]
    missing: Vec<String>,
    #[serde(default)]
    remaining: Vec<String>,
}

pub(crate) fn client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_default()
    })
}

// ponytail: one pass at a time for the whole process. Per-org locks when someone
// really syncs several orgs on one device and notices them queueing.
static PASS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn due(stamp: Option<&str>) -> bool {
    stamp
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map_or(true, |at| chrono::Utc::now() - at.with_timezone(&chrono::Utc) > REFRESH_AFTER)
}

impl SyncEngine {
    /// One sync pass for `org`, as `user_key` (the signed-in user — a different
    /// one than the mirror was built for starts it over).
    ///
    /// Any error leaves the pages applied so far in place and the pass resumable —
    /// every page is committed before its cursor is. 401 → [`SyncError::AuthFailed`]
    /// (sign in again). When this user no longer has the org, the mirror is wiped
    /// and the pass ends `Ok` — mail must not outlive the membership on the device.
    pub async fn mx_sync(&self, org: &str, user_key: &str, opts: MxSyncOptions) -> Result<MxSyncReport> {
        let _pass = PASS.lock().await;
        // One base + token for the whole pass: a context swapped mid-pass must not
        // send this pass's bearer somewhere new, nor mix two servers into one mirror.
        let ctx = self.mx_signed_in().await?;
        match self.mx_pass(&ctx, org, user_key, opts).await {
            Err(e @ SyncError::HttpStatus { code: 404, .. }) => {
                // A 404 alone proves nothing — an older server without this route, a
                // wrong base, a proxy blip — and wiping on it would erase every local
                // message. Access is gone only when this same base + token still
                // answers for the account while the org itself is a 404 (the API's
                // answer for an org you're not an active member of).
                let account_ok = mx_fetch::<Value>(&ctx, "account", &[]).await.is_ok();
                match mx_get::<Value>(&ctx, org, "", &[]).await {
                    Err(SyncError::HttpStatus { code: 404, .. }) if account_ok => {
                        log::warn!("[mx] {org}: gone for {user_key} — access lost, wiping the local mirror");
                        // (we hold the pass lock, so not `mx_forget`, which takes it)
                        self.mx_domain_keys.write().remove(org);
                        self.store().mx_wipe(org)?;
                        Ok(MxSyncReport::default())
                    }
                    _ => Err(e),
                }
            }
            other => other,
        }
    }

    /// Sign-out, a removed org, a lost membership: the org's mail, queued actions
    /// and domain keys all leave — the one way to forget an org, on every path.
    pub async fn mx_forget(&self, org: &str) -> Result<()> {
        self.mx_domain_keys.write().remove(org);
        // Now — and a pass already running for this org sees its state row gone
        // before its next page and stops (`still_mirrored`)…
        self.store().mx_wipe(org)?;
        // …then once more after that pass has let go, for the page it was in the
        // middle of applying. Nothing may be left on disk after a sign-out.
        let _pass = PASS.lock().await;
        self.store().mx_wipe(org)
    }

    /// False once the org was forgotten (or handed to another user) under a running
    /// pass: whatever that pass still holds must not be written.
    fn still_mirrored(&self, org: &str, user_key: &str) -> Result<()> {
        match self.store().mx_state(org)? {
            Some(state) if state.user_key == user_key => Ok(()),
            _ => Err(SyncError::Other(format!("mx {org}: no longer mirrored for this user — pass abandoned"))),
        }
    }

    /// Hand the engine the E2EE domain keys this member unlocked (memory only), and
    /// open whatever sealed mail is already mirrored. The client that holds the
    /// identity key calls this after unlock; `keys = []` on lock / sign-out.
    pub fn mx_set_domain_keys(&self, org: &str, keys: Vec<crate::sync::seal::DomainKey>) -> usize {
        if keys.is_empty() {
            self.mx_domain_keys.write().remove(org);
            return 0;
        }
        self.mx_domain_keys.write().insert(org.to_string(), keys);
        self.mx_open_sealed(org)
    }

    /// Phones: open the identity key with the account password. `None` is a wrong
    /// password. The result goes straight into the platform's secure store.
    pub async fn mx_unlock_identity(&self, password: &str) -> Result<Option<Zeroizing<String>>> {
        let ctx = self.mx_signed_in().await?;
        let res: Value = mx_fetch(&ctx, "user-key", &[]).await?;
        let envelope = res["user_key"]["encrypted_private_key"].as_str().ok_or_else(|| SyncError::Other("sealed mail: no identity key".into()))?;
        let identity = crate::sync::seal::unwrap_identity(password, envelope)?;
        Ok(identity.map(|k| Zeroizing::new(base64::engine::general_purpose::STANDARD.encode(*k))))
    }

    /// Phones: open every grant this member holds in the org and hand the keys to
    /// the engine. An empty list takes back keys for grants that are gone.
    pub async fn mx_unlock_org(&self, org: &str, identity_b64: &str) -> Result<usize> {
        let ctx = self.mx_signed_in().await?;
        let res: Value = mx_get(&ctx, org, "e2ee/my-grants", &[]).await?;
        let mut keys = Vec::new();
        for g in res["grants"].as_array().into_iter().flatten() {
            let (Some(version), Some(public), Some(grant)) =
                (g["version"].as_i64(), g["public_key"].as_str(), g["sealed_secret_key"].as_str()) else { continue };
            keys.push(crate::sync::seal::DomainKey::from_grant(version, public, crate::sync::seal::open_grant(grant, identity_b64)?)?);
        }
        Ok(self.mx_set_domain_keys(org, keys))
    }

    async fn mx_signed_in(&self) -> Result<ApiContext> {
        self.api_context().read().await.clone().filter(|c| !c.rails_jwt.is_empty())
            .ok_or_else(|| SyncError::AuthFailed("not signed in to inbox2".into()))
    }

    /// Open mirrored sealed mail with the held keys. Returns how many were opened.
    /// Mail no held key fits stays sealed and is simply tried again next time.
    pub fn mx_open_sealed(&self, org: &str) -> usize {
        let (mut total, mut after) = (0, String::new());
        loop {
            let batch = match self.store().mx_unopened(org, &after, 200) {
                Ok(batch) if !batch.is_empty() => batch,
                _ => break,
            };
            after = batch.last().map(|(key, _)| key.clone()).unwrap_or_default();
            let opened: Vec<(String, Value, Value)> = {
                // Used in place, under the lock: the keys are never copied out.
                let held = self.mx_domain_keys.read();
                let Some(keys) = held.get(org) else { return total };
                batch
                    .iter()
                    .filter_map(|(key, sealed)| {
                        crate::sync::seal::open_with_any(sealed, keys).ok().map(|o| (key.clone(), o.header, o.body))
                    })
                    .collect()
            };
            if let Err(e) = self.store().mx_store_opened(org, &opened) {
                log::warn!("[mx] {org}: storing opened mail failed: {e}");
                break;
            }
            total += opened.len();
        }
        if total > 0 {
            log::info!("[mx] {org}: opened {total} sealed message(s)");
            self.emit("mx-sync", serde_json::json!({ "org": org, "opened": total }));
        }
        total
    }

    /// A conversation action (`archive`, `trash`, `spam`, `open`, `mark_read`,
    /// `mark_unread`): visible locally before this returns, durable in the queue,
    /// and sent right away if the network allows. Never fails for being offline.
    pub async fn mx_action(&self, org: &str, threads: &[String], action: &str) -> Result<()> {
        self.store().mx_enqueue_action(org, threads, action)?;
        self.emit("mx-sync", serde_json::json!({ "org": org, "conversationKeys": threads }));
        self.mx_drain().await;
        Ok(())
    }

    /// Send every due queued action, oldest first. Stops at the first transient
    /// failure — the server or the link is down, and pushing the rest of the queue
    /// at it would only burn every row's retry budget at once.
    pub async fn mx_drain(&self) -> usize {
        let Some(ctx) = self.api_context().read().await.clone().filter(|c| !c.rails_jwt.is_empty()) else {
            return 0;
        };
        let mut sent = 0;
        loop {
            let batch = match self.store().mx_claim_actions() {
                Ok(Some(batch)) => batch,
                Ok(None) => return sent,
                Err(e) => {
                    log::warn!("[mx] claiming actions failed: {e}");
                    return sent;
                }
            };
            let url = format!("{}/orgs/{}/conversations/bulk", ctx.api_base.trim_end_matches('/'), batch.org);
            let body = serde_json::json!({ "conversation_ids": batch.conversations, "action_name": batch.action });
            let outcome = match client().post(url).bearer_auth(&ctx.rails_jwt).json(&body).send().await {
                Ok(resp) if resp.status().is_success() => {
                    // `updated` short of what we sent: some of these threads the server
                    // wouldn't touch (gone, or no longer visible). We can't tell which,
                    // so all of them re-fetch; the refused ones come back as missing.
                    let updated = resp.json::<Value>().await.ok().and_then(|v| v.get("updated").and_then(Value::as_u64));
                    if updated.is_some_and(|n| (n as usize) < batch.conversations.len()) {
                        if let Err(e) = self.store().mx_mark_unhydrated(&batch.org, &batch.conversations) {
                            log::warn!("[mx] marking a partly-applied batch for re-fetch failed: {e}");
                        }
                    }
                    Ok(())
                }
                Ok(resp) => Err((resp.status().as_u16(), format!("{} {}", batch.action, resp.status()))),
                Err(e) => Err((0, e.to_string())),
            };
            let result = match outcome {
                Ok(()) => {
                    sent += batch.ids.len();
                    self.store().mx_actions_done(&batch.ids)
                }
                Err((code, error)) => {
                    // Understood and refused — retrying can't fix it. 401 (session
                    // refresh), 408 and 429 are worth another go, like 5xx and offline.
                    let permanent = (400..500).contains(&code) && ![401, 408, 429].contains(&code);
                    log::warn!("[mx] {} on {} thread(s) failed ({}): {error}", batch.action, batch.ids.len(),
                               if permanent { "permanent" } else { "will retry" });
                    let marked = self.store().mx_actions_failed(&batch.ids, &error, permanent);
                    if permanent {
                        self.emit("mx-sync", serde_json::json!({ "org": batch.org, "conversationKeys": batch.conversations }));
                    } else {
                        return sent;
                    }
                    marked
                }
            };
            if let Err(e) = result {
                log::warn!("[mx] recording action outcome failed: {e}");
                return sent;
            }
        }
    }

    /// One pass for every org mirrored on this device. Errors are logged, not
    /// returned: one org being unreachable must not stop the others.
    pub async fn mx_tick(&self) {
        self.mx_drain().await;
        for (org, user_key) in self.store().mx_watched().unwrap_or_default() {
            // Keep going while a pass reports more (history, hydration), briefly —
            // the next tick carries on.
            for _ in 0..4 {
                match self.mx_sync(&org, &user_key, MxSyncOptions::default()).await {
                    Ok(report) if report.more => continue,
                    Ok(_) => break,
                    Err(e) => {
                        log::warn!("[mx] {org}: sync pass failed: {e}");
                        break;
                    }
                }
            }
            if let Err(e) = self.mx_push_busy(&org).await {
                log::warn!("[mx] {org}: busy upload failed: {e}");
            }
        }
    }

    /// Upload this device's calendar busy time — bare start/end pairs, nothing
    /// else — so the org's free/busy and meet links see meetings that live only
    /// in local Gmail/Office365 calendars (docs/Calendar.md "External busy").
    /// Skipped while nothing changed, re-sent every few hours regardless so the
    /// server knows this device is still reporting.
    pub async fn mx_push_busy(&self, org: &str) -> Result<()> {
        let Some(ctx) = self.api_context().read().await.clone().filter(|c| !c.rails_jwt.is_empty()) else {
            return Ok(());
        };
        let store = self.store();
        let now = chrono::Utc::now();
        let until = now + BUSY_HORIZON;
        let rows = store.busy_periods(
            &(now - chrono::Duration::days(1)).format("%Y-%m-%d").to_string(),
            &until.format("%Y-%m-%d").to_string(),
        )?;
        let blocks = busy_blocks(&rows, now, until);

        let source = match store.get_engine_setting(BUSY_SOURCE_KEY)? {
            Some(id) => id,
            None => {
                let id = format!("dev_{}", nanoid::nanoid!(16));
                store.set_engine_setting(BUSY_SOURCE_KEY, &id)?;
                id
            }
        };
        let body = serde_json::json!({
            "source": source,
            "blocks": blocks.iter().map(|(s, e)| serde_json::json!({ "start": s.to_rfc3339(), "end": e.to_rfc3339() })).collect::<Vec<_>>(),
        });

        use sha2::Digest;
        let digest = format!("{:x}", sha2::Sha256::digest(body["blocks"].to_string().as_bytes()));
        let stamp_key = format!("mx_busy_pushed:{org}");
        if let Some(prev) = store.get_engine_setting(&stamp_key)? {
            if let Some((prev_digest, at)) = prev.split_once('|') {
                let fresh = chrono::DateTime::parse_from_rfc3339(at)
                    .is_ok_and(|at| now - at.with_timezone(&chrono::Utc) < BUSY_RESEND_AFTER);
                if prev_digest == digest && fresh {
                    return Ok(());
                }
            }
        }

        let url = format!("{}/orgs/{org}/external-busy", ctx.api_base.trim_end_matches('/'));
        let resp = client().put(url).bearer_auth(&ctx.rails_jwt).json(&body).send().await?;
        match resp.status().as_u16() {
            200..=299 => {
                store.set_engine_setting(&stamp_key, &format!("{digest}|{}", now.to_rfc3339()))?;
                log::info!("[mx] {org}: uploaded {} busy block(s)", blocks.len());
                Ok(())
            }
            401 => Err(SyncError::AuthFailed("inbox2 session expired".into())),
            code => Err(SyncError::HttpStatus { code, context: format!("mx {org} external-busy") }),
        }
    }

    /// Bytes of one MX attachment, from the `download_url` its message payload
    /// carries (`/api/v1/orgs/:org/attachments/:key`). Only a server-relative path
    /// is accepted: an absolute URL would send this session's bearer to another host.
    pub async fn mx_download_attachment(&self, download_url: &str) -> Result<Vec<u8>> {
        if !download_url.starts_with('/') || download_url.starts_with("//") {
            return Err(SyncError::Other("attachment url must be server-relative".into()));
        }
        let Some(ctx) = self.api_context().read().await.clone().filter(|c| !c.rails_jwt.is_empty()) else {
            return Err(SyncError::AuthFailed("not signed in to inbox2".into()));
        };
        let url = url::Url::parse(&ctx.api_base)
            .and_then(|base| base.join(download_url))
            .map_err(|e| SyncError::Other(format!("attachment url: {e}")))?;
        let resp = client().get(url).bearer_auth(&ctx.rails_jwt).send().await?;
        match resp.status().as_u16() {
            200..=299 => Ok(resp.bytes().await?.to_vec()),
            401 => Err(SyncError::AuthFailed("inbox2 session expired".into())),
            code => Err(SyncError::HttpStatus { code, context: "mx attachment".into() }),
        }
    }

    async fn mx_pass(&self, ctx: &ApiContext, org: &str, user_key: &str, opts: MxSyncOptions) -> Result<MxSyncReport> {
        let store = self.store().clone();
        // A mirror built for someone else is about to be wiped: their keys go first.
        if store.mx_state(org)?.is_some_and(|held| held.user_key != user_key) {
            self.mx_domain_keys.write().remove(org);
        }
        let mut state = store.mx_begin(org, user_key)?;
        let mut report = MxSyncReport::default();

        if state.cursor.is_none() {
            let head: Value = mx_get(ctx, org, "sync/head", &[]).await?;
            let cursor = head.get("cursor").and_then(Value::as_str).unwrap_or_default();
            store.mx_set_cursor(org, cursor)?;
            state.cursor = Some(cursor.to_string());
        }

        if opts.directory || due(state.directory_at.as_deref()) {
            self.mx_directory(ctx, org).await?;
        }

        // Delta.
        let mut cursor = state.cursor.clone().unwrap_or_default();
        let mut expired = false;
        let mut drained = false;
        for _ in 0..PULL_PAGES_PER_PASS {
            let page: PullPage = mx_get(ctx, org, "sync/pull", &[("since", cursor.as_str())]).await?;
            self.still_mirrored(org, user_key)?;
            report.pulled += page.records.conversations.len() + page.records.messages.len() + page.records.notes.len();
            report.deleted += page.deleted.len();
            store.mx_apply(org, &page.records, false)?;
            store.mx_apply_deleted(org, &page.deleted)?;
            store.mx_set_cursor(org, &page.cursor)?;
            expired |= page.cursor_expired;
            if page.has_more && page.cursor == cursor {
                return Err(stuck("pull"));
            }
            cursor = page.cursor;
            if !page.has_more {
                drained = true;
                break;
            }
        }

        // History, newest first.
        if !state.backfill_done {
            let mut token = state.backfill_token.clone();
            for _ in 0..BACKFILL_PAGES_PER_PASS {
                let query: Vec<(&str, &str)> = token.as_deref().map(|t| ("before", t)).into_iter().collect();
                let page: BackfillPage = mx_get(ctx, org, "sync/backfill", &query).await?;
                self.still_mirrored(org, user_key)?;
                report.backfilled += page.records.conversations.len();
                store.mx_apply(org, &page.records, true)?;
                if page.next.is_some() && page.next == token {
                    return Err(stuck("backfill"));
                }
                store.mx_set_backfill(org, page.next.as_deref())?;
                token = page.next;
                if token.is_none() {
                    state.backfill_done = true;
                    break;
                }
            }
        }
        report.backfill_done = state.backfill_done;

        // Reconcile. Removal never waits for history — revoked mail goes now — but
        // until backfill is done, "absent here" just means "not read yet".
        let mut hydrate = Vec::new();
        if opts.reconcile || expired || due(state.reconciled_at.as_deref()) {
            let started = SyncStore::mx_now();
            let mut listing = Vec::new();
            let mut after: Option<String> = None;
            for page_no in 0.. {
                let query: Vec<(&str, &str)> = after.as_deref().map(|a| ("after", a)).into_iter().collect();
                let page: KeysPage = mx_get(ctx, org, "sync/keys", &query).await?;
                listing.extend(page.keys);
                if page.next.is_none() {
                    break;
                }
                if page.next == after || page_no >= KEYS_PAGES_MAX {
                    return Err(stuck("keys"));
                }
                after = page.next;
            }
            let plan = store.mx_reconcile(org, &listing, &started)?;
            report.removed = plan.removed;
            hydrate = plan.hydrate;
            if state.backfill_done {
                hydrate.extend(plan.absent);
            }
        }

        // Hydrate: what reconcile asked for, plus threads first seen in a delta.
        for key in store.mx_apply(org, &MxRecords::default(), false)? {
            if !hydrate.contains(&key) {
                hydrate.push(key);
            }
        }
        let mut batches = 0;
        while !hydrate.is_empty() && batches < HYDRATE_BATCHES_PER_PASS {
            batches += 1;
            let take = hydrate.len().min(HYDRATE_BATCH);
            let batch: Vec<String> = hydrate.drain(..take).collect();
            let query: Vec<(&str, &str)> = batch.iter().map(|k| ("ids[]", k.as_str())).collect();
            let page: ThreadsPage = mx_get(ctx, org, "sync/threads", &query).await?;
            self.still_mirrored(org, user_key)?;
            report.hydrated += page.records.conversations.len();
            store.mx_apply(org, &page.records, true)?;
            store.mx_drop_threads(org, &page.missing)?;
            report.removed += page.missing.len();
            let progressed = !page.records.conversations.is_empty() || !page.missing.is_empty();
            hydrate.extend(page.remaining);
            // Nothing it was asked for came back: asking again won't help this pass.
            if !progressed {
                break;
            }
        }

        self.mx_open_sealed(org);

        report.more = !drained || !state.backfill_done || !hydrate.is_empty();
        if report != (MxSyncReport { backfill_done: report.backfill_done, ..Default::default() }) {
            self.emit("mx-sync", serde_json::json!({ "org": org, "report": &report }));
        }
        Ok(report)
    }

    async fn mx_directory(&self, ctx: &ApiContext, org: &str) -> Result<()> {
        let store = self.store();
        match mx_get::<Value>(ctx, org, "", &[]).await {
            Ok(v) => store.mx_directory_replace(org, "organization", v.get("organization").map(std::slice::from_ref).unwrap_or_default())?,
            Err(e @ (SyncError::AuthFailed(_) | SyncError::HttpStatus { code: 404, .. })) => return Err(e),
            Err(e) => log::warn!("[mx] {org}: organization listing failed: {e}"),
        }
        for (path, field, kind) in DIRECTORY {
            match mx_get::<Value>(ctx, org, path, &[]).await {
                Ok(v) => {
                    let items = v.get(field).and_then(Value::as_array).cloned().unwrap_or_default();
                    store.mx_directory_replace(org, kind, &items)?;
                }
                Err(e @ SyncError::AuthFailed(_)) => return Err(e),
                // Forbidden for this role, or a blip: keep what we had.
                Err(e) => log::warn!("[mx] {org}: {kind} listing failed: {e}"),
            }
        }
        Ok(())
    }

}

/// GET `orgs/:org/<path>` as JSON.
/// Local calendar rows → merged absolute busy periods inside `[from, to)`.
/// Timed events carry their own offset; all-day events cover whole days in the
/// device's zone. Zero-length entries (reminders, tasks) are not busy.
fn busy_blocks(
    rows: &[(String, String, bool)],
    from: chrono::DateTime<chrono::Utc>,
    to: chrono::DateTime<chrono::Utc>,
) -> Vec<(chrono::DateTime<chrono::Utc>, chrono::DateTime<chrono::Utc>)> {
    use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
    let parse = |value: &str, all_day: bool| -> Option<DateTime<Utc>> {
        if all_day {
            let day = NaiveDate::parse_from_str(value.get(..10)?, "%Y-%m-%d").ok()?;
            Local.from_local_datetime(&day.and_hms_opt(0, 0, 0)?).earliest().map(|t| t.with_timezone(&Utc))
        } else {
            DateTime::parse_from_rfc3339(value).ok().map(|t| t.with_timezone(&Utc))
        }
    };
    let mut periods: Vec<_> = rows
        .iter()
        .filter_map(|(start, end, all_day)| {
            let (s, e) = (parse(start, *all_day)?.max(from), parse(end, *all_day)?.min(to));
            (e > s).then_some((s, e))
        })
        .collect();
    periods.sort();
    let mut merged: Vec<(DateTime<Utc>, DateTime<Utc>)> = Vec::new();
    for (s, e) in periods {
        match merged.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => merged.push((s, e)),
        }
    }
    merged
}

async fn mx_get<T: serde::de::DeserializeOwned>(ctx: &ApiContext, org: &str, path: &str, query: &[(&str, &str)]) -> Result<T> {
    mx_fetch(ctx, &format!("orgs/{org}/{path}"), query).await
}

/// 401 → `AuthFailed`; any other non-2xx → `HttpStatus`, so callers can tell
/// "gone" from "down".
async fn mx_fetch<T: serde::de::DeserializeOwned>(ctx: &ApiContext, path: &str, query: &[(&str, &str)]) -> Result<T> {
    let url = format!("{}/{}", ctx.api_base.trim_end_matches('/'), path.trim_end_matches('/'));
    let resp = client().get(url).query(query).bearer_auth(&ctx.rails_jwt).send().await?;
    match resp.status().as_u16() {
        200..=299 => Ok(resp.json().await?),
        401 => Err(SyncError::AuthFailed("inbox2 session expired".into())),
        code => Err(SyncError::HttpStatus { code, context: format!("mx {path}") }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::events::NullSink;
    use serde_json::json;
    use std::sync::Arc;
    use wiremock::matchers::{header, method, path, query_param, query_param_is_missing};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    const ORG: &str = "org_a";

    fn conv(key: &str, seq: i64) -> Value {
        json!({"id": key, "change_seq": seq, "status": "open", "read": false, "updated_at": "2026-09-20T10:00:00Z"})
    }
    fn msg(key: &str, thread: &str) -> Value {
        json!({"id": key, "conversation_id": thread, "change_seq": 1, "encryption_scheme": "none"})
    }
    fn ok(body: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(body)
    }
    fn at(p: &str) -> String {
        format!("/api/v1/orgs/{ORG}/{p}")
    }

    async fn engine(server: &MockServer) -> SyncEngine {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = SyncEngine::new(store, Arc::new(NullSink));
        engine.set_api_context(format!("{}/api/v1", server.uri()), "ink_tok".into()).await;
        engine
    }

    /// History that never ends: every page empty, every token new.
    async fn endless_history(server: &MockServer) {
        let n = std::sync::atomic::AtomicUsize::new(0);
        Mock::given(method("GET")).and(path(at("sync/backfill")))
            .respond_with(move |_: &wiremock::Request| {
                ok(json!({"next": format!("t{}", n.fetch_add(1, std::sync::atomic::Ordering::SeqCst)), "records": {}}))
            })
            .mount(server).await;
    }

    async fn lists(server: &MockServer, keys: Value) {
        Mock::given(method("GET")).and(path(at("sync/keys")))
            .respond_with(ok(json!({"keys": keys, "next": null}))).mount(server).await;
    }

    /// Directory + an empty delta + empty history + an empty key listing: the quiet
    /// baseline. wiremock answers with the first mounted match, so tests mount their
    /// own responses first and this last.
    async fn quiet(server: &MockServer) {
        for (p, body) in [
            ("sync/head", json!({"cursor": "100.0"})),
            ("sync/pull", json!({"cursor": "100.0", "has_more": false, "records": {}, "deleted": []})),
            ("sync/backfill", json!({"next": null, "records": {}})),
            ("sync/keys", json!({"keys": [], "next": null})),
            ("domains", json!({"domains": [{"id": "dom_1", "name": "acme.test"}]})),
            ("members", json!({"members": []})),
            ("tags", json!({"tags": [{"id": "tag_1"}]})),
            ("spaces", json!({"spaces": []})),
            ("triage-labels", json!({"triage_labels": []})),
            ("views", json!({"views": []})),
        ] {
            Mock::given(method("GET")).and(path(at(p))).respond_with(ok(body)).mount(server).await;
        }
        Mock::given(method("GET")).and(path(format!("/api/v1/orgs/{ORG}")))
            .respond_with(ok(json!({"organization": {"id": ORG, "name": "Acme"}}))).mount(server).await;
    }

    fn count(engine: &SyncEngine, table: &str) -> i64 {
        engine.store().mx_count_for_test(table)
    }

    #[tokio::test]
    async fn first_pass_parks_the_cursor_then_lists_the_directory_and_reads_history() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/backfill"))).and(query_param_is_missing("before"))
            .and(header("authorization", "Bearer ink_tok"))
            .respond_with(ok(json!({"next": "t1", "records": {"conversations": [conv("conv_new", 9)], "messages": [msg("msg_1", "conv_new")]}})))
            .mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/backfill"))).and(query_param("before", "t1"))
            .respond_with(ok(json!({"next": null, "records": {"conversations": [conv("conv_old", 0)]}})))
            .mount(&server).await;
        lists(&server, json!([["conv_new", 9], ["conv_old", 0]])).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!((report.backfilled, report.backfill_done, report.more), (2, true, false));
        assert_eq!(count(&engine, "mx_conversations"), 2);
        assert_eq!(count(&engine, "mx_messages"), 1);
        assert_eq!(count(&engine, "mx_directory"), 3); // org + domain + tag

        let state = engine.store().mx_state(ORG).unwrap().unwrap();
        assert_eq!(state.cursor.as_deref(), Some("100.0"));
        assert!(state.backfill_done && state.reconciled_at.is_some());

        // head is asked exactly once, ever: the second pass resumes from state.
        engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        let heads = server.received_requests().await.unwrap().iter().filter(|r| r.url.path().ends_with("sync/head")).count();
        assert_eq!(heads, 1);
    }

    #[tokio::test]
    async fn delta_pages_until_drained_applies_deletes_and_saves_the_cursor() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/pull"))).and(query_param("since", "100.0"))
            .respond_with(ok(json!({"cursor": "101.5", "has_more": true,
                "records": {"conversations": [conv("conv_1", 5), conv("conv_2", 5)], "messages": [msg("msg_1", "conv_1")]}, "deleted": []})))
            .mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/pull"))).and(query_param("since", "101.5"))
            .respond_with(ok(json!({"cursor": "140.0", "has_more": false, "records": {},
                "deleted": [{"type": "conversation", "id": "conv_2"}]})))
            .mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/threads"))).and(query_param("ids[]", "conv_1"))
            .respond_with(ok(json!({"records": {"conversations": [conv("conv_1", 5)], "messages": [msg("msg_1", "conv_1")]}})))
            .mount(&server).await;
        lists(&server, json!([["conv_1", 5]])).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!((report.pulled, report.deleted), (3, 1));
        assert_eq!(count(&engine, "mx_conversations"), 1);
        assert_eq!(engine.store().mx_state(ORG).unwrap().unwrap().cursor.as_deref(), Some("140.0"));
    }

    #[tokio::test]
    async fn a_thread_first_seen_in_a_delta_is_hydrated_and_a_refused_one_dropped() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/pull")))
            .respond_with(ok(json!({"cursor": "120.0", "has_more": false,
                "records": {"conversations": [conv("conv_shared", 7), conv("conv_revoked", 7)]}, "deleted": []})))
            .mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/threads")))
            .respond_with(ok(json!({"records": {"conversations": [conv("conv_shared", 7)],
                "messages": [msg("msg_a", "conv_shared"), msg("msg_b", "conv_shared")]},
                "missing": ["conv_revoked"], "remaining": []})))
            .mount(&server).await;
        lists(&server, json!([["conv_shared", 7], ["conv_revoked", 7]])).await; // a listing fetched just before the revoke
        quiet(&server).await;
        let engine = engine(&server).await;

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!((report.hydrated, report.removed, report.more), (1, 1, false));
        assert_eq!(count(&engine, "mx_conversations"), 1);
        assert_eq!(count(&engine, "mx_messages"), 2);
    }

    #[tokio::test]
    async fn reconcile_removes_what_the_server_no_longer_lists() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/backfill")))
            .respond_with(ok(json!({"next": null, "records": {"conversations": [conv("conv_keep", 3), conv("conv_lost", 3)]}})))
            .mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/keys"))).and(query_param_is_missing("after"))
            .respond_with(ok(json!({"keys": [["conv_keep", 3]], "next": "conv_keep"}))).mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/keys"))).and(query_param("after", "conv_keep"))
            .respond_with(ok(json!({"keys": [], "next": null}))).mount(&server).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!(report.removed, 1);
        assert_eq!(count(&engine, "mx_conversations"), 1);

        // Hourly after that — unless asked.
        let keys = |reqs: &[wiremock::Request]| reqs.iter().filter(|r| r.url.path().ends_with("sync/keys")).count();
        engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!(keys(&server.received_requests().await.unwrap()), 2);
        engine.mx_sync(ORG, "usr_1", MxSyncOptions { reconcile: true, ..Default::default() }).await.unwrap();
        assert_eq!(keys(&server.received_requests().await.unwrap()), 4);
    }

    #[tokio::test]
    async fn history_is_bounded_per_pass_and_resumes_from_the_saved_token() {
        let server = MockServer::start().await;
        endless_history(&server).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert!(report.more && !report.backfill_done);
        let state = engine.store().mx_state(ORG).unwrap().unwrap();
        assert_eq!(state.backfill_token.as_deref(), Some("t4"));
        let pages = server.received_requests().await.unwrap().iter().filter(|r| r.url.path().ends_with("sync/backfill")).count();
        assert_eq!(pages, BACKFILL_PAGES_PER_PASS);
    }

    #[tokio::test]
    async fn an_expired_session_changes_nothing() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(401)).mount(&server).await;
        let engine = engine(&server).await;
        let err = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap_err();
        assert!(err.is_auth(), "{err}");
    }

    #[tokio::test]
    async fn losing_the_org_wipes_the_mirror() {
        let server = MockServer::start().await;
        quiet(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        engine.store().mx_apply(ORG, &MxRecords { conversations: vec![conv("conv_1", 1)], ..Default::default() }, true).unwrap();

        server.reset().await;
        Mock::given(method("GET")).and(path("/api/v1/account")).respond_with(ok(json!({"user": {}}))).mount(&server).await;
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(404)).mount(&server).await;
        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions { directory: true, ..Default::default() }).await.unwrap();
        assert_eq!(report, MxSyncReport::default());
        assert_eq!(count(&engine, "mx_conversations"), 0);
        assert!(engine.store().mx_state(ORG).unwrap().is_none());
    }

    #[tokio::test]
    async fn a_404_from_one_route_is_an_error_not_a_wipe() {
        // An older server without sync/threads: the org is fine, the route isn't.
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/pull")))
            .respond_with(ok(json!({"cursor": "120.0", "has_more": false, "records": {"conversations": [conv("conv_1", 7)]}, "deleted": []})))
            .mount(&server).await;
        lists(&server, json!([["conv_1", 7]])).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        let err = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap_err();
        assert!(matches!(err, SyncError::HttpStatus { code: 404, .. }), "{err}");
        assert_eq!(count(&engine, "mx_conversations"), 1);
        assert!(engine.store().mx_state(ORG).unwrap().is_some());
    }

    #[tokio::test]
    async fn a_base_where_everything_404s_is_an_error_not_a_wipe() {
        let server = MockServer::start().await;
        quiet(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        engine.store().mx_apply(ORG, &MxRecords { conversations: vec![conv("conv_1", 1)], ..Default::default() }, true).unwrap();

        server.reset().await; // wrong base / old server: nothing answers, not even /account
        Mock::given(method("GET")).respond_with(ResponseTemplate::new(404)).mount(&server).await;
        assert!(engine.mx_sync(ORG, "usr_1", MxSyncOptions { directory: true, ..Default::default() }).await.is_err());
        assert_eq!(count(&engine, "mx_conversations"), 1);
    }

    #[tokio::test]
    async fn revoked_mail_is_removed_even_while_history_is_still_being_read() {
        let server = MockServer::start().await;
        endless_history(&server).await;
        lists(&server, json!([["conv_keep", 3], ["conv_not_read_yet", 3]])).await;
        quiet(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        let held = MxRecords { conversations: vec![conv("conv_keep", 3), conv("conv_revoked", 3)], ..Default::default() };
        engine.store().mx_apply(ORG, &held, true).unwrap();

        let report = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert!(!report.backfill_done);
        // Gone now. The thread we simply haven't read yet is backfill's job, not hydration's.
        assert_eq!((report.removed, report.hydrated), (1, 0));
        assert_eq!(count(&engine, "mx_conversations"), 1);
    }

    #[tokio::test]
    async fn a_server_that_repeats_a_history_token_is_an_error_not_a_loop() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/backfill")))
            .respond_with(ok(json!({"next": "again", "records": {}}))).mount(&server).await;
        quiet(&server).await;
        let engine = engine(&server).await;
        let err = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap_err();
        assert!(err.to_string().contains("same position"), "{err}");
    }

    #[tokio::test]
    async fn a_server_that_pages_in_place_is_an_error_not_a_loop() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/pull")))
            .respond_with(ok(json!({"cursor": "100.0", "has_more": true, "records": {}, "deleted": []}))).mount(&server).await;
        quiet(&server).await;
        let engine = engine(&server).await;
        let err = engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap_err();
        assert!(err.to_string().contains("same position"), "{err}");
    }

    #[tokio::test]
    async fn a_server_error_keeps_the_mirror_and_the_cursor() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/pull"))).respond_with(ResponseTemplate::new(503)).mount(&server).await;
        quiet(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        engine.store().mx_set_cursor(ORG, "77.0").unwrap();
        engine.store().mx_apply(ORG, &MxRecords { conversations: vec![conv("conv_1", 1)], ..Default::default() }, true).unwrap();

        assert!(engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.is_err());
        assert_eq!(count(&engine, "mx_conversations"), 1);
        assert_eq!(engine.store().mx_state(ORG).unwrap().unwrap().cursor.as_deref(), Some("77.0"));
    }

    /// Live end-to-end against a real API — the fakes above prove the logic, this
    /// proves the shapes line up with what Rails actually serializes.
    ///   MX_E2E_BASE=http://localhost:4011/api/v1 MX_E2E_TOKEN=… MX_E2E_ORG=org_… MX_E2E_USER=usr_… \
    ///     cargo test -p inbox2-core --lib mx_sync::tests::live -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "needs a running API: see the env vars above"]
    async fn live_end_to_end() {
        let var = |k: &str| std::env::var(k).unwrap_or_else(|_| panic!("{k} not set"));
        let (org, user) = (var("MX_E2E_ORG"), var("MX_E2E_USER"));
        let engine = SyncEngine::new(Arc::new(SyncStore::new_in_memory().unwrap()), Arc::new(NullSink));
        engine.set_api_context(var("MX_E2E_BASE"), var("MX_E2E_TOKEN")).await;

        let mut passes = 0;
        loop {
            passes += 1;
            let report = engine.mx_sync(&org, &user, MxSyncOptions::default()).await.expect("pass");
            println!("pass {passes}: {report:?}");
            assert!(passes < 500, "never finished");
            if !report.more {
                break;
            }
        }
        let n = |t: &str| count(&engine, t);
        println!("mirror: {} threads, {} messages, {} notes, {} directory rows",
                 n("mx_conversations"), n("mx_messages"), n("mx_notes"), n("mx_directory"));
        if let Ok(expect) = std::env::var("MX_E2E_EXPECT") {
            let got = format!("{}/{}", n("mx_conversations"), n("mx_messages"));
            assert_eq!(got, expect, "threads/messages vs the server's own count");
        }
        assert!(n("mx_directory") > 0, "directory listings came back empty — response keys drifted?");
        let unhydrated = engine.store().mx_apply(&org, &MxRecords::default(), false).unwrap();
        assert!(unhydrated.is_empty(), "left unhydrated: {unhydrated:?}");

        // A settled mirror: another pass moves nothing.
        let again = engine.mx_sync(&org, &user, MxSyncOptions { reconcile: true, directory: true }).await.unwrap();
        println!("steady state: {again:?}");
        assert_eq!((again.pulled, again.backfilled, again.hydrated, again.removed), (0, 0, 0, 0));

        // MX_E2E_WRITE=1: flip one thread's read flag through the real endpoint and
        // watch the delta carry it (then flip it back).
        if std::env::var("MX_E2E_WRITE").is_ok() {
            let base = var("MX_E2E_BASE");
            assert!(base.contains("://localhost") || base.contains("://127.0.0.1"), "MX_E2E_WRITE is for a local API only");
            let (key, was_read): (String, i64) = engine.store().mx_first_thread_for_test(&org);
            for read in [was_read == 0, was_read != 0] {
                let url = format!("{}/orgs/{org}/conversations/{key}", var("MX_E2E_BASE"));
                let resp = client().patch(url).bearer_auth(var("MX_E2E_TOKEN")).json(&json!({ "read": read })).send().await.unwrap();
                assert!(resp.status().is_success(), "{}", resp.status());
                let report = engine.mx_sync(&org, &user, MxSyncOptions::default()).await.unwrap();
                println!("after read={read}: {report:?}");
                assert!(report.pulled >= 1, "the write never reached the delta");
                assert_eq!(engine.store().mx_first_thread_for_test(&org), (key.clone(), read as i64));
            }
        }
    }

    use wiremock::matchers::body_json;

    async fn holding(engine: &SyncEngine, keys: &[&str]) {
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        let held = MxRecords { conversations: keys.iter().map(|k| conv(k, 1)).collect(), ..Default::default() };
        engine.store().mx_apply(ORG, &held, true).unwrap();
    }

    #[tokio::test]
    async fn an_action_shows_locally_and_lands_as_one_bulk_request() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path(at("conversations/bulk")))
            .and(body_json(json!({"conversation_ids": ["conv_1", "conv_2"], "action_name": "archive"})))
            .respond_with(ok(json!({"updated": 2}))).expect(1).mount(&server).await;
        let engine = engine(&server).await;
        holding(&engine, &["conv_1", "conv_2"]).await;

        engine.mx_action(ORG, &["conv_1".into(), "conv_2".into()], "archive").await.unwrap();
        assert_eq!(engine.store().mx_first_thread_status_for_test(ORG), "archived");
        assert!(engine.store().mx_claim_actions().unwrap().is_none(), "nothing left to send");
    }

    #[tokio::test]
    async fn a_partly_applied_bulk_action_re_fetches_its_threads() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path(at("conversations/bulk")))
            .respond_with(ok(json!({"updated": 1}))).mount(&server).await; // asked for 2
        let engine = engine(&server).await;
        holding(&engine, &["conv_1", "conv_2"]).await;

        engine.mx_action(ORG, &["conv_1".into(), "conv_2".into()], "archive").await.unwrap();
        let mut refetch = engine.store().mx_apply(ORG, &MxRecords::default(), false).unwrap();
        refetch.sort();
        assert_eq!(refetch, vec!["conv_1", "conv_2"]);
    }

    #[tokio::test]
    async fn offline_the_action_still_shows_and_is_sent_later() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path(at("conversations/bulk")))
            .respond_with(ResponseTemplate::new(503)).up_to_n_times(1).mount(&server).await;
        Mock::given(method("POST")).and(path(at("conversations/bulk")))
            .respond_with(ok(json!({"updated": 1}))).expect(1).mount(&server).await;
        let engine = engine(&server).await;
        holding(&engine, &["conv_1"]).await;

        engine.mx_action(ORG, &["conv_1".into()], "trash").await.unwrap(); // 503: queued, not lost
        assert_eq!(engine.store().mx_first_thread_status_for_test(ORG), "trash");
        assert_eq!(engine.mx_drain().await, 0, "backing off");

        engine.store().mx_make_actions_due_for_test();
        assert_eq!(engine.mx_drain().await, 1);
    }

    #[tokio::test]
    async fn a_phone_unlocks_with_the_password() {
        let raw = std::fs::read_to_string(format!("{}/testdata/identity_by_js.json", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let f: Value = serde_json::from_str(&raw).unwrap();
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path("/api/v1/user-key"))
            .respond_with(ok(json!({"user_key": {"encrypted_private_key": f["encrypted_private_key"]}}))).mount(&server).await;
        Mock::given(method("GET")).and(path(at("e2ee/my-grants")))
            .respond_with(ok(json!({"grants": [{"version": 3, "public_key": f["domain_public_key"],
                                                "sealed_secret_key": f["sealed_secret_key"]}]}))).expect(1).mount(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        let sealed = MxRecords { conversations: vec![conv("conv_s", 1)], messages: vec![json!({"id": "msg_s", "conversation_id": "conv_s", "change_seq": 1,
            "encryption_scheme": "sealed_box_v2", "sealed": f["sealed"]})], ..Default::default() };
        engine.store().mx_apply(ORG, &sealed, false).unwrap();

        assert!(engine.mx_unlock_identity("wrong").await.unwrap().is_none());
        let identity = engine.mx_unlock_identity(f["password"].as_str().unwrap()).await.unwrap().unwrap();
        assert_eq!(engine.mx_unlock_org(ORG, &identity).await.unwrap(), 1);
        assert!(engine.store().mx_unopened(ORG, "", 10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_refused_action_gives_the_thread_back_to_the_server() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path(at("conversations/bulk")))
            .respond_with(ResponseTemplate::new(422)).expect(1).mount(&server).await;
        let engine = engine(&server).await;
        holding(&engine, &["conv_1"]).await;

        engine.mx_action(ORG, &["conv_1".into()], "spam").await.unwrap();
        assert_eq!(engine.mx_drain().await, 0, "not retried");
        let refetch = engine.store().mx_apply(ORG, &MxRecords::default(), false).unwrap();
        assert_eq!(refetch, vec!["conv_1"]);
    }

    #[tokio::test]
    async fn sealed_mail_is_opened_once_the_member_unlocks_and_as_it_arrives() {
        let fixture: Value = serde_json::from_str(
            &std::fs::read_to_string(format!("{}/testdata/sealed_by_go.json", env!("CARGO_MANIFEST_DIR"))).unwrap()).unwrap();
        let sealed_msg = |key: &str| json!({"id": key, "conversation_id": "conv_s", "change_seq": 1,
            "encryption_scheme": "sealed_box_v1", "sealed": fixture["sealed"]});
        let mut thread = conv("conv_s", 1);
        thread["subject"] = Value::Null;

        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("sync/backfill")))
            .respond_with(ok(json!({"next": null, "records": {"conversations": [thread], "messages": [sealed_msg("msg_1")]}}))).mount(&server).await;
        Mock::given(method("GET")).and(path(at("sync/pull"))).and(query_param("since", "100.0"))
            .respond_with(ok(json!({"cursor": "101.0", "has_more": false, "records": {"conversations": [conv("conv_s", 2)], "messages": [sealed_msg("msg_2")]}, "deleted": []})))
            .up_to_n_times(1).mount(&server).await;
        lists(&server, json!([["conv_s", 1]])).await;
        quiet(&server).await;
        let engine = engine(&server).await;

        // Locked: mirrored as ciphertext only.
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        engine.store().mx_set_cursor(ORG, "999.0").unwrap(); // no delta yet
        engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert_eq!(engine.store().mx_unopened(ORG, "", 10).unwrap().len(), 1);

        // Unlock: what is already here opens at once…
        let key = crate::sync::seal::DomainKey::from_b64(3, fixture["domain_public_key"].as_str().unwrap(),
                                                         fixture["domain_secret_key"].as_str().unwrap()).unwrap();
        assert_eq!(engine.mx_set_domain_keys(ORG, vec![key]), 1);
        // …and mail that arrives later opens as part of the pass that brings it.
        engine.store().mx_set_cursor(ORG, "100.0").unwrap();
        engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap();
        assert!(engine.store().mx_unopened(ORG, "", 10).unwrap().is_empty());

        // Mail no held key fits must not hide openable mail queued behind it.
        let other = serde_json::from_str::<Value>(
            &std::fs::read_to_string(format!("{}/testdata/sealed_by_js.json", env!("CARGO_MANIFEST_DIR"))).unwrap()).unwrap();
        let foreign = MxRecords { messages: (0..3).map(|i| json!({"id": format!("msg_0_foreign_{i}"), "conversation_id": "conv_s",
            "change_seq": 1, "encryption_scheme": "sealed_box_v1", "sealed": other["sealed"]})).collect(), ..Default::default() };
        engine.store().mx_apply(ORG, &foreign, false).unwrap();
        engine.store().mx_apply(ORG, &MxRecords { messages: vec![sealed_msg("msg_9_ours")], ..Default::default() }, false).unwrap();
        assert_eq!(engine.mx_open_sealed(ORG), 1);
        assert_eq!(engine.store().mx_unopened(ORG, "", 10).unwrap().len(), 3);

        // Forgetting the org takes the keys with it, not just the rows.
        engine.mx_forget(ORG).await.unwrap();
        assert!(engine.mx_domain_keys.read().is_empty());
        engine.mx_domain_keys.write().insert(ORG.into(), vec![]);

        // Lock again: keys leave memory; nothing new opens.
        assert_eq!(engine.mx_set_domain_keys(ORG, vec![]), 0);
        assert!(engine.mx_domain_keys.read().is_empty());
    }

    #[tokio::test]
    async fn a_sign_out_during_a_pass_leaves_nothing_on_disk() {
        let server = MockServer::start().await;
        // History arrives slowly; the user signs out while the page is in flight.
        Mock::given(method("GET")).and(path(at("sync/backfill")))
            .respond_with(ok(json!({"next": null, "records": {"conversations": [conv("conv_late", 1)], "messages": [msg("msg_late", "conv_late")]}}))
                .set_delay(std::time::Duration::from_millis(400)))
            .mount(&server).await;
        quiet(&server).await;
        let engine = Arc::new(engine(&server).await);

        let pass = { let e = engine.clone(); tokio::spawn(async move { e.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await }) };
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        engine.mx_forget(ORG).await.unwrap();

        assert!(pass.await.unwrap().is_err(), "the pass notices and stops");
        assert_eq!(count(&engine, "mx_conversations") + count(&engine, "mx_messages"), 0);
        assert!(engine.store().mx_state(ORG).unwrap().is_none());
    }

    #[tokio::test]
    async fn the_tick_syncs_every_mirrored_org() {
        let server = MockServer::start().await;
        quiet(&server).await;
        let engine = engine(&server).await;
        engine.store().mx_begin(ORG, "usr_1").unwrap();
        engine.mx_tick().await;
        assert!(engine.store().mx_state(ORG).unwrap().unwrap().backfill_done);
    }

    #[test]
    fn busy_blocks_merge_clip_and_skip_zero_length() {
        let at = |s: &str| chrono::DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&chrono::Utc);
        let rows = vec![
            ("2026-09-29T09:00:00+02:00".into(), "2026-09-29T17:00:00+02:00".into(), false),
            ("2026-09-29T08:00:00Z".into(), "2026-09-29T10:00:00Z".into(), false), // inside the day above
            ("2026-09-28T09:00:00Z".into(), "2026-09-28T09:00:00Z".into(), false), // reminder
            ("2026-09-20T09:00:00Z".into(), "2026-09-24T12:00:00Z".into(), false), // clipped at `from`
        ];
        let blocks = busy_blocks(&rows, at("2026-09-24T00:00:00Z"), at("2026-10-24T00:00:00Z"));
        assert_eq!(blocks, vec![
            (at("2026-09-24T00:00:00Z"), at("2026-09-24T12:00:00Z")),
            (at("2026-09-29T07:00:00Z"), at("2026-09-29T15:00:00Z")),
        ]);
        let all_day = busy_blocks(&[("2026-09-30".into(), "2026-10-01".into(), true)],
                                  at("2026-09-24T00:00:00Z"), at("2026-10-24T00:00:00Z"));
        assert_eq!(all_day.len(), 1);
        assert_eq!(all_day[0].1 - all_day[0].0, chrono::Duration::hours(24));
    }

    #[tokio::test]
    async fn busy_upload_puts_bare_blocks_once_until_they_change() {
        let server = MockServer::start().await;
        Mock::given(method("PUT")).and(path(format!("/api/v1/orgs/{ORG}/external-busy")))
            .respond_with(ResponseTemplate::new(204)).expect(1).mount(&server).await;
        let engine = engine(&server).await;
        engine.mx_push_busy(ORG).await.unwrap();
        engine.mx_push_busy(ORG).await.unwrap(); // unchanged → not re-sent
        let sent = &server.received_requests().await.unwrap()[0];
        let body: Value = serde_json::from_slice(&sent.body).unwrap();
        assert!(body["source"].as_str().unwrap().starts_with("dev_"));
        assert!(body["blocks"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn without_a_session_it_does_not_call_out() {
        let server = MockServer::start().await;
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let engine = SyncEngine::new(store, Arc::new(NullSink));
        engine.set_api_context(format!("{}/api/v1", server.uri()), String::new()).await;
        assert!(engine.mx_sync(ORG, "usr_1", MxSyncOptions::default()).await.unwrap_err().is_auth());
        assert!(server.received_requests().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn attachment_download_is_bearer_authed_and_refuses_off_host_urls() {
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path(at("attachments/att_1"))).and(header("authorization", "Bearer ink_tok"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"%PDF".to_vec()))
            .mount(&server).await;
        let engine = engine(&server).await;
        assert_eq!(engine.mx_download_attachment(&at("attachments/att_1")).await.unwrap(), b"%PDF");
        assert!(engine.mx_download_attachment("https://evil.test/x").await.is_err());
        assert!(engine.mx_download_attachment("//evil.test/x").await.is_err());
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}
