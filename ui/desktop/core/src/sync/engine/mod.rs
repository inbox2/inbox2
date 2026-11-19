use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, Mutex, RwLock};

use crate::sync::actions::WritebackQueue;
use crate::sync::adapters;
use crate::sync::error::{Result, SyncError};
use crate::sync::interactive::OutgoingMessage;
use crate::sync::model::*;
use crate::sync::outbox::OutboxQueue;
use crate::sync::provider::ProviderAdapter;
use crate::sync::store::SyncStore;

mod calendar;
mod conversation_actions;
mod queues;
mod runtime;
mod sync_flow;
mod tracking;
#[cfg(test)]
mod tests;

const INITIAL_RECONNECT_SECS: u64 = 1;
const MAX_RECONNECT_SECS: u64 = 300;

/// Shared handle to an account's provider adapter.
///
/// The adapter lives behind its own per-account lock, separate from the
/// `accounts` map lock. Sync operations clone this handle under a brief map
/// lock, release the map, then hold only the adapter lock across network I/O —
/// so a long-running sync never blocks the map, and global ops (shutdown,
/// add_account, status/diagnostics queries) stay responsive mid-sync.
type AdapterHandle = Arc<Mutex<Box<dyn ProviderAdapter>>>;

/// Per-account sync state tracked by the engine.
struct AccountState {
    adapter: AdapterHandle,
    credentials: ProviderCredentials,
    status: AccountStatus,
    folders: Vec<UnifiedFolder>,
    reconnect_backoff_secs: u64,
    /// The pending reconnect-backoff task for this account, if any. Tracked so a
    /// flapping account replaces (aborts) its previous sleeper instead of
    /// accumulating one per disconnect.
    reconnect_task: Option<tokio::task::JoinHandle<()>>,
}

/// See the `jev` field on [`SyncEngine`].
struct JevKeyState {
    key: Option<String>,
    unauthorized: bool,
    /// Jev said 402/403 (credits, billing): the message + when, so the worker
    /// pauses and probes once a minute. Cleared by any answered call.
    blocked: Option<(String, std::time::Instant)>,
    endpoint: String,
}

/// How long a blocked Jev account pauses the triage queue between probes.
const JEV_BLOCKED_PROBE: std::time::Duration = std::time::Duration::from_secs(60);

/// Tally of one account-level sync run, surfaced in the `completed` event and
/// the server log so a client report reads "4 folders, 600 messages in 42s".
#[derive(Default)]
struct SyncSummary {
    folders: usize,
    messages: usize,
}

/// Provider-agnostic sync engine.
///
/// Orchestrates provider adapters, manages per-account lifecycle, processes
/// the write-back queue, and handles error recovery (UIDVALIDITY changes,
/// reconnections with exponential backoff).
pub struct SyncEngine {
    store: Arc<SyncStore>,
    writeback: Arc<WritebackQueue>,
    /// Durable outbox for user-composed provider sends (drained on the loop).
    outbox: Arc<OutboxQueue>,
    /// Accounts are behind a tokio Mutex (Send-safe across await points).
    accounts: Arc<Mutex<HashMap<String, AccountState>>>,
    event_tx: mpsc::UnboundedSender<ProviderEvent>,
    /// Behind a Mutex<Option<>> so `run()` can take it with `&self`, allowing
    /// the engine to be shared (Arc) between the run-loop task and commands.
    event_rx: Mutex<Option<mpsc::UnboundedReceiver<ProviderEvent>>>,
    shutdown: Arc<tokio::sync::Notify>,
    /// Where refresh events are delivered (webview, IPC socket clients, both, or
    /// nowhere). See [`crate::sync::events::EventSink`].
    sink: Arc<dyn crate::sync::events::EventSink>,
    /// Rails proxy context for OAuth token refresh (set by the frontend on boot).
    api_context: Arc<RwLock<Option<ApiContext>>>,
    /// Accounts with a sync in flight, keyed to whether the run is user-visible
    /// (`true` for full syncs that emit started/completed; `false` for the
    /// silent periodic-poll / push-coalesce paths). The map serializes ALL sync
    /// paths per account, but only visible runs are reported to the UI — the
    /// 60s background polls must not blink the "Syncing…" indicator forever.
    /// Deliberately a separate, fast (non-async) lock — NOT the `accounts`
    /// mutex, which is held across network I/O during a sync, so querying it
    /// would block for the whole run.
    syncing: Arc<parking_lot::Mutex<HashMap<String, bool>>>,
    /// Monotonic id stamped on every `sync` event (`seq`), so the UI can dedup
    /// the live stream against the backfilled buffer.
    event_seq: Arc<std::sync::atomic::AtomicU64>,
    /// Ring buffer of recent `sync` events (with `seq` + `at` epoch-ms). The
    /// Sync Console backfills from this on mount, so it shows the full run even
    /// when it opened mid-sync (e.g. straight after setup) — comprehensive
    /// client-side diagnostics, not just whatever arrived after it subscribed.
    event_log: Arc<parking_lot::Mutex<std::collections::VecDeque<serde_json::Value>>>,
    /// Pinged after a sync completes with new mail, so a host's local-rules worker
    /// can evaluate the just-arrived messages immediately instead of waiting for
    /// its periodic poll. This is what links a cloud-push-driven resync to auto-
    /// rules: push → resync → `notify_one` → rules run. Hosts without a rules
    /// worker (or that prefer polling) simply never await it.
    rules_scan: Arc<tokio::sync::Notify>,
    /// Host-injected on-device text generator for the background triage worker
    /// (Apple Foundation Models / Qwen on mobile, a sidecar on desktop). The
    /// same [`crate::bridge::LocalGenerator`] seam the Bridge uses; set by the
    /// host after construction. `None` → the worker uses the OpenAI lane (or the
    /// deterministic fallback) only. parking_lot (sync) so the worker snapshots
    /// it without an await.
    generator: parking_lot::RwLock<Option<Arc<dyn crate::bridge::LocalGenerator>>>,
    /// The AI generation lane the user picked in Settings (OpenAI vs on-device,
    /// plus key + model), pushed by the host. The triage worker reads a snapshot
    /// so it classifies/summarizes with the *same* model the Bridge speaks with.
    ai_config: parking_lot::RwLock<Option<crate::bridge::agent::BridgeConfig>>,
    /// Pinged after a sync brings in new mail so the triage worker drains
    /// promptly instead of waiting for its periodic poll (mirrors `rules_scan`).
    ai_scan: Arc<tokio::sync::Notify>,
    /// The user's Jev (TypeSafe) key for triage classification, pushed by the
    /// host from its secret store (`typesafe_api_key`) — never persisted by core.
    /// `unauthorized` is set on a 401 and cleared when the key changes; while
    /// set, the worker doesn't call Jev. `endpoint` is overridable for tests.
    jev: parking_lot::RwLock<JevKeyState>,
    /// The summary lane's last failure (OpenAI quota, a bad key, the on-device
    /// model); `None` once a summary succeeds. Rides on `triage-progress`.
    summary_error: parking_lot::RwLock<Option<String>>,
    /// Running message history for the Bridge's tool-using voice agent
    /// ([`crate::bridge::agent::agent_turn`]) — the OpenAI chat `messages` array
    /// carried across voice turns so the agent remembers which conversation a
    /// follow-up ("archive it") refers to. Reset when a fresh interaction begins
    /// (e.g. the host requests a daily brief). Voice is serial, so a plain
    /// (non-async) lock snapshotted per turn is sufficient.
    bridge_dialog: parking_lot::Mutex<Vec<serde_json::Value>>,
    /// The conversation the voice agent is currently focused on — the one just read
    /// or acted on — so a follow-up like "archive it" resolves "it" without an id.
    /// Used by the on-device (JSON-intent) agent path and set by both paths. Cleared
    /// alongside the dialog on a fresh interaction.
    bridge_current_conv: parking_lot::Mutex<Option<String>>,
    /// Pre-warmed daily brief: `(facts_key, spoken_text)`. A background timer composes
    /// the brief into here while the app is active so a tap speaks instantly. Keyed by
    /// the brief's facts so it's reused only while the inputs are unchanged; new mail
    /// changes the key and the next pre-warm refreshes it.
    brief_cache: parking_lot::Mutex<Option<(String, String)>>,
    /// The unlocked credential-vault DEK, in memory only (see docs/E2EE.md +
    /// `sync::vault_sync`). `None` until the vault is unlocked (device-key copy at
    /// boot, or the inbox2 password). Zeroized on drop; cleared on sign-out /
    /// identity switch. parking_lot (sync) so the backup drain snapshots it without
    /// an await.
    dek: parking_lot::RwLock<Option<zeroize::Zeroizing<[u8; 32]>>>,
    /// E2EE domain keys the signed-in member unlocked, per org — memory only,
    /// handed over by the client that holds the identity key (docs/MX-Sync.md).
    pub(crate) mx_domain_keys: parking_lot::RwLock<std::collections::HashMap<String, Vec<crate::sync::seal::DomainKey>>>,
}

