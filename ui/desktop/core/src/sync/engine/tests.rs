use super::sync_flow::{initial_page_size, order_inbox_first, DEFAULT_BATCH_SIZE};
use super::*;
use crate::sync::model::{ExternalAccount, ProviderCredentials};

#[tokio::test]
async fn api_context_persists_and_rehydrates_across_restart() {
    let store = Arc::new(SyncStore::new_in_memory().unwrap());
    let e1 = SyncEngine::new(store.clone(), Arc::new(crate::sync::events::NullSink));
    assert!(e1.api_context().read().await.is_none(), "fresh engine: no context");

    e1.set_api_context("https://host/api/v1".into(), "ink_tok".into())
        .await;
    assert_eq!(e1.persisted_rails_token().as_deref(), Some("ink_tok"));

    // Simulate a restart: a new engine over the same store hydrates from disk
    // without the webview re-seeding (the CLI/daemon portability guarantee).
    let e2 = SyncEngine::new(store.clone(), Arc::new(crate::sync::events::NullSink));
    let ctx = e2.api_context().read().await.clone().expect("hydrated context");
    assert_eq!(ctx.rails_jwt, "ink_tok");
    assert_eq!(ctx.api_base, "https://host/api/v1");

    // Sign-out (empty token) clears the persisted JWT but keeps the base:
    // a restarted engine hydrates a JWT-less context (the iOS shape) so
    // OAuth token refresh — which needs only the base — keeps working.
    e2.set_api_context("https://host/api/v1".into(), String::new())
        .await;
    assert!(e2.persisted_rails_token().is_none());
    let e3 = SyncEngine::new(store, Arc::new(crate::sync::events::NullSink));
    let ctx = e3.api_context().read().await.clone().expect("base survives sign-out");
    assert_eq!(ctx.api_base, "https://host/api/v1");
    assert!(ctx.rails_jwt.is_empty(), "JWT cleared after sign-out");
}

#[tokio::test]
async fn add_account_replaces_live_credentials_on_reconnect() {
    // Regression: reconnecting an account must swap its in-memory
    // adapter/TokenManager to the NEW tokens. Previously the FFI only updated
    // the store and the live state kept the OLD (revoked) refresh token, so
    // the immediate post-reconnect refresh hit Google `invalid_grant` (502).
    let engine = in_memory_engine();
    let creds = |refresh: &str| ProviderCredentials::OAuth2 {
        username: "user@gmail.com".into(),
        access_token: format!("access-for-{refresh}"),
        refresh_token: Some(refresh.into()),
    };

    engine
        .add_account("acc_1", &ProviderType::Gmail, "", 993, true, creds("old-refresh"))
        .await
        .unwrap();
    // Reconnect with a freshly-issued token.
    engine
        .add_account("acc_1", &ProviderType::Gmail, "", 993, true, creds("new-refresh"))
        .await
        .unwrap();

    let live_refresh = match &engine.accounts.lock().await.get("acc_1").unwrap().credentials {
        ProviderCredentials::OAuth2 { refresh_token, .. } => refresh_token.clone(),
        _ => panic!("expected oauth2 creds"),
    };
    assert_eq!(
        live_refresh.as_deref(),
        Some("new-refresh"),
        "reconnect must replace the live refresh token, not keep the old one"
    );
}

fn in_memory_engine() -> SyncEngine {
    let store = Arc::new(SyncStore::new_in_memory().unwrap());
    SyncEngine::new(store, Arc::new(crate::sync::events::NullSink))
}

fn seed_gmail_account(engine: &SyncEngine) -> String {
    let key = engine
        .store
        .create_account(&ExternalAccount {
            key: String::new(),
            display_name: "Test".into(),
            email_address: "t@x.com".into(),
            provider_type: ProviderType::Gmail,
            host: None,
            port: None,
            use_tls: true,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: true,
            auth_method: AuthMethod::OAuth2.as_str().into(),
            status: AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        })
        .unwrap();
    engine
        .store
        .store_credentials(
            &key,
            &ProviderCredentials::OAuth2 {
                username: "t@x.com".into(),
                access_token: "tok".into(),
                refresh_token: Some("ref".into()),
            },
        )
        .unwrap();
    key
}

// Regression: a frontend start_sync that races boot registration must not
// fail with "account not found" — connect_and_sync registers on demand.
#[tokio::test]
async fn ensure_registers_account_from_store_on_demand() {
    let engine = in_memory_engine();
    let key = seed_gmail_account(&engine);

    // Not registered yet (boot loop hasn't run).
    assert!(!engine.accounts.lock().await.contains_key(&key));

    engine.ensure_account_registered(&key).await.unwrap();
    assert!(engine.accounts.lock().await.contains_key(&key));
}

#[tokio::test]
async fn ensure_is_idempotent() {
    let engine = in_memory_engine();
    let key = seed_gmail_account(&engine);
    engine.ensure_account_registered(&key).await.unwrap();
    // Second call (e.g. boot after frontend already registered) is a no-op.
    engine.ensure_account_registered(&key).await.unwrap();
    assert_eq!(engine.accounts.lock().await.len(), 1);
}

#[tokio::test]
async fn ensure_errors_for_genuinely_unknown_account() {
    let engine = in_memory_engine();
    let err = engine.ensure_account_registered("acc_nonexistent").await;
    assert!(err.is_err(), "unknown account should still error");
}

fn folder(name: &str, role: Option<WellKnownFolder>) -> UnifiedFolder {
    UnifiedFolder {
        key: format!("fld_{name}"),
        account_key: "acc_x".into(),
        provider_name: name.into(),
        role,
        separator: None,
        flags: vec![],
        uid_validity: None,
        highest_mod_seq: 0,
        last_synced_uid: 0,
        sync_cursor: None,
        sync_enabled: true,
    }
}