/// How many recent `sync` events the engine retains for Console backfill.
const SYNC_LOG_CAPACITY: usize = 1000;

/// `app_secrets` names for the persisted Rails API context (encrypted at rest, so
/// the engine + CLI + daemon share one durable token instead of the webview's
/// plaintext localStorage). See docs/Cloud-Push.md.
const CLOUD_AUTH_TOKEN: &str = "cloud_auth_token";
const SECRET_RAILS_BASE: &str = "rails_api_base";

/// Engine event names emitted onto the [`EventSink`]. These are the wire
/// contract the frontends subscribe to (web `sync-manager.js`, iOS
/// `EngineModel`), so the strings are byte-stable. Single source per the
/// "no duplicated enums" rule.
pub(crate) mod event {
    /// Structured sync-lifecycle backbone (carries a [`super::SyncPhase`]).
    pub const SYNC: &str = "sync";
    /// A new inbound message landed (notification trigger).
    pub const NEW_MESSAGE: &str = "new-message";
    /// A calendar/event changed; the UI refetches.
    pub const CALENDAR_CHANGED: &str = "calendar-changed";
    /// Account connection status changed.
    pub const STATUS: &str = "status";
    /// An outbox entry changed state (queued/sent/failed/deleted).
    pub const OUTBOX_CHANGED: &str = "outbox-changed";
    /// Background triage worker progress (`{inWindow, done, pending,
    /// currentDate, jevStatus}`).
    pub const TRIAGE_PROGRESS: &str = "triage-progress";
    /// A conversation was (re)classified (`{conversationKey, label, priority,
    /// summaryShort}`; `label`/`priority` may be null).
    pub const TRIAGE_UPDATED: &str = "triage-updated";
    /// A conversation was routed into an org Space (`{conversationKey, slug}`).
    pub const SPACE_UPDATED: &str = "space-updated";
}

/// A phase of the structured `sync` lifecycle event. Single source for the
/// phase strings the frontend reads for the syncing indicator, progress, refresh
/// alerts, and the Sync Console log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SyncPhase {
    Started,
    FolderStarted,
    FolderProgress,
    FolderComplete,
    Completed,
    Failed,
}

impl SyncPhase {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Started => "started",
            Self::FolderStarted => "folder-started",
            Self::FolderProgress => "folder-progress",
            Self::FolderComplete => "folder-complete",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }
}

/// Emit a structured sync-lifecycle event onto the sink (and the backfill ring
/// buffer). Free function so both [`SyncEngine::sync_event`] and the
/// cancellation-safety [`SyncGuard`] — which holds only `Arc` handles, not a
/// `&SyncEngine` — emit through the identical path.
fn emit_sync_event(
    sink: &Arc<dyn crate::sync::events::EventSink>,
    event_seq: &std::sync::atomic::AtomicU64,
    event_log: &parking_lot::Mutex<std::collections::VecDeque<serde_json::Value>>,
    account_key: &str,
    phase: SyncPhase,
    extra: serde_json::Value,
) {
    let phase = phase.as_str();
    use std::sync::atomic::Ordering;
    let seq = event_seq.fetch_add(1, Ordering::Relaxed);
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    let mut payload = serde_json::Map::new();
    payload.insert("accountKey".into(), serde_json::json!(account_key));
    payload.insert("phase".into(), serde_json::json!(phase));
    payload.insert("seq".into(), serde_json::json!(seq));
    payload.insert("at".into(), serde_json::json!(at));
    if let serde_json::Value::Object(fields) = extra {
        payload.extend(fields);
    }
    let value = serde_json::Value::Object(payload);

    // Retain for Console backfill (bounded ring buffer), then emit live.
    {
        let mut log = event_log.lock();
        if log.len() == SYNC_LOG_CAPACITY {
            log.pop_front();
        }
        log.push_back(value.clone());
    }
    sink.emit(event::SYNC, value);
}

/// RAII guard for an account's sync slot. Releasing the slot — and, for a
/// user-visible run, emitting a terminal event — MUST happen even if the sync
/// future is cancelled mid-await. A dropped future skips everything after the
/// `.await`, so a plain `end_sync()` call placed there silently leaks the
/// account in the `syncing` set forever. That leak is exactly what stranded the
/// UI's "Syncing…" indicator: `get_syncing_accounts` kept reporting the zombie,
/// the boot seed latched it, and the periodic poll (which emits no `completed`)
/// could never clear it.
///
/// Drop always removes the account from `syncing`. If still `armed` (the normal
/// path calls [`SyncGuard::disarm`] after emitting its own `completed`/`failed`),
/// Drop also emits a terminal `failed` event so a watching UI clears.
struct SyncGuard {
    syncing: Arc<parking_lot::Mutex<HashMap<String, bool>>>,
    sink: Arc<dyn crate::sync::events::EventSink>,
    event_seq: Arc<std::sync::atomic::AtomicU64>,
    event_log: Arc<parking_lot::Mutex<std::collections::VecDeque<serde_json::Value>>>,
    account_key: String,
    /// When true, Drop emits a terminal `failed` event (cancellation path). The
    /// silent paths (poll, push-coalesce) construct the guard disarmed — they
    /// emit no account-level lifecycle events, so there is nothing to balance.
    armed: bool,
}

impl SyncGuard {
    /// Mark the run as terminated through its normal path; Drop will then only
    /// release the slot, not emit a duplicate terminal event.
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for SyncGuard {
    fn drop(&mut self) {
        self.syncing.lock().remove(&self.account_key);
        if self.armed {
            log::warn!(
                "[sync] {}: interrupted (future cancelled) — releasing slot, emitting failed",
                self.account_key
            );
            emit_sync_event(
                &self.sink,
                &self.event_seq,
                &self.event_log,
                &self.account_key,
                SyncPhase::Failed,
                serde_json::json!({ "error": "sync interrupted" }),
            );
        }
    }
}

impl SyncEngine {
    /// Construct an engine that delivers events through `sink`. Pass
    /// `Arc::new(NullSink)` for a headless engine that drops events.
    pub fn new(store: Arc<SyncStore>, sink: Arc<dyn crate::sync::events::EventSink>) -> Self {
        let writeback = Arc::new(WritebackQueue::new(store.clone()));
        let outbox = Arc::new(OutboxQueue::new(store.clone()));
        let (event_tx, event_rx) = mpsc::unbounded_channel();

        // Hydrate the Rails API context from the encrypted store, so the engine is
        // usable (token refresh, cloud push) on cold boot and for headless/CLI
        // clients — without waiting for the webview to call set_api_context.
        //
        // OAuth token refresh needs only the API base (the proxy's refresh endpoint
        // is public). Cloud push additionally needs the JWT and guards on it being
        // non-empty. So hydrate whenever we know the base, defaulting the JWT to
        // empty — this is the iOS path, where there's a base but no Rails sign-in.
        let api_context = store
            .get_app_secret(SECRET_RAILS_BASE)
            .ok()
            .flatten()
            .map(|api_base| ApiContext {
                api_base,
                rails_jwt: store
                    .get_app_secret(CLOUD_AUTH_TOKEN)
                    .ok()
                    .flatten()
                    .unwrap_or_default(),
            });

        Self {
            store,
            writeback,
            outbox,
            accounts: Arc::new(Mutex::new(HashMap::new())),
            event_tx,
            event_rx: Mutex::new(Some(event_rx)),
            shutdown: Arc::new(tokio::sync::Notify::new()),
            sink,
            api_context: Arc::new(RwLock::new(api_context)),
            syncing: Arc::new(parking_lot::Mutex::new(HashMap::new())),
            event_seq: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            event_log: Arc::new(parking_lot::Mutex::new(std::collections::VecDeque::with_capacity(
                SYNC_LOG_CAPACITY,
            ))),
            rules_scan: Arc::new(tokio::sync::Notify::new()),
            generator: parking_lot::RwLock::new(None),
            ai_config: parking_lot::RwLock::new(None),
            ai_scan: Arc::new(tokio::sync::Notify::new()),
            jev: parking_lot::RwLock::new(JevKeyState {
                key: None,
                unauthorized: false,
                blocked: None,
                endpoint: crate::typesafe::ENDPOINT.to_string(),
            }),
            summary_error: parking_lot::RwLock::new(None),
            bridge_dialog: parking_lot::Mutex::new(Vec::new()),
            bridge_current_conv: parking_lot::Mutex::new(None),
            brief_cache: parking_lot::Mutex::new(None),
            dek: parking_lot::RwLock::new(None),
            mx_domain_keys: parking_lot::RwLock::new(std::collections::HashMap::new()),
        }
    }

    /// The pre-warmed brief text if its facts key matches `key`, else `None`.
    pub fn brief_cache_get(&self, key: &str) -> Option<String> {
        let cache = self.brief_cache.lock();
        cache.as_ref().filter(|(k, _)| k == key).map(|(_, t)| t.clone())
    }

    /// Store a pre-warmed brief: its facts key + spoken text.
    pub fn brief_cache_set(&self, key: String, text: String) {
        *self.brief_cache.lock() = Some((key, text));
    }