/// Seed one open, read message in an inbox folder and return its
/// conversation key. Used to exercise perform_conversation_action.
fn seed_open_conversation(engine: &SyncEngine, account_key: &str) -> String {
    let folder = UnifiedFolder {
        key: format!("fld_{account_key}_inbox"),
        account_key: account_key.to_string(),
        provider_name: "INBOX".into(),
        role: Some(WellKnownFolder::Inbox),
        separator: None,
        flags: vec!["INBOX".into()],
        uid_validity: None,
        highest_mod_seq: 0,
        last_synced_uid: 0,
        sync_cursor: None,
        sync_enabled: true,
    };
    engine.store.upsert_folder(&folder).unwrap();
    let msg = UnifiedMessage {
        key: String::new(),
        message_id: "<seed@x>".into(),
        subject: Some("Hello".into()),
        from_address: "sender@example.com".into(),
        to_address: Some("me@example.com".into()),
        cc_address: None,
        in_reply_to: None,
        references_header: None,
        provider_thread_id: None,
        body_plain: Some("body".into()),
        body_html: None,
        has_attachment: false,
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: true,
        flags: UnifiedFlags { read: true, ..Default::default() },
        labels: ["INBOX".to_string()].into_iter().collect(),
        folders: std::collections::HashSet::new(),
        date: None,
        internal_date: None,
    };
    let pid = ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("g_seed".into()) };
    engine
        .store
        .upsert_synced_message(account_key, &folder.key, &msg, &pid)
        .unwrap()
        .conversation_key
}

fn conv_status(engine: &SyncEngine, conv_key: &str) -> (String, bool) {
    engine.store.conversation_status_read(conv_key)
}

// The centralization guarantee: perform_conversation_action writes the
// conversation's local status/read up front (before the write-back), so
// callers never touch the DB and a racing sync re-query can't resurrect the
// old state. The provider write-back fails here (no connected adapter) yet
// the local state is still applied — proving it lands before the network.
#[tokio::test]
async fn perform_action_persists_status_locally_before_writeback() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let conv = seed_open_conversation(&engine, &acct);
    assert_eq!(conv_status(&engine, &conv), ("open".into(), true));

    engine
        .perform_conversation_action(&acct, std::slice::from_ref(&conv), "trash")
        .await
        .unwrap();
    assert_eq!(conv_status(&engine, &conv), ("trash".into(), true), "trash not persisted locally");

    // mark_unread flips read, leaves status.
    engine
        .perform_conversation_action(&acct, std::slice::from_ref(&conv), "mark_unread")
        .await
        .unwrap();
    assert_eq!(conv_status(&engine, &conv), ("trash".into(), false));

    // The reverse verb (undo) returns the thread to the inbox locally.
    engine
        .perform_conversation_action(&acct, std::slice::from_ref(&conv), "untrash")
        .await
        .unwrap();
    assert_eq!(conv_status(&engine, &conv), ("open".into(), false));
}

// add_conversation_label enqueues an AddLabel write-back for the thread (the
// auto-label rule action's durable path).
#[tokio::test]
async fn add_conversation_label_enqueues_writeback() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let conv = seed_open_conversation(&engine, &acct);
    engine
        .add_conversation_label(&acct, std::slice::from_ref(&conv), "Invoices".into())
        .await
        .unwrap();
    // Inspect the durable queue directly: process_writeback runs offline here and
    // backs the action off, so it won't read as "due" via pending_actions.
    let conn = engine.store.connection();
    let c = conn.lock();
    let count: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM writeback_actions WHERE action_type = 'add_label'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1, "expected one AddLabel write-back enqueued");
}

/// (action_type, target_folder_key || payload) of every queued write-back.
fn queued(engine: &SyncEngine) -> Vec<(String, String)> {
    let conn = engine.store.connection();
    let c = conn.lock();
    let mut stmt = c
        .prepare("SELECT action_type, COALESCE(target_folder_key, '') || COALESCE(payload, '') FROM writeback_actions ORDER BY id")
        .unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|r| r.unwrap()).collect()
}

fn gmail_label(engine: &SyncEngine, acct: &str, name: &str, id: &str) {
    let mut f = folder(name, None);
    f.account_key = acct.into();
    f.flags = vec![id.into()];
    engine.store.upsert_folder(&f).unwrap();
}

// A user folder is a Move to its provider id (Gmail: the label id) and takes the
// thread out of the inbox; a role folder goes through its own verb instead.
#[tokio::test]
async fn move_conversations_resolves_the_folder_by_name_or_role() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let conv = seed_open_conversation(&engine, &acct);
    gmail_label(&engine, &acct, "Receipts", "Label_7");

    engine.move_conversations(&acct, std::slice::from_ref(&conv), "receipts").await.unwrap();
    assert_eq!(conv_status(&engine, &conv).0, "archived");
    let q = queued(&engine);
    assert_eq!(q[0].0, "move");
    assert!(q[0].1.contains("Label_7"), "moves to the label id, not its name: {q:?}");

    engine.move_conversations(&acct, std::slice::from_ref(&conv), "inbox").await.unwrap();
    assert_eq!(conv_status(&engine, &conv).0, "open");
    assert_eq!(queued(&engine)[1].0, "unarchive");

    assert!(engine.move_conversations(&acct, std::slice::from_ref(&conv), "Nope").await.is_err());
}

// Gmail tags are label ids looked up by name; an unknown label is an error rather
// than a write-back Gmail would reject.
#[tokio::test]
async fn tag_conversations_maps_gmail_label_names_to_ids() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let conv = seed_open_conversation(&engine, &acct);
    gmail_label(&engine, &acct, "Invoices", "Label_3");

    engine.tag_conversations(&acct, std::slice::from_ref(&conv), "invoices", true).await.unwrap();
    engine.tag_conversations(&acct, std::slice::from_ref(&conv), "Invoices", false).await.unwrap();
    let q = queued(&engine);
    assert_eq!((q[0].0.as_str(), q[1].0.as_str()), ("add_label", "remove_label"));
    assert!(q[0].1.contains("Label_3") && q[1].1.contains("Label_3"), "{q:?}");

    assert!(engine.tag_conversations(&acct, std::slice::from_ref(&conv), "Missing", true).await.is_err());
    // System folders are statuses, not tags: no trashing through the back door.
    let err = engine.tag_conversations(&acct, std::slice::from_ref(&conv), "INBOX", false).await.unwrap_err();
    assert!(err.to_string().contains("system folder"), "{err}");
}

// A draft saved twice before it could be delivered is one queued row holding
// the latest version, and it never shows in the sends list.
#[tokio::test]
async fn draft_versions_coalesce_to_the_latest_while_undelivered() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine); // no credentials: every attempt fails and waits
    let draft = |body: &str| OutgoingMessage {
        from_address: "t@x.com".into(),
        to_address: "a@b.com".into(),
        body_plain: Some(body.into()),
        ..Default::default()
    };
    let first = engine.enqueue_draft(&acct, "drf_1", draft("v1")).await.unwrap();
    let second = engine.enqueue_draft(&acct, "drf_1", draft("v2")).await.unwrap();
    assert_eq!(first.outbox_key, second.outbox_key, "the waiting version is overwritten, not duplicated");
    assert_eq!(second.status, OutboxStatus::Pending);

    let conn = engine.store.connection();
    let (rows, payload): (i64, String) = conn
        .lock()
        .query_row(
            "SELECT COUNT(*), MAX(payload) FROM outbox_messages WHERE draft_key = 'drf_1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(rows, 1);
    assert!(payload.contains("v2") && payload.contains("<drf_1@x.com>"), "{payload}");
    assert!(engine.outbox.list(&acct).unwrap().is_empty(), "drafts aren't sends");
}