    /// Snapshot the Bridge agent's running voice-dialog history (cloned out of the
    /// lock so callers don't hold it across an await).
    pub fn bridge_dialog_snapshot(&self) -> Vec<serde_json::Value> {
        self.bridge_dialog.lock().clone()
    }

    /// Replace the Bridge agent's dialog history (the agent persists the trimmed
    /// tail after each turn).
    pub fn set_bridge_dialog(&self, messages: Vec<serde_json::Value>) {
        *self.bridge_dialog.lock() = messages;
    }

    /// Clear the Bridge agent's dialog history (and the focused conversation) — call
    /// when a fresh interaction begins (a new daily brief) or the user cancels.
    pub fn reset_bridge_dialog(&self) {
        self.bridge_dialog.lock().clear();
        *self.bridge_current_conv.lock() = None;
    }

    /// The conversation the voice agent is currently focused on (for "archive it").
    pub fn bridge_current_conv(&self) -> Option<String> {
        self.bridge_current_conv.lock().clone()
    }

    /// Focus the voice agent on a conversation (the one just read or acted on).
    pub fn set_bridge_current_conv(&self, key: Option<String>) {
        *self.bridge_current_conv.lock() = key;
    }

    /// Inject the host's on-device generator for the background triage worker.
    /// Called once at startup by the host (mobile: the Apple FM / Qwen adapter;
    /// desktop: the GenerativeState adapter).
    pub fn set_generator(&self, generator: Arc<dyn crate::bridge::LocalGenerator>) {
        *self.generator.write() = Some(generator);
    }

    /// Push the user's selected AI generation lane (from Settings). The triage
    /// worker reads a snapshot of this so it honors the same model as the Bridge.
    pub fn set_ai_config(&self, config: crate::bridge::agent::BridgeConfig) {
        *self.ai_config.write() = Some(config);
    }

    /// A snapshot of the configured AI lane, or `None` if the host hasn't pushed
    /// one yet. Cloned out of the lock so callers don't hold it across an await.
    pub fn ai_config_snapshot(&self) -> Option<crate::bridge::agent::BridgeConfig> {
        self.ai_config.read().clone()
    }

    /// Push the user's Jev key (`None`/blank clears it). A new usable key
    /// re-enqueues the processed in-window threads still missing a label,
    /// priority or space, plus the never-processed backlog, and wakes the worker.
    pub fn set_jev_key(&self, key: Option<String>) {
        let key = key.map(|k| k.trim().to_string()).filter(|k| !k.is_empty());
        let fresh = {
            let mut jev = self.jev.write();
            // Re-pushing a rejected key retries it once (it may have been re-enabled).
            let fresh = key.is_some() && (jev.key != key || jev.unauthorized);
            jev.unauthorized = false;
            jev.blocked = None;
            jev.key = key;
            fresh
        };
        if fresh {
            match (self.store.requeue_for_jev(), self.store.backfill_triage_queue()) {
                (Ok(a), Ok(b)) => log::info!("[triage] Jev key set: re-enqueued {a} thread(s), backfilled {b}"),
                (Err(e), _) | (_, Err(e)) => log::warn!("[triage] Jev key set: re-enqueue failed: {e}"),
            }
            self.ai_scan.notify_one();
        }
    }

    /// The Jev key the worker may use: `None` when unset or rejected (401).
    pub fn jev_key(&self) -> Option<String> {
        let jev = self.jev.read();
        jev.key.clone().filter(|_| !jev.unauthorized)
    }

    /// Where Jev requests go (the real API unless a test redirected it).
    pub fn jev_endpoint(&self) -> String {
        self.jev.read().endpoint.clone()
    }

    /// Point Jev calls at another endpoint (tests: a mock server).
    pub fn set_jev_endpoint(&self, endpoint: String) {
        self.jev.write().endpoint = endpoint;
    }

    /// Jev returned 401 for the current key: stop calling until it changes.
    pub fn mark_jev_unauthorized(&self) {
        self.jev.write().unauthorized = true;
    }

    /// Jev said 402/403: pause the queue with this message (see [`Self::jev_paused`]).
    pub fn mark_jev_blocked(&self, message: String) {
        self.jev.write().blocked = Some((message, std::time::Instant::now()));
    }

    /// A call was answered: the account works again. Returns whether it was blocked.
    pub fn clear_jev_blocked(&self) -> bool {
        self.jev.write().blocked.take().is_some()
    }

    /// Blocked less than a probe interval ago: the worker leaves the queue alone.
    /// After that one job goes through as the probe; its answer clears the block.
    pub fn jev_paused(&self) -> bool {
        self.jev.read().blocked.as_ref().is_some_and(|(_, at)| at.elapsed() < JEV_BLOCKED_PROBE)
    }

    /// What's stopping Jev, for the progress panel: a rejected key or a blocked
    /// account. `None` when it's working (or has no key).
    pub fn jev_error(&self) -> Option<String> {
        let jev = self.jev.read();
        if jev.key.is_some() && jev.unauthorized {
            return Some("TypeSafe rejected the Jev key".into());
        }
        jev.blocked.as_ref().map(|(m, _)| m.clone())
    }

    pub fn summary_error(&self) -> Option<String> {
        self.summary_error.read().clone()
    }

    pub fn set_summary_error(&self, error: Option<String>) {
        *self.summary_error.write() = error;
    }

    /// `missing` | `ok` | `unauthorized` — rides on `triage-progress` so a
    /// settings screen can flag a rejected key.
    pub fn jev_status(&self) -> crate::typesafe::JevStatus {
        let jev = self.jev.read();
        match (&jev.key, jev.unauthorized) {
            (None, _) => crate::typesafe::JevStatus::Missing,
            (Some(_), true) => crate::typesafe::JevStatus::Unauthorized,
            (Some(_), false) => crate::typesafe::JevStatus::Ok,
        }
    }

    /// A handle to the host's on-device generator, if injected.
    pub fn generator_handle(&self) -> Option<Arc<dyn crate::bridge::LocalGenerator>> {
        self.generator.read().clone()
    }