// While a version is in flight the next one queues behind it (never both at
// once); a failed version that a newer one superseded is dropped, not retried
// over it; and a draft key can't be reused for another account's draft.
#[test]
fn draft_versions_never_race_or_resurrect() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let msg = |body: &str| OutgoingMessage { to_address: "a@b.com".into(), body_plain: Some(body.into()), ..Default::default() };
    let q = &engine.outbox;
    let v1 = q.enqueue_draft(&acct, "drf_2", msg("v1")).unwrap();
    assert!(q.claim(&v1.key).unwrap(), "v1 in flight");
    let v2 = q.enqueue_draft(&acct, "drf_2", msg("v2")).unwrap();
    assert_ne!(v1.key, v2.key, "an in-flight version isn't overwritten");
    assert!(!q.claim(&v2.key).unwrap(), "v2 waits for v1");
    let kept = engine.store.requeue_draft_version(&v1.key, &OutboxStatus::Pending, 1, None, "503").unwrap();
    assert!(!kept, "failed v1 is dropped, not retried over v2");
    // v3 lands on v2 (the newest pending), never on an older row.
    let v3 = q.enqueue_draft(&acct, "drf_2", msg("v3")).unwrap();
    assert_eq!(v3.key, v2.key);
    assert!(q.claim(&v2.key).unwrap());
    assert!(engine.store.get_outbox(&v2.key).unwrap().unwrap().message.body_plain.as_deref() == Some("v3"));

    engine.store.complete_draft(&v2.key, "drf_2", &acct, "r-9").unwrap();
    assert_eq!(engine.store.draft_ref("drf_2").unwrap().as_deref(), Some("r-9"));
    let err = q.enqueue_draft("acc_other", "drf_2", msg("x")).unwrap_err();
    assert!(err.to_string().contains("another account"), "{err}");
}

// Drive process_writeback against an adapter that returns `err_code`, with one
// pending Archive action carrying an enqueue-time provider id (so it reaches the
// adapter even without a live provider-state row). Returns the engine + account.
async fn drain_writeback_with_error(err_code: u16) -> (SyncEngine, String) {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    engine.accounts.lock().await.insert(
        acct.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(WritebackErrAdapter {
                capabilities: caps(),
                err_code,
            }))),
            credentials: ProviderCredentials::OAuth2 {
                username: "t".into(),
                access_token: "x".into(),
                refresh_token: Some("r".into()),
            },
            status: AccountStatus::Connected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );
    engine
        .writeback
        .enqueue(
            &acct,
            ActionType::Archive,
            "msg_x",
            None,
            Some(ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("g1".into()) }),
        )
        .unwrap();
    engine.process_writeback(&acct).await.unwrap();
    (engine, acct)
}

fn writeback_status_count(engine: &SyncEngine, status: &str) -> i64 {
    let conn = engine.store.connection();
    let c = conn.lock();
    c.query_row(
        "SELECT COUNT(*) FROM writeback_actions WHERE status = ?1",
        [status],
        |r| r.get(0),
    )
    .unwrap()
}

// A 401/403 write-back means dead credentials: the drain must flag the account
// NeedsReauth AND stop retrying (permanently fail the action), not burn the
// backoff schedule.
#[tokio::test]
async fn writeback_auth_failure_flags_reauth_and_gives_up() {
    let (engine, acct) = drain_writeback_with_error(401).await;

    assert_eq!(
        engine.store.get_account(&acct).unwrap().unwrap().status,
        AccountStatus::NeedsReauth,
        "401 write-back must flag the account NeedsReauth"
    );
    assert_eq!(writeback_status_count(&engine, "failed"), 1, "action must be permanently failed");
    assert!(engine.store.get_pending_actions(&acct).unwrap().is_empty());
}

// A permanent 4xx (e.g. bad label id) that is NOT an auth error: give up on the
// action, but do NOT flag the account for re-auth.
#[tokio::test]
async fn writeback_permanent_failure_gives_up_without_reauth() {
    let (engine, acct) = drain_writeback_with_error(400).await;

    assert_ne!(
        engine.store.get_account(&acct).unwrap().unwrap().status,
        AccountStatus::NeedsReauth,
        "a non-auth 4xx must NOT trip re-auth"
    );
    assert_eq!(writeback_status_count(&engine, "failed"), 1);
    assert!(engine.store.get_pending_actions(&acct).unwrap().is_empty());
}

// A transient 5xx must be retried: the action stays pending (back-off scheduled),
// the account is untouched.
#[tokio::test]
async fn writeback_transient_failure_retries() {
    let (engine, acct) = drain_writeback_with_error(503).await;

    assert_ne!(
        engine.store.get_account(&acct).unwrap().unwrap().status,
        AccountStatus::NeedsReauth,
        "a transient 5xx must NOT trip re-auth"
    );
    assert_eq!(writeback_status_count(&engine, "failed"), 0, "5xx must not permanently fail");
    assert_eq!(writeback_status_count(&engine, "pending"), 1, "5xx stays queued for retry");
}

// (The built-in archive/triage/auto-reply action behavior lives with the
// rule engine in `crate::rules::actions` and is covered by its own tests
// there. This engine module deliberately holds no reference to the rule
// engine so the dependency runs one way: rules → engine.)

// Initial sync ramps page size (fast first paint) then settles at the
// default for throughput.
#[test]
fn initial_page_size_ramps_then_settles() {
    assert_eq!(initial_page_size(0), 25);
    assert_eq!(initial_page_size(1), 25);
    assert_eq!(initial_page_size(2), 50);
    assert_eq!(initial_page_size(3), DEFAULT_BATCH_SIZE);
    assert_eq!(initial_page_size(50), DEFAULT_BATCH_SIZE);
}

// Inbox syncs first; the rest keep their original relative order (stable).
#[test]
fn order_inbox_first_moves_inbox_ahead_and_is_stable() {
    let mut folders = vec![
        folder("SENT", Some(WellKnownFolder::Sent)),
        folder("INBOX", Some(WellKnownFolder::Inbox)),
        folder("TRASH", Some(WellKnownFolder::Trash)),
        folder("Work", None),
    ];
    order_inbox_first(&mut folders);
    let names: Vec<&str> = folders.iter().map(|f| f.provider_name.as_str()).collect();
    assert_eq!(names, vec!["INBOX", "SENT", "TRASH", "Work"]);
}

// No inbox present → order is unchanged.
#[test]
fn order_inbox_first_no_inbox_is_noop() {
    let mut folders = vec![
        folder("SENT", Some(WellKnownFolder::Sent)),
        folder("TRASH", Some(WellKnownFolder::Trash)),
    ];
    order_inbox_first(&mut folders);
    let names: Vec<&str> = folders.iter().map(|f| f.provider_name.as_str()).collect();
    assert_eq!(names, vec!["SENT", "TRASH"]);
}

// ── Sync-lifecycle event backbone ──────────────────────────────────────

/// Captures emitted events so tests can assert the sync lifecycle.
#[derive(Default)]
struct RecordingSink {
    events: std::sync::Mutex<Vec<(String, serde_json::Value)>>,
}
impl crate::sync::events::EventSink for RecordingSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        self.events.lock().unwrap().push((event.to_string(), payload));
    }
}
impl RecordingSink {
    /// Ordered `phase` values of every emitted `sync` event.
    fn sync_phases(&self) -> Vec<String> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(e, _)| e == "sync")
            .map(|(_, p)| p["phase"].as_str().unwrap_or_default().to_string())
            .collect()
    }
}

fn caps() -> ProviderCapabilities {
    ProviderCapabilities {
        push: false,
        incremental_sync: false,
        conditional_store: false,
        server_move: false,
        labels: false,
        custom_keywords: false,
        notify: false,
        raw: vec![],
    }
}

/// Minimal adapter whose `connect` outcome is configurable; the rest is only
/// reached on the success path (not exercised here).
struct FakeAdapter {
    capabilities: ProviderCapabilities,
    connect_ok: bool,
}
#[async_trait::async_trait]
impl ProviderAdapter for FakeAdapter {
    async fn connect(&mut self, _: &ProviderCredentials) -> Result<ProviderCapabilities> {
        if self.connect_ok {
            Ok(self.capabilities.clone())
        } else {
            Err(SyncError::AuthFailed("fake connect failure".into()))
        }
    }
    async fn disconnect(&mut self) -> Result<()> { Ok(()) }
    fn capabilities(&self) -> &ProviderCapabilities { &self.capabilities }
    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> { unimplemented!() }
    async fn initial_sync(&mut self, _: &UnifiedFolder, _: u32, _: Continuation) -> Result<FolderSyncResult> { unimplemented!() }
    async fn start_watching(&mut self, _: &[UnifiedFolder], _: &ProviderCredentials, _: mpsc::UnboundedSender<ProviderEvent>) -> Result<()> { Ok(()) }
    async fn stop_watching(&mut self) -> Result<()> { Ok(()) }
    async fn incremental_sync(&mut self, _: &UnifiedFolder, _: &SyncCursor) -> Result<FolderSyncResult> { unimplemented!() }
    async fn apply_action(&mut self, _: &WritebackAction, _: &ProviderMessageId) -> Result<()> { unimplemented!() }
    fn normalize_flags(&self, _: &ProviderFlags) -> UnifiedFlags { unimplemented!() }
    fn denormalize_flags(&self, _: &UnifiedFlags, _: Option<&str>) -> ProviderFlags { unimplemented!() }
}

/// Adapter whose `apply_action` always fails with a preset HTTP status — drives
/// the write-back drain's error-classification branches.
struct WritebackErrAdapter {
    capabilities: ProviderCapabilities,
    err_code: u16,
}
#[async_trait::async_trait]
impl ProviderAdapter for WritebackErrAdapter {
    async fn connect(&mut self, _: &ProviderCredentials) -> Result<ProviderCapabilities> { Ok(self.capabilities.clone()) }
    async fn disconnect(&mut self) -> Result<()> { Ok(()) }
    fn capabilities(&self) -> &ProviderCapabilities { &self.capabilities }
    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> { unimplemented!() }
    async fn initial_sync(&mut self, _: &UnifiedFolder, _: u32, _: Continuation) -> Result<FolderSyncResult> { unimplemented!() }
    async fn start_watching(&mut self, _: &[UnifiedFolder], _: &ProviderCredentials, _: mpsc::UnboundedSender<ProviderEvent>) -> Result<()> { Ok(()) }
    async fn stop_watching(&mut self) -> Result<()> { Ok(()) }
    async fn incremental_sync(&mut self, _: &UnifiedFolder, _: &SyncCursor) -> Result<FolderSyncResult> { unimplemented!() }
    async fn apply_action(&mut self, _: &WritebackAction, _: &ProviderMessageId) -> Result<()> {
        Err(SyncError::HttpStatus { code: self.err_code, context: "fake writeback error".into() })
    }
    fn normalize_flags(&self, _: &ProviderFlags) -> UnifiedFlags { unimplemented!() }
    fn denormalize_flags(&self, _: &UnifiedFlags, _: Option<&str>) -> ProviderFlags { unimplemented!() }
}

// sync_event emits a "sync" event with the phase plus merged extra fields —
// the exact contract the frontend (syncEvents.js) consumes.
#[tokio::test]
async fn sync_event_emits_phase_with_merged_fields() {
    let sink = Arc::new(RecordingSink::default());
    let engine = SyncEngine::new(Arc::new(SyncStore::new_in_memory().unwrap()), sink.clone());
    engine.sync_event(
        "acc_1",
        SyncPhase::FolderProgress,
        serde_json::json!({ "folderKey": "fld_inbox", "synced": 25 }),
    );
    let events = sink.events.lock().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].0, event::SYNC);
    let p = &events[0].1;
    assert_eq!(p["accountKey"], "acc_1");
    assert_eq!(p["phase"], SyncPhase::FolderProgress.as_str());
    assert_eq!(p["folderKey"], "fld_inbox");
    assert_eq!(p["synced"], 25);
}