    /// A handle the triage worker awaits to drain immediately after a sync that
    /// brought in new mail (mirrors [`rules_scan_notify`](Self::rules_scan_notify)).
    pub fn ai_scan_notify(&self) -> Arc<tokio::sync::Notify> {
        self.ai_scan.clone()
    }

    /// Emit a raw event onto the host's sink. Used by the background triage
    /// worker for `triage-progress` / `triage-updated`; the structured `sync`
    /// lifecycle uses [`sync_event`](Self::sync_event) instead.
    pub fn emit_event(&self, event: &str, payload: serde_json::Value) {
        self.sink.emit(event, payload);
    }

    /// A handle a host's local-rules worker awaits to scan immediately after a
    /// sync that brought in new mail (see the `rules_scan` field). The desktop
    /// `AgentRunner` selects on this alongside its 5s poll; a native mobile runner
    /// will do the same after a push-triggered sync.
    pub fn rules_scan_notify(&self) -> Arc<tokio::sync::Notify> {
        self.rules_scan.clone()
    }

    pub fn store(&self) -> &Arc<SyncStore> {
        &self.store
    }

    pub fn writeback(&self) -> &Arc<WritebackQueue> {
        &self.writeback
    }

    pub fn outbox(&self) -> &Arc<OutboxQueue> {
        &self.outbox
    }

    /// Store the Rails proxy context (base URL + JWT) for OAuth token refresh and
    /// cloud push. Persisted to the encrypted store so it survives restarts and is
    /// shared with the CLI/daemon. An empty token means signed-out → clear it.
    pub async fn set_api_context(&self, api_base: String, rails_jwt: String) {
        if rails_jwt.is_empty() {
            let _ = self.store.delete_app_secret(CLOUD_AUTH_TOKEN);
        } else {
            let _ = self.store.store_app_secret(CLOUD_AUTH_TOKEN, &rails_jwt);
            let _ = self.store.store_app_secret(SECRET_RAILS_BASE, &api_base);
        }
        *self.api_context.write().await = Some(ApiContext { api_base, rails_jwt });
    }

    /// Override just the Rails API base (keeping the persisted JWT), persisting it
    /// so it sticks across restarts. Mobile hosts call this on boot: their store is
    /// seeded from a desktop dump whose `rails_api_base` points at a dev URL
    /// (`localhost:4173`) that's unreachable on-device — the device must use its own
    /// reachable base (e.g. the Tailscale URL). No-op on an empty base.
    pub async fn override_api_base(&self, api_base: String) {
        if api_base.is_empty() {
            return;
        }
        let _ = self.store.store_app_secret(SECRET_RAILS_BASE, &api_base);
        let mut guard = self.api_context.write().await;
        match guard.as_mut() {
            Some(ctx) => ctx.api_base = api_base,
            None => {
                // No context yet. Set it from the base regardless of whether a JWT
                // exists — OAuth token refresh needs only the base, and iOS never
                // signs into Rails so there's no token. Cloud push stays disabled
                // until a JWT arrives (it guards on the JWT being non-empty).
                let rails_jwt = self
                    .store
                    .get_app_secret(CLOUD_AUTH_TOKEN)
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                *guard = Some(ApiContext { api_base, rails_jwt });
            }
        }
    }

    /// Store a provider's OAuth client credentials in the encrypted store so
    /// token refresh goes **directly** to the provider's token endpoint instead
    /// of through the Rails proxy (which is then only needed for first auth).
    pub fn set_oauth_client(
        &self,
        provider: &ProviderType,
        client_id: &str,
        client_secret: Option<&str>,
    ) -> Result<()> {
        let key = crate::sync::oauth::oauth_client_secret_key(provider).ok_or_else(|| {
            SyncError::Other(format!("{} has no OAuth client", provider.as_str()))
        })?;
        let config = crate::sync::oauth::OAuthClientConfig {
            client_id: client_id.to_string(),
            client_secret: client_secret.map(str::to_string),
            token_url: None,
        };
        let json = serde_json::to_string(&config).map_err(|e| SyncError::Other(e.to_string()))?;
        self.store.store_app_secret(key, &json)?;
        log::info!(
            "[oauth] {} client credentials configured — token refresh will go directly to the provider",
            provider.as_str()
        );
        Ok(())
    }

    /// Pick up OAuth client credentials from the host environment
    /// (`GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`,
    /// `MICROSOFT_CLIENT_ID`/`MICROSOFT_CLIENT_SECRET`), falling back to values
    /// baked in at compile time. Hosts call this once at startup. Values persist
    /// in the encrypted store, so a run that ever saw the env keeps refreshing
    /// locally; absent env leaves any previously-stored credentials untouched
    /// (and refresh falls back to the Rails proxy when none were ever stored).
    pub fn load_oauth_clients_from_env(&self) {
        let google_id = std::env::var("GOOGLE_CLIENT_ID")
            .ok()
            .or_else(|| option_env!("GOOGLE_CLIENT_ID").map(String::from));
        let google_secret = std::env::var("GOOGLE_CLIENT_SECRET")
            .ok()
            .or_else(|| option_env!("GOOGLE_CLIENT_SECRET").map(String::from));
        let ms_id = std::env::var("MICROSOFT_CLIENT_ID")
            .ok()
            .or_else(|| option_env!("MICROSOFT_CLIENT_ID").map(String::from));
        let ms_secret = std::env::var("MICROSOFT_CLIENT_SECRET")
            .ok()
            .or_else(|| option_env!("MICROSOFT_CLIENT_SECRET").map(String::from));
        for (provider, id, secret) in [
            (ProviderType::Gmail, google_id, google_secret),
            (ProviderType::Microsoft, ms_id, ms_secret),
        ] {
            if let Some(id) = id.filter(|s| !s.is_empty()) {
                let secret = secret.filter(|s| !s.is_empty());
                if let Err(e) = self.set_oauth_client(&provider, &id, secret.as_deref()) {
                    log::warn!(
                        "[oauth] failed to store {} client credentials: {e}",
                        provider.as_str()
                    );
                }
            }
        }
    }