// connect_and_sync brackets the run with started → … → completed/failed.
// A connect failure must still emit started then failed (not a bare error).
#[tokio::test]
async fn connect_failure_emits_started_then_failed() {
    let sink = Arc::new(RecordingSink::default());
    let engine = SyncEngine::new(Arc::new(SyncStore::new_in_memory().unwrap()), sink.clone());
    let key = seed_gmail_account(&engine);
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(FakeAdapter { capabilities: caps(), connect_ok: false }))),
            credentials: ProviderCredentials::OAuth2 {
                username: "t".into(),
                access_token: "x".into(),
                refresh_token: None,
            },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    let result = engine.connect_and_sync(&key).await;
    assert!(result.is_err(), "connect failure should propagate");
    assert_eq!(
        sink.sync_phases(),
        vec![SyncPhase::Started.as_str(), SyncPhase::Failed.as_str()]
    );
    // And the account is no longer marked syncing.
    assert!(engine.syncing_accounts().is_empty());
}

fn seed_imap_account(engine: &SyncEngine) -> String {
    let key = engine
        .store
        .create_account(&ExternalAccount {
            key: String::new(),
            display_name: "Imap".into(),
            email_address: "i@x.com".into(),
            provider_type: ProviderType::Imap,
            host: Some("imap.x.com".into()),
            port: Some(993),
            use_tls: true,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: true,
            auth_method: AuthMethod::Password.as_str().into(),
            status: AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        })
        .unwrap();
    engine
        .store
        .store_credentials(
            &key,
            &ProviderCredentials::Password {
                username: "i@x.com".into(),
                password: "pw".into(),
            },
        )
        .unwrap();
    key
}

/// Adapter whose `connect` parks inside the await (holding the per-account
/// adapter lock) until released — lets a test pin a sync "in flight" and
/// assert that map-backed ops don't block behind it.
struct BlockingAdapter {
    capabilities: ProviderCapabilities,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
}
#[async_trait::async_trait]
impl ProviderAdapter for BlockingAdapter {
    async fn connect(&mut self, _: &ProviderCredentials) -> Result<ProviderCapabilities> {
        self.entered.notify_one();
        self.release.notified().await;
        Ok(self.capabilities.clone())
    }
    async fn disconnect(&mut self) -> Result<()> { Ok(()) }
    fn capabilities(&self) -> &ProviderCapabilities { &self.capabilities }
    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> { Ok(vec![]) }
    async fn initial_sync(&mut self, _: &UnifiedFolder, _: u32, _: Continuation) -> Result<FolderSyncResult> { unimplemented!() }
    async fn start_watching(&mut self, _: &[UnifiedFolder], _: &ProviderCredentials, _: mpsc::UnboundedSender<ProviderEvent>) -> Result<()> { Ok(()) }
    async fn stop_watching(&mut self) -> Result<()> { Ok(()) }
    async fn incremental_sync(&mut self, _: &UnifiedFolder, _: &SyncCursor) -> Result<FolderSyncResult> { unimplemented!() }
    async fn apply_action(&mut self, _: &WritebackAction, _: &ProviderMessageId) -> Result<()> { unimplemented!() }
    fn normalize_flags(&self, _: &ProviderFlags) -> UnifiedFlags { unimplemented!() }
    fn denormalize_flags(&self, _: &UnifiedFlags, _: Option<&str>) -> ProviderFlags { unimplemented!() }
}

// The whole point of the per-account adapter lock: a sync in flight (here
// parked inside connect, holding the adapter lock across the await) must NOT
// block map-backed ops — status/diagnostics queries or shutdown. Before the
// split, all of these waited on the single accounts-map lock the sync held,
// which deadlocked shutdown (destroy data) and stalled add-second-account.
#[tokio::test]
async fn in_flight_sync_does_not_block_map_ops() {
    let engine = Arc::new(in_memory_engine());
    let key = seed_imap_account(&engine);
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(BlockingAdapter {
                capabilities: caps(),
                entered: entered.clone(),
                release: release.clone(),
            }))),
            credentials: ProviderCredentials::Password {
                username: "i".into(),
                password: "pw".into(),
            },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    let e2 = engine.clone();
    let k2 = key.clone();
    let sync = tokio::spawn(async move { e2.connect_and_sync(&k2).await });

    // Block until the sync is parked inside connect (adapter lock held).
    entered.notified().await;

    // Map-backed queries must complete promptly despite the held adapter
    // lock — they only touch the accounts map / `syncing` set, not the adapter.
    tokio::time::timeout(Duration::from_secs(2), async {
        assert!(engine.syncing_accounts().contains(&key));
        let statuses = engine.account_statuses().await;
        assert!(statuses.contains_key(&key));
        engine.account_diagnostics(&key).await.unwrap();
    })
    .await
    .expect("map ops must not block behind an in-flight sync");

    // Release the sync and let it finish cleanly, then shutdown must not hang.
    release.notify_one();
    sync.await.unwrap().unwrap();
    tokio::time::timeout(Duration::from_secs(2), engine.shutdown())
        .await
        .expect("shutdown must not hang");
}

// Shutting down mid-sync (app quit during an initial import) must NOT wait
// for the in-flight batch's network I/O — the adapter lock is held across
// it, so shutdown try_locks and leaves a busy adapter to the OS. Before the
// fix this blocked on `lock().await`, hanging the UI for a whole fetch.
#[tokio::test]
async fn shutdown_does_not_block_on_in_flight_sync() {
    let engine = Arc::new(in_memory_engine());
    let key = seed_imap_account(&engine);
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(BlockingAdapter {
                capabilities: caps(),
                entered: entered.clone(),
                release: release.clone(),
            }))),
            credentials: ProviderCredentials::Password {
                username: "i".into(),
                password: "pw".into(),
            },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    let e2 = engine.clone();
    let k2 = key.clone();
    let sync = tokio::spawn(async move { e2.connect_and_sync(&k2).await });
    entered.notified().await; // sync parked inside connect, holding the adapter lock

    // Shutdown must return promptly despite the held adapter lock.
    tokio::time::timeout(Duration::from_secs(2), engine.shutdown())
        .await
        .expect("shutdown must not block on an in-flight sync");

    release.notify_one();
    let _ = sync.await;
}

// Boot, the frontend's resync, and setup's start_sync all call
// connect_and_sync for the same account. A second trigger while one is in
// flight must be a no-op — not a second concurrent full sync (which re-pages
// every folder, duplicating batches and jumbling the progress log).
#[tokio::test]
async fn concurrent_sync_triggers_are_coalesced() {
    let sink = Arc::new(RecordingSink::default());
    let engine = Arc::new(SyncEngine::new(
        Arc::new(SyncStore::new_in_memory().unwrap()),
        sink.clone(),
    ));
    let key = seed_imap_account(&engine);
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(BlockingAdapter {
                capabilities: caps(),
                entered: entered.clone(),
                release: release.clone(),
            }))),
            credentials: ProviderCredentials::Password {
                username: "i".into(),
                password: "pw".into(),
            },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    let e2 = engine.clone();
    let k2 = key.clone();
    let first = tokio::spawn(async move { e2.connect_and_sync(&k2).await });
    entered.notified().await; // first sync is now in flight (slot claimed)

    // Duplicate trigger while the first runs: returns Ok immediately, no-op.
    engine.connect_and_sync(&key).await.unwrap();

    release.notify_one();
    first.await.unwrap().unwrap();

    // Exactly one lifecycle bracket: started … completed (not two starts).
    let phases = sink.sync_phases();
    assert_eq!(
        phases.iter().filter(|p| p.as_str() == SyncPhase::Started.as_str()).count(),
        1,
        "duplicate trigger must not start a second sync: {phases:?}"
    );
    assert_eq!(phases.first().map(String::as_str), Some(SyncPhase::Started.as_str()));
    assert_eq!(phases.last().map(String::as_str), Some(SyncPhase::Completed.as_str()));
}

// Regression for the stranded "Syncing…" indicator. A sync future cancelled
// mid-await (the RPC client disconnecting on a UI reload is the real-world
// trigger) used to skip the slot release that lived after the `.await`: the
// account leaked in `syncing` forever, `get_syncing_accounts` kept reporting
// it, the UI latched, and the periodic poll (no `completed`) never cleared
// it. The RAII guard must release the slot AND emit a terminal `failed` even
// when the future is dropped.
#[tokio::test]
async fn cancelled_sync_releases_slot_and_emits_failed() {
    let sink = Arc::new(RecordingSink::default());
    let engine = Arc::new(SyncEngine::new(
        Arc::new(SyncStore::new_in_memory().unwrap()),
        sink.clone(),
    ));
    let key = seed_imap_account(&engine);
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter: Arc::new(Mutex::new(Box::new(BlockingAdapter {
                capabilities: caps(),
                entered: entered.clone(),
                release: release.clone(),
            }))),
            credentials: ProviderCredentials::Password {
                username: "i".into(),
                password: "pw".into(),
            },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    let e2 = engine.clone();
    let k2 = key.clone();
    let sync = tokio::spawn(async move { e2.connect_and_sync(&k2).await });

    // Parked inside connect, mid-await: the slot is claimed and `started`
    // emitted, but the run will never reach its own terminal event.
    entered.notified().await;
    assert!(engine.syncing_accounts().contains(&key));

    // Cancel the task — drops the future (and its guard) at the await point.
    sync.abort();
    assert!(
        sync.await.unwrap_err().is_cancelled(),
        "task should report as cancelled"
    );

    // The guard's Drop must have run despite the cancellation.
    assert!(
        engine.syncing_accounts().is_empty(),
        "cancelled sync must not leak the account in the syncing set"
    );
    assert_eq!(
        sink.sync_phases(),
        vec![SyncPhase::Started.as_str(), SyncPhase::Failed.as_str()],
        "cancellation must emit a balancing `failed` so the UI clears"
    );

    let _ = release; // never fired — the run was cancelled, not released.
}

// The guard is the single slot-release path; assert both arms directly.
// Armed (full sync) → visible in `syncing_accounts` and emits `failed` on
// drop. Disarmed (normal completion, or the silent poll/push paths) → holds
// the slot but is invisible to the indicator set and releases with no event.
// And a live guard refuses a second concurrent claim.
#[tokio::test]
async fn sync_guard_release_and_terminal_event_semantics() {
    let sink = Arc::new(RecordingSink::default());
    let engine = SyncEngine::new(Arc::new(SyncStore::new_in_memory().unwrap()), sink.clone());

    // Armed guard dropped without disarm → slot released + `failed`.
    {
        let _g = engine.begin_sync_guard("acc_armed", true).unwrap();
        assert!(engine.syncing_accounts().contains(&"acc_armed".to_string()));
    }
    assert!(engine.syncing_accounts().is_empty());
    assert_eq!(sink.sync_phases(), vec![SyncPhase::Failed.as_str()]);

    // Disarmed guard (poll/push) → holds the slot exclusively but stays out of
    // the UI-facing set (background polls must not blink the indicator), and
    // releases with no event.
    {
        let mut g = engine.begin_sync_guard("acc_silent", false).unwrap();
        g.disarm(); // already unarmed; exercises the normal-completion call
        assert!(
            !engine.syncing_accounts().contains(&"acc_silent".to_string()),
            "silent runs must not appear in the indicator set"
        );
        assert!(
            engine.begin_sync_guard("acc_silent", false).is_none(),
            "silent runs still hold the slot exclusively"
        );
    }
    assert!(
        engine.begin_sync_guard("acc_silent", false).is_some(),
        "dropping a silent guard must release the slot"
    );
    assert_eq!(sink.sync_phases(), vec![SyncPhase::Failed.as_str()], "no event from the silent path");

    // A live guard holds the slot exclusively: a second claim is refused.
    let _held = engine.begin_sync_guard("acc_dup", true).unwrap();
    assert!(engine.begin_sync_guard("acc_dup", true).is_none());
}

// ---------------------------------------------------------------------------
// Reply threading: enqueue_send hydrates In-Reply-To / References / threadId
// ---------------------------------------------------------------------------

/// Seed a parent message carrying a References chain and a provider thread id;
/// return the parent's local message key.
fn seed_reply_parent(engine: &SyncEngine, account_key: &str) -> String {
    let folder = UnifiedFolder {
        key: format!("fld_{account_key}_inbox"),
        account_key: account_key.to_string(),
        provider_name: "INBOX".into(),
        role: Some(WellKnownFolder::Inbox),
        separator: None,
        flags: vec!["INBOX".into()],
        uid_validity: None,
        highest_mod_seq: 0,
        last_synced_uid: 0,
        sync_cursor: None,
        sync_enabled: true,
    };
    engine.store.upsert_folder(&folder).unwrap();
    let msg = UnifiedMessage {
        key: String::new(),
        message_id: "<p2@x>".into(),
        subject: Some("Re: Hello".into()),
        from_address: "sender@example.com".into(),
        to_address: Some("me@example.com".into()),
        cc_address: None,
        in_reply_to: Some("<p1@x>".into()),
        references_header: Some("<p1@x>".into()),
        provider_thread_id: Some("t_123".into()),
        body_plain: Some("body".into()),
        body_html: None,
        has_attachment: false,
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: true,
        flags: UnifiedFlags { read: true, ..Default::default() },
        labels: ["INBOX".to_string()].into_iter().collect(),
        folders: std::collections::HashSet::new(),
        date: None,
        internal_date: None,
    };
    let pid = ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("g_parent".into()) };
    let conv = engine
        .store
        .upsert_synced_message(account_key, &folder.key, &msg, &pid)
        .unwrap()
        .conversation_key;
    let (parent_key, _) = engine
        .store
        .message_keys_for_conversation(account_key, &conv)
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    parent_key
}