    /// The persisted Rails token, if any — lets the desktop webview rehydrate its
    /// localStorage from the durable store (e.g. after a storage clear).
    pub fn persisted_rails_token(&self) -> Option<String> {
        self.store.get_app_secret(CLOUD_AUTH_TOKEN).ok().flatten()
    }

    /// Current API context, if the frontend has pushed it.
    pub fn api_context(&self) -> &Arc<RwLock<Option<ApiContext>>> {
        &self.api_context
    }

    /// Set (or clear) the in-memory credential-vault DEK. See `sync::vault_sync`.
    pub(crate) fn set_dek(&self, dek: Option<zeroize::Zeroizing<[u8; 32]>>) {
        *self.dek.write() = dek;
    }

    /// A clone of the unlocked vault DEK, if the vault is unlocked.
    pub(crate) fn dek_snapshot(&self) -> Option<zeroize::Zeroizing<[u8; 32]>> {
        self.dek.read().clone()
    }

    /// Emit a refresh event through the configured sink. Best-effort.
    pub(crate) fn emit<S: serde::Serialize>(&self, event: &str, payload: S) {
        let value = serde_json::to_value(payload).unwrap_or(serde_json::Value::Null);
        self.sink.emit(event, value);
    }

    /// Emit a structured sync-lifecycle event. This is the single backbone the
    /// frontend reads for the syncing indicator, progress, refresh alerts, and
    /// the Sync Console log. `phase` is a [`SyncPhase`]. `extra` carries
    /// phase-specific fields (folderKey/folderName, synced/total,
    /// conversationKeys, error).
    pub(crate) fn sync_event(&self, account_key: &str, phase: SyncPhase, extra: serde_json::Value) {
        emit_sync_event(
            &self.sink,
            &self.event_seq,
            &self.event_log,
            account_key,
            phase,
            extra,
        );
    }

    /// Recent `sync` events (oldest→newest) for Console backfill. Lets the UI
    /// reconstruct the full run history even if it mounted mid-sync.
    pub fn recent_sync_events(&self) -> Vec<serde_json::Value> {
        self.event_log.lock().iter().cloned().collect()
    }

    // -----------------------------------------------------------------------
    // Account management
    // -----------------------------------------------------------------------

    pub async fn add_account(
        &self,
        account_key: &str,
        provider_type: &ProviderType,
        host: &str,
        port: u16,
        use_tls: bool,
        credentials: ProviderCredentials,
    ) -> Result<()> {
        let adapter = adapters::create_adapter(
            account_key,
            provider_type,
            host,
            port,
            use_tls,
            &credentials,
            self.store.clone(),
            self.api_context.clone(),
        );
        let state = AccountState {
            adapter: Arc::new(Mutex::new(adapter)),
            credentials,
            status: AccountStatus::Disconnected,
            folders: Vec::new(),
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        };
        self.accounts
            .lock()
            .await
            .insert(account_key.to_string(), state);
        // Through update_status so the `status` event fires — on a reconnect
        // this is what clears a stale needs_reauth row in a live UI.
        self.update_status(account_key, AccountStatus::Disconnected, None)
            .await?;
        Ok(())
    }

    pub async fn remove_account(&self, account_key: &str) -> Result<()> {
        // Best-effort cloud-push / Meta-relay teardown before the account and
        // its credentials are gone.
        let _ = self.deregister_push(account_key).await;
        let _ = self.deregister_meta_push(account_key).await;
        // Delete the cloud-vault blob (if any) so a removed account isn't restored
        // on a new device. Capture provider+email before the row is gone.
        if self.store.account_backup_enabled(account_key).unwrap_or(false) {
            if let Ok(Some(acct)) = self.store.get_account(account_key) {
                let _ = self
                    .delete_account_backup(acct.provider_type.as_str(), &acct.email_address)
                    .await;
            }
        }
        let state = {
            let mut accounts = self.accounts.lock().await;
            accounts.remove(account_key)
        };
        if let Some(state) = state {
            let _ = state.adapter.lock().await.disconnect().await;
        }
        self.store.delete_account(account_key)?;
        Ok(())
    }

    /// Build an interactive provider (fetch body / send / attachments / actions)
    /// for an account, using its stored credentials + the current API context.
    pub fn interactive_provider(
        &self,
        account_key: &str,
    ) -> Result<Box<dyn crate::sync::interactive::InteractiveProvider>> {
        use crate::sync::interactive::{
            GmailInteractive, ImapConnectionInfo, ImapInteractive, MicrosoftInteractive,
        };
        use crate::sync::oauth::TokenManager;

        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        let creds = self
            .store
            .get_credentials(account_key)?
            .ok_or_else(|| SyncError::Other("no credentials for account".into()))?;

        if account.provider_type == ProviderType::Imap {
            let smtp_use_tls = account.smtp_use_tls;
            let conn = ImapConnectionInfo {
                host: account.host.clone().unwrap_or_default(),
                port: account.port.unwrap_or(993),
                use_tls: account.use_tls,
                credentials: creds,
                smtp_host: account.smtp_host.clone(),
                smtp_port: account
                    .smtp_port
                    .unwrap_or(if smtp_use_tls { 465 } else { 587 }),
                smtp_use_tls,
            };
            return Ok(Box::new(ImapInteractive::new(
                self.store.clone(),
                account_key.to_string(),
                conn,
            )));
        }

        if let Some(channel) = account.provider_type.meta_channel() {
            // Meta uses its own permanent token (no TokenManager).
            use crate::sync::interactive::MetaInteractive;
            let meta_creds = match creds {
                ProviderCredentials::Meta(m) => m,
                _ => {
                    return Err(SyncError::Other(
                        "Meta account has non-Meta credentials".into(),
                    ))
                }
            };
            return Ok(Box::new(MetaInteractive::new(
                channel,
                meta_creds,
                self.store.clone(),
                account_key.to_string(),
            )));
        }

        let token = Arc::new(TokenManager::new(
            account_key.to_string(),
            account.provider_type.clone(),
            self.store.clone(),
            self.api_context.clone(),
            &creds,
        ));
        match account.provider_type {
            ProviderType::Gmail => Ok(Box::new(GmailInteractive::new(
                token,
                self.store.clone(),
                account_key.to_string(),
            ))),
            ProviderType::Microsoft => Ok(Box::new(MicrosoftInteractive::new(
                token,
                self.store.clone(),
                account_key.to_string(),
            ))),
            ProviderType::Imap => unreachable!("IMAP handled above"),
            ProviderType::Instagram | ProviderType::Messenger | ProviderType::WhatsApp => {
                unreachable!("Meta handled above")
            }
        }
    }

    /// Boot all stored accounts: connect + initial/incremental sync. Shared by
    /// the desktop app's setup and the headless daemon.
    pub async fn boot_all_accounts(&self) {
        // Transparent same-device unlock of the credential vault via the keychain
        // copy, so token-refresh backups + restores work without a password prompt.
        if self.try_device_unlock() {
            log::info!("[engine] boot: credential vault unlocked via device key");
        }
        let accounts = match self.store.list_accounts() {
            Ok(a) => a,
            Err(e) => {
                log::error!("Boot: failed to list accounts: {e}");
                return;
            }
        };
        log::info!("[engine] boot: connecting {} stored account(s)", accounts.len());
        for account in accounts {
            if let Err(e) = self.connect_and_sync(&account.key).await {
                log::warn!("Boot: connect_and_sync failed for {}: {e}", account.key);
            }
        }
        log::info!("[engine] boot: complete");
    }

    /// One-time backfill of attachment filenames into the search index. Mail
    /// synced before filenames were indexed (or by a provider that doesn't carry
    /// them in the list payload, e.g. IMAP/Microsoft) has `attachment_names`
    /// NULL, so a filename search misses it. Walk the attachment-bearing messages
    /// that lack indexed names, fetch each from its provider, and persist the
    /// names (the FTS trigger reindexes them). Grouped by account to reuse one
    /// provider; throttled to stay well under provider rate limits; resilient
    /// (a failed fetch is left NULL and retried on a later launch). Drains to
    /// nothing once every attachment-bearing message is indexed, so it's a no-op
    /// (one cheap query) on subsequent starts. Invoked after `boot_all_accounts`
    /// so providers are connected and the boot sync has populated messages.
    pub async fn backfill_attachment_filenames(&self) {
        // Per-message pause and per-run ceiling: ~one fetch every 120ms keeps the
        // sweep gentle, and 5000 comfortably covers a typical backlog in one run.
        const PACE: Duration = Duration::from_millis(120);
        const MAX_PER_RUN: usize = 5000;

        let candidates = match self.store.messages_needing_filename_backfill(MAX_PER_RUN) {
            Ok(c) => c,
            Err(e) => {
                log::warn!("[filename-backfill] candidate query failed: {e}");
                return;
            }
        };
        if candidates.is_empty() {
            return;
        }
        log::info!(
            "[filename-backfill] indexing filenames for {} message(s)",
            candidates.len()
        );

        let mut indexed = 0usize;
        let mut current_account: Option<String> = None;
        let mut provider: Option<Box<dyn crate::sync::interactive::InteractiveProvider>> = None;

        for (account_key, message_key) in candidates {
            // Build the provider once per account (candidates are account-ordered).
            if current_account.as_deref() != Some(account_key.as_str()) {
                provider = self.interactive_provider(&account_key).ok();
                current_account = Some(account_key.clone());
            }
            let Some(p) = provider.as_ref() else { continue }; // account offline — retry next launch

            match p.fetch_message(&message_key).await {
                Ok(fetched) => {
                    let names = fetched
                        .attachments
                        .iter()
                        .map(|a| a.filename.as_str())
                        .filter(|f| !f.is_empty())
                        .collect::<Vec<_>>()
                        .join(" ");
                    let max_size = fetched.attachments.iter().map(|a| a.size as i64).max();
                    // Always record (empty = "checked, none") so an inline-only
                    // message isn't re-fetched on every launch.
                    if let Err(e) = self.store.set_attachment_names(&message_key, &names, max_size)
                    {
                        log::warn!("[filename-backfill] persist {message_key}: {e}");
                    } else {
                        indexed += 1;
                    }
                }
                Err(e) => log::debug!("[filename-backfill] fetch {message_key}: {e}"),
            }
            tokio::time::sleep(PACE).await;
        }
        log::info!("[filename-backfill] done: indexed {indexed} message(s)");
    }

    /// One-time backfill of `body_plain` for HTML-only mail synced before the
    /// store derived it (see `store::messages::plain_or_text`) — without it those
    /// messages never matched a body search. Pages by rowid in small batches
    /// with the store lock released between them and the stripping done outside
    /// it, then records a marker so later launches skip the scan entirely.
    pub async fn backfill_html_body_text(&self) {
        const MARKER: &str = "html_body_text_backfilled";
        const BATCH: usize = 200;
        if self.store.get_engine_setting(MARKER).ok().flatten().is_some() {
            return;
        }
        let mut after = 0i64;
        let mut batches = 0usize;
        loop {
            match self.store.backfill_html_body_text(after, BATCH) {
                Ok(Some(last)) => {
                    after = last;
                    batches += 1;
                    tokio::task::yield_now().await;
                }
                Ok(None) => break,
                Err(e) => {
                    log::warn!("[body-text-backfill] batch after id {after}: {e}");
                    return; // no marker: retried next launch
                }
            }
        }
        if let Err(e) = self.store.set_engine_setting(MARKER, "1") {
            log::warn!("[body-text-backfill] marker: {e}");
        }
        log::info!("[body-text-backfill] done in {batches} batch(es)");
    }