// The fix for unthreaded replies: with only `reply_to_message_key` set by the
// composer, the engine must fill the parent's Message-ID as In-Reply-To, the
// parent's chain + Message-ID as References (RFC 5322 §3.6.4), and the
// conversation's provider thread id (Gmail threadId).
#[tokio::test]
async fn reply_hydration_threads_outgoing_replies() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let parent_key = seed_reply_parent(&engine, &acct);

    let mut msg = crate::sync::interactive::OutgoingMessage {
        from_address: "t@x.com".into(),
        to_address: "sender@example.com".into(),
        reply_to_message_key: Some(parent_key),
        ..Default::default()
    };
    engine.hydrate_reply_context(&mut msg);

    assert_eq!(msg.in_reply_to.as_deref(), Some("<p2@x>"));
    assert_eq!(msg.references.as_deref(), Some("<p1@x> <p2@x>"));
    assert_eq!(msg.provider_thread_id.as_deref(), Some("t_123"));
}

// Caller-set headers win — hydration only fills gaps.
#[tokio::test]
async fn reply_hydration_does_not_override_caller_headers() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let parent_key = seed_reply_parent(&engine, &acct);

    let mut msg = crate::sync::interactive::OutgoingMessage {
        from_address: "t@x.com".into(),
        to_address: "sender@example.com".into(),
        reply_to_message_key: Some(parent_key),
        in_reply_to: Some("<custom@x>".into()),
        references: Some("<custom@x>".into()),
        ..Default::default()
    };
    engine.hydrate_reply_context(&mut msg);

    assert_eq!(msg.in_reply_to.as_deref(), Some("<custom@x>"));
    assert_eq!(msg.references.as_deref(), Some("<custom@x>"));
}

// A vanished parent (pruned row) degrades to an unthreaded send, not an error.
#[tokio::test]
async fn reply_hydration_with_missing_parent_sends_unthreaded() {
    let engine = in_memory_engine();
    let mut msg = crate::sync::interactive::OutgoingMessage {
        from_address: "t@x.com".into(),
        to_address: "sender@example.com".into(),
        reply_to_message_key: Some("msg_gone".into()),
        ..Default::default()
    };
    engine.hydrate_reply_context(&mut msg);
    assert!(msg.in_reply_to.is_none());
    assert!(msg.references.is_none());
    assert!(msg.provider_thread_id.is_none());
}

// ---------------------------------------------------------------------------
// Local sent copy: the thread shows a send immediately, and the provider's own
// copy merges into that row instead of appearing twice.
// ---------------------------------------------------------------------------

/// Register a Sent folder for `account_key` and return its key.
fn seed_sent_folder(engine: &SyncEngine, account_key: &str) -> String {
    let folder = UnifiedFolder {
        key: format!("fld_{account_key}_sent"),
        account_key: account_key.to_string(),
        provider_name: "SENT".into(),
        role: Some(WellKnownFolder::Sent),
        separator: None,
        flags: vec!["SENT".into()],
        uid_validity: None,
        highest_mod_seq: 0,
        last_synced_uid: 0,
        sync_cursor: None,
        sync_enabled: true,
    };
    engine.store.upsert_folder(&folder).unwrap();
    folder.key
}

/// The Sent-folder copy of `sent`, as the provider reports it on the next sync.
fn synced_sent_copy(
    sent: &crate::sync::interactive::OutgoingMessage,
    message_id: &str,
) -> UnifiedMessage {
    UnifiedMessage {
        key: String::new(),
        message_id: message_id.into(),
        subject: sent.subject.clone(),
        from_address: sent.from_address.clone(),
        to_address: Some(sent.to_address.clone()),
        cc_address: None,
        in_reply_to: sent.in_reply_to.clone(),
        references_header: sent.references.clone(),
        provider_thread_id: Some("t_sent".into()),
        body_plain: sent.body_plain.clone(),
        body_html: None,
        has_attachment: false,
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: false,
        flags: UnifiedFlags { read: true, ..Default::default() },
        labels: ["SENT".to_string()].into_iter().collect(),
        folders: std::collections::HashSet::new(),
        date: None,
        internal_date: None,
    }
}

fn outgoing_mail(subject: &str) -> crate::sync::interactive::OutgoingMessage {
    crate::sync::interactive::OutgoingMessage {
        from_address: "t@x.com".into(),
        to_address: "you@example.com".into(),
        subject: Some(subject.into()),
        body_plain: Some("hello".into()),
        message_id: Some("<mine@x.com>".into()),
        ..Default::default()
    }
}

// Gmail: the send returns a message id, and Gmail rewrites our Message-ID. The
// returned id is what merges the two copies.
#[tokio::test]
async fn sent_copy_merges_with_the_synced_copy_by_provider_id() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let sent_folder = seed_sent_folder(&engine, &acct);
    let msg = outgoing_mail("Lunch?");

    // Sent → the message is in the thread right away, before any sync.
    let local = engine.record_sent_copy(&acct, &msg, "g_sent_1").expect("stored");
    assert!(local.was_new);

    // …and the Sent folder syncs it back under a Gmail-assigned Message-ID.
    let synced = synced_sent_copy(&msg, "<rewritten@mail.gmail.com>");
    let pid = ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("g_sent_1".into()) };
    let up = engine
        .store
        .upsert_synced_message(&acct, &sent_folder, &synced, &pid)
        .unwrap();

    assert!(!up.was_new, "the synced copy must not create a second message");
    assert_eq!(up.message_key, local.message_key);
    assert_eq!(up.conversation_key, local.conversation_key);
    // The recipient-visible Message-ID replaces ours, so replies thread.
    assert_eq!(
        engine.store.get_message_id_header(&up.message_key).unwrap().as_deref(),
        Some("<rewritten@mail.gmail.com>"),
    );
}