    /// One-time re-index of HTML-only MX mail whose `search_text` was stripped
    /// without decoding entities or breaking words at block tags.
    pub async fn reindex_mx_html_search_text(&self) {
        const MARKER: &str = "mx_html_search_text_v2";
        if self.store.get_engine_setting(MARKER).ok().flatten().is_some() {
            return;
        }
        let mut after = 0i64;
        loop {
            match self.store.mx_reindex_html_search_text(after, 200) {
                Ok(Some(last)) => {
                    after = last;
                    tokio::task::yield_now().await;
                }
                Ok(None) => break,
                Err(e) => {
                    log::warn!("[mx-reindex] batch after id {after}: {e}");
                    return; // no marker: retried next launch
                }
            }
        }
        if let Err(e) = self.store.set_engine_setting(MARKER, "1") {
            log::warn!("[mx-reindex] marker: {e}");
        }
    }

    pub async fn account_statuses(&self) -> HashMap<String, AccountStatus> {
        self.accounts
            .lock()
            .await
            .iter()
            .map(|(k, v)| (k.clone(), v.status.clone()))
            .collect()
    }

    /// Keys of accounts with a *user-visible* sync currently in flight. Lets
    /// the UI show a "Syncing…" indicator even when it mounts mid-sync (e.g.
    /// straight after setup, while the initial import is still running). The
    /// silent background paths (60s poll, push-coalesce) hold the slot but are
    /// excluded — reporting them made the indicator blink perpetually, reading
    /// as a stuck sync. Reads the dedicated `syncing` lock, so it is never
    /// blocked by an in-progress sync.
    pub fn syncing_accounts(&self) -> Vec<String> {
        self.syncing
            .lock()
            .iter()
            .filter(|(_, visible)| **visible)
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Live diagnostics for the Sync Console: engine adapter/polling state plus
    /// local-DB counts and the inbox cursor. Keys match what `SyncConsole` reads.
    pub async fn account_diagnostics(&self, account_key: &str) -> Result<serde_json::Value> {
        let (conversations, messages, provider_states, folders, history_id) =
            self.store.account_diagnostics(account_key)?;
        let folder_message_counts = self.store.folder_message_counts(account_key)?;
        // If a sync is in flight, the adapter is by definition running — and
        // reading `accounts` would block behind the sync's lock, so short-circuit.
        let (running, polling) = if self.syncing.lock().contains_key(account_key) {
            (true, true)
        } else {
            let accounts = self.accounts.lock().await;
            match accounts.get(account_key) {
                Some(s) => (true, matches!(s.status, AccountStatus::Connected)),
                None => (false, false),
            }
        };
        Ok(serde_json::json!({
            "running": running,
            "polling": polling,
            "historyId": history_id,
            "localConversations": conversations,
            "localMessages": messages,
            "providerStates": provider_states,
            "folderCount": folders,
            "folderMessageCounts": folder_message_counts,
        }))
    }

    /// Clone an account's adapter handle under a brief map lock. Callers hold
    /// the returned per-account lock across network I/O, never the map lock —
    /// so syncs don't block shutdown / add / status. `None` if unregistered.
    async fn adapter_handle(&self, account_key: &str) -> Option<AdapterHandle> {
        self.accounts
            .lock()
            .await
            .get(account_key)
            .map(|s| s.adapter.clone())
    }

    /// Atomically claim the sync slot for an account, returning an RAII
    /// [`SyncGuard`] that releases it on drop — including on cancellation, the
    /// case a bare claim/release pair could not survive (see `SyncGuard`).
    /// Returns `None` if a sync is already running: a losing caller MUST skip,
    /// because a second concurrent full sync re-pages every folder from the
    /// start, duplicating batches (the jumbled, non-monotonic progress logs).
    ///
    /// `user_visible` distinguishes the two kinds of run. `true` — the
    /// user-triggered/boot full sync: it appears in [`syncing_accounts`] (the
    /// UI's "Syncing…" indicator) and, having emitted `started`, a cancelled
    /// run must emit a balancing `failed` to clear the UI. `false` — the
    /// silent paths (periodic poll, push-coalesce): they hold the slot for
    /// serialization but emit no account-level events and stay out of the
    /// indicator set, so routine background polling can't read as a stuck sync.
    fn begin_sync_guard(&self, account_key: &str, user_visible: bool) -> Option<SyncGuard> {
        {
            let mut syncing = self.syncing.lock();
            if syncing.contains_key(account_key) {
                return None;
            }
            syncing.insert(account_key.to_string(), user_visible);
        }
        Some(SyncGuard {
            syncing: self.syncing.clone(),
            sink: self.sink.clone(),
            event_seq: self.event_seq.clone(),
            event_log: self.event_log.clone(),
            account_key: account_key.to_string(),
            armed: user_visible,
        })
    }

    // -----------------------------------------------------------------------
    // Sync lifecycle
    // -----------------------------------------------------------------------

    /// Ensure an account is present in the in-memory registry, loading it from
    /// the store on demand.
    ///
    /// The frontend fires `start_sync` as soon as it knows an account key,
    /// which can arrive before (or racing) the boot registration loop. Without
    /// this, `connect_and_sync` failed with "account not found" on a cold boot.
    /// Registration is idempotent — only the first writer wins.
    async fn ensure_account_registered(&self, account_key: &str) -> Result<()> {
        // Fast path: already registered.
        if self.accounts.lock().await.contains_key(account_key) {
            return Ok(());
        }

        // Load identity + credentials from the store (no registry lock held
        // during store I/O).
        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;
        let credentials = self
            .store
            .get_credentials(account_key)?
            .ok_or_else(|| SyncError::Other("no credentials for account".into()))?;
        let host = account.host.clone().unwrap_or_default();
        let port = account.port.unwrap_or(993);
        let adapter = adapters::create_adapter(
            account_key,
            &account.provider_type,
            &host,
            port,
            account.use_tls,
            &credentials,
            self.store.clone(),
            self.api_context.clone(),
        );

        // Atomic check-and-insert: another task may have registered it while we
        // loaded from the store, so only insert if still absent.
        self.accounts
            .lock()
            .await
            .entry(account_key.to_string())
            .or_insert(AccountState {
                adapter: Arc::new(Mutex::new(adapter)),
                credentials,
                status: AccountStatus::Disconnected,
                folders: Vec::new(),
                reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
                reconnect_task: None,
            });
        Ok(())
    }
}