// Graph: sendMail returns no id at all and Exchange assigns its own Message-ID,
// so the merge falls back to the un-synced-placeholder heuristic.
#[tokio::test]
async fn sent_copy_merges_when_the_provider_returns_no_id() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let sent_folder = seed_sent_folder(&engine, &acct);
    let msg = outgoing_mail("Invoice");

    let local = engine.record_sent_copy(&acct, &msg, "").expect("stored");

    let synced = synced_sent_copy(&msg, "<exchange@outlook.com>");
    let pid = ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("ms_1".into()) };
    let up = engine
        .store
        .upsert_synced_message(&acct, &sent_folder, &synced, &pid)
        .unwrap();

    assert!(!up.was_new, "no id and no shared Message-ID must still merge");
    assert_eq!(up.message_key, local.message_key);
}

// The heuristic is scoped: an unrelated sent message is not swallowed by it.
#[tokio::test]
async fn sent_copy_heuristic_does_not_merge_a_different_message() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    let sent_folder = seed_sent_folder(&engine, &acct);

    let local = engine.record_sent_copy(&acct, &outgoing_mail("Invoice"), "").expect("stored");

    let other = outgoing_mail("Something else entirely");
    let synced = synced_sent_copy(&other, "<exchange@outlook.com>");
    let pid = ProviderMessageId { uid: None, mod_seq: None, provider_id: Some("ms_2".into()) };
    let up = engine
        .store
        .upsert_synced_message(&acct, &sent_folder, &synced, &pid)
        .unwrap();

    assert!(up.was_new);
    assert_ne!(up.message_key, local.message_key);
}

// A send with no Sent folder to sync back into stores nothing — the row would
// belong to no folder and nothing would ever reconcile it.
#[tokio::test]
async fn sent_copy_is_skipped_without_a_sent_folder() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    assert!(engine.record_sent_copy(&acct, &outgoing_mail("Hi"), "g_1").is_none());
}

// The Message-ID is minted once at enqueue, from the sender's domain, and is
// stable across delivery retries.
#[tokio::test]
async fn enqueue_mints_a_stable_message_id() {
    let engine = in_memory_engine();
    let acct = seed_gmail_account(&engine);
    seed_sent_folder(&engine, &acct);

    // No provider is connected, so delivery fails and the entry stays queued —
    // the payload (with its Message-ID) is what we care about here.
    let composed = crate::sync::interactive::OutgoingMessage {
        message_id: None, // the composer never sets one
        ..outgoing_mail("Hi")
    };
    let result = engine.enqueue_send(&acct, composed).await.unwrap();
    let queued = engine.outbox.list(&acct).unwrap();
    let entry = queued.iter().find(|e| e.key == result.outbox_key).expect("queued");
    let mid = entry.message.message_id.clone().expect("minted");
    assert!(mid.ends_with("@x.com>"), "domain comes from the sender: {mid}");
}

/// Adapter that, like IMAP, mints a fresh `fld_` key on every folder listing.
struct RelistingAdapter {
    capabilities: ProviderCapabilities,
}
#[async_trait::async_trait]
impl ProviderAdapter for RelistingAdapter {
    async fn connect(&mut self, _: &ProviderCredentials) -> Result<ProviderCapabilities> { Ok(self.capabilities.clone()) }
    async fn disconnect(&mut self) -> Result<()> { Ok(()) }
    fn capabilities(&self) -> &ProviderCapabilities { &self.capabilities }
    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> {
        let mut f = folder("INBOX", Some(WellKnownFolder::Inbox));
        f.key = format!("fld_{}", nanoid::nanoid!(21));
        Ok(vec![f])
    }
    async fn initial_sync(&mut self, _: &UnifiedFolder, _: u32, _: Continuation) -> Result<FolderSyncResult> { Ok(empty_sync()) }
    async fn start_watching(&mut self, _: &[UnifiedFolder], _: &ProviderCredentials, _: mpsc::UnboundedSender<ProviderEvent>) -> Result<()> { Ok(()) }
    async fn stop_watching(&mut self) -> Result<()> { Ok(()) }
    async fn incremental_sync(&mut self, _: &UnifiedFolder, _: &SyncCursor) -> Result<FolderSyncResult> { Ok(empty_sync()) }
    async fn apply_action(&mut self, _: &WritebackAction, _: &ProviderMessageId) -> Result<()> { Ok(()) }
    fn normalize_flags(&self, _: &ProviderFlags) -> UnifiedFlags { UnifiedFlags::default() }
    fn denormalize_flags(&self, _: &UnifiedFlags, _: Option<&str>) -> ProviderFlags { ProviderFlags::default() }
}

fn empty_sync() -> FolderSyncResult {
    FolderSyncResult {
        messages: vec![],
        deletions: vec![],
        flag_updates: vec![],
        new_highest_mod_seq: 0,
        uid_validity: 1,
        next_token: None,
        continuation: None,
        seen_provider_ids: None,
        has_more: false,
        total_estimate: Some(0),
    }
}

// A reconnect re-lists folders. IMAP gives each listing fresh keys, so the
// store ended up with one "Inbox" row per connect (five after five retries on
// Linux, 2026-11-07). The sync flow must reuse the stored key by provider name.
#[tokio::test]
async fn relisting_folders_on_reconnect_does_not_duplicate_them() {
    let engine = in_memory_engine();
    let key = seed_gmail_account(&engine);
    let adapter: Arc<Mutex<Box<dyn ProviderAdapter>>> =
        Arc::new(Mutex::new(Box::new(RelistingAdapter { capabilities: caps() })));
    engine.accounts.lock().await.insert(
        key.clone(),
        AccountState {
            adapter,
            credentials: ProviderCredentials::OAuth2 { username: "t".into(), access_token: "x".into(), refresh_token: None },
            status: AccountStatus::Disconnected,
            folders: vec![],
            reconnect_backoff_secs: INITIAL_RECONNECT_SECS,
            reconnect_task: None,
        },
    );

    engine.connect_and_sync(&key).await.unwrap();
    let first = engine.store.get_folders_for_account(&key).unwrap();
    assert_eq!(first.len(), 1);

    engine.connect_and_sync(&key).await.unwrap();
    let second = engine.store.get_folders_for_account(&key).unwrap();
    assert_eq!(second.len(), 1, "a re-list must update the folder row, not add one");
    assert_eq!(second[0].key, first[0].key, "the stored key survives the re-list");
}
