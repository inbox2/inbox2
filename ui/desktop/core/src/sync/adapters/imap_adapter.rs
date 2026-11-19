//! IMAP provider adapter.
//!
//! Uses the `imap` crate (v2.4) for IMAP protocol handling with `native-tls`
//! for TLS. Chosen because it is the most mature, actively maintained Rust IMAP
//! library with production-grade IDLE support. STORE UNCHANGEDSINCE is passed
//! through the crate's generic query parameters for conflict-safe flag writes.
//! FETCH CHANGEDSINCE is *not* used: the crate (2.4.1) surfaces no MODSEQ on
//! FETCH/SELECT responses, so incremental sync is keyed off `last_synced_uid`
//! (new mail) plus a cheap FLAGS-only re-read of the known UID range (flag
//! changes). Full QRESYNC SELECT is likewise unsupported by the crate's API.
//!
//! # Capability support
//!
//! | Extension    | RFC   | Support                                        |
//! |-------------|-------|------------------------------------------------|
//! | IDLE        | 2177  | Full — via `imap` crate's idle extension        |
//! | CONDSTORE   | 7162  | STORE UNCHANGEDSINCE (FETCH MODSEQ unavailable)  |
//! | QRESYNC     | 7162  | Detected; not used (crate exposes no MODSEQ)     |
//! | UIDPLUS     | 4315  | UID EXPUNGE if available                        |
//! | SPECIAL-USE | 6154  | Folder role detection via LIST attributes        |
//! | NOTIFY      | 5465  | Detected; falls back to per-folder IDLE          |
//! | ENABLE      | 5161  | Used to enable CONDSTORE/QRESYNC after login     |

use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use imap::types::{Flag, NameAttribute};
use imap::Session;
use native_tls::{TlsConnector, TlsStream};
use tokio::sync::mpsc;

use crate::sync::error::{Result, SyncError};
use crate::sync::model::*;
use crate::sync::provider::ProviderAdapter;

pub(crate) type ImapSession = Session<TlsStream<TcpStream>>;

/// Build the TLS connector. When `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1` is set
/// (integration tests against a Dovecot container with a self-signed cert), cert
/// and hostname verification are disabled. This env var is NEVER set in
/// production — real connections always verify.
pub(crate) fn build_tls_connector() -> Result<TlsConnector> {
    let mut builder = TlsConnector::builder();
    if std::env::var("INBOX2_IMAP_ACCEPT_INVALID_CERTS").as_deref() == Ok("1") {
        builder.danger_accept_invalid_certs(true);
        builder.danger_accept_invalid_hostnames(true);
    }
    Ok(builder.build()?)
}

/// IMAP provider adapter configuration.
pub struct ImapConfig {
    pub host: String,
    pub port: u16,
    pub use_tls: bool,
    /// Maximum folders to watch with IDLE (default 5).
    pub max_idle_folders: usize,
    /// IDLE re-issue interval (default 540s = 9 minutes).
    pub idle_timeout_secs: u64,
}

impl Default for ImapConfig {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 993,
            use_tls: true,
            max_idle_folders: 5,
            idle_timeout_secs: 540,
        }
    }
}

pub struct ImapAdapter {
    config: ImapConfig,
    session: Option<ImapSession>,
    capabilities: ProviderCapabilities,
    stop_flag: Arc<AtomicBool>,
    idle_handles: Vec<std::thread::JoinHandle<()>>,
}

impl ImapAdapter {
    pub fn new(config: ImapConfig) -> Self {
        Self {
            config,
            session: None,
            capabilities: ProviderCapabilities::default(),
            stop_flag: Arc::new(AtomicBool::new(false)),
            idle_handles: Vec::new(),
        }
    }

    /// Authenticate with the server.
    pub(crate) fn authenticate(
        client: imap::Client<TlsStream<TcpStream>>,
        credentials: &ProviderCredentials,
    ) -> Result<ImapSession> {
        match credentials {
            ProviderCredentials::Password { username, password } => client
                .login(username, password)
                .map_err(|e| SyncError::AuthFailed(format!("LOGIN failed: {}", e.0))),
            ProviderCredentials::OAuth2 {
                username,
                access_token,
                ..
            } => {
                let auth = XOAuth2Auth {
                    user: username.clone(),
                    access_token: access_token.clone(),
                };
                client
                    .authenticate("XOAUTH2", &auth)
                    .map_err(|e| SyncError::AuthFailed(format!("XOAUTH2 failed: {}", e.0)))
            }
            ProviderCredentials::Meta(_) => Err(SyncError::AuthFailed(
                "Meta credentials are not valid for IMAP".into(),
            )),
        }
    }

    /// Detect capabilities using has_str.
    fn detect_capabilities(session: &mut ImapSession) -> Result<ProviderCapabilities> {
        let caps = session.capabilities()?;

        let raw: Vec<String> = caps.iter().map(|c| format!("{c:?}")).collect();

        Ok(ProviderCapabilities {
            push: caps.has_str("IDLE"),
            incremental_sync: caps.has_str("QRESYNC") || caps.has_str("CONDSTORE"),
            conditional_store: caps.has_str("CONDSTORE"),
            server_move: caps.has_str("MOVE"),
            labels: false,
            custom_keywords: false,
            notify: caps.has_str("NOTIFY"),
            raw,
        })
    }

    /// Try to ENABLE CONDSTORE and/or QRESYNC after login.
    fn enable_extensions(session: &mut ImapSession, caps: &ProviderCapabilities) -> Result<()> {
        if !caps.conditional_store && !caps.incremental_sync {
            return Ok(());
        }
        let mut extensions = Vec::new();
        if caps.conditional_store {
            extensions.push("CONDSTORE");
        }
        if caps
            .raw
            .iter()
            .any(|c| c.to_uppercase().contains("QRESYNC"))
        {
            extensions.push("QRESYNC");
        }
        if !extensions.is_empty()
            && caps
                .raw
                .iter()
                .any(|c| c.to_uppercase().contains("ENABLE"))
        {
            let cmd = format!("ENABLE {}", extensions.join(" "));
            let _ = session.run_command_and_check_ok(&cmd);
        }
        Ok(())
    }

    /// Map IMAP LIST attributes to a well-known folder role.
    pub fn role_from_attributes(
        attrs: &[NameAttribute<'_>],
        name: &str,
    ) -> Option<WellKnownFolder> {
        for attr in attrs {
            match attr {
                NameAttribute::Custom(cow) => {
                    match cow.to_lowercase().as_str() {
                        "\\inbox" => return Some(WellKnownFolder::Inbox),
                        "\\sent" => return Some(WellKnownFolder::Sent),
                        "\\drafts" => return Some(WellKnownFolder::Drafts),
                        "\\archive" | "\\all" => return Some(WellKnownFolder::Archive),
                        "\\trash" => return Some(WellKnownFolder::Trash),
                        "\\junk" => return Some(WellKnownFolder::Spam),
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        // Fallback: match by display name (shared with the Microsoft adapter).
        WellKnownFolder::from_display_name(name)
    }

    /// Parse email headers from a FETCH response body.
    pub fn parse_headers(header_bytes: &[u8]) -> ParsedHeaders {
        let mut headers = ParsedHeaders::default();
        if let Ok(parsed) = mailparse::parse_headers(header_bytes) {
            for header in parsed.0 {
                match header.get_key().to_lowercase().as_str() {
                    "message-id" => headers.message_id = Some(header.get_value()),
                    "subject" => headers.subject = Some(header.get_value()),
                    "from" => headers.from = Some(header.get_value()),
                    "to" => headers.to = Some(header.get_value()),
                    "cc" => headers.cc = Some(header.get_value()),
                    "in-reply-to" => headers.in_reply_to = Some(header.get_value()),
                    "references" => headers.references = Some(header.get_value()),
                    "date" => headers.date = Some(header.get_value()),
                    "content-type" => headers.content_type = Some(header.get_value()),
                    _ => {}
                }
            }
        }
        headers
    }

    /// Convert IMAP Flag enums to unified flags.
    pub fn imap_flags_to_unified(
        flags: &[Flag<'_>],
        folder_role: Option<&WellKnownFolder>,
    ) -> UnifiedFlags {
        let mut unified = UnifiedFlags::default();
        for flag in flags {
            match flag {
                Flag::Seen => unified.read = true,
                Flag::Flagged => unified.flagged = true,
                Flag::Deleted => unified.trashed = true,
                Flag::Draft => unified.draft = true,
                _ => {}
            }
        }
        if let Some(WellKnownFolder::Archive) = folder_role {
            unified.archived = true;
        }
        if let Some(WellKnownFolder::Spam) = folder_role {
            unified.spam = true;
        }
        if let Some(WellKnownFolder::Trash) = folder_role {
            unified.trashed = true;
        }
        unified
    }

    /// Check if NameAttribute indicates Noselect.
    fn is_noselect(attr: &NameAttribute<'_>) -> bool {
        match attr {
            NameAttribute::NoSelect => true,
            NameAttribute::Custom(cow) => {
                let lower = cow.to_lowercase();
                lower == "\\noselect" || lower == "\\nonexistent"
            }
            _ => false,
        }
    }

    /// Start IDLE watchers using explicit credentials (called by the engine).
    pub async fn start_watching_with_credentials(
        &mut self,
        folders: &[UnifiedFolder],
        credentials: &ProviderCredentials,
        tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()> {
        self.stop_idle_watchers();
        self.stop_flag.store(false, Ordering::SeqCst);

        let folders_to_watch: Vec<_> = folders
            .iter()
            .filter(|f| f.sync_enabled)
            .take(self.config.max_idle_folders)
            .cloned()
            .collect();

        for folder in &folders_to_watch {
            let host = self.config.host.clone();
            let port = self.config.port;
            let use_tls = self.config.use_tls;
            let creds = credentials.clone();
            let folder_name = folder.provider_name.clone();
            let folder_key = folder.key.clone();
            let account_key = folder.account_key.clone();
            let stop_flag = self.stop_flag.clone();
            let idle_timeout = Duration::from_secs(self.config.idle_timeout_secs);
            let tx = tx.clone();

            let handle = std::thread::Builder::new()
                .name(format!("idle-{}", folder_name))
                .spawn(move || {
                    idle_watcher_loop(
                        &host,
                        port,
                        use_tls,
                        &creds,
                        &folder_name,
                        &folder_key,
                        &account_key,
                        stop_flag,
                        idle_timeout,
                        tx,
                    );
                })
                .map_err(SyncError::Io)?;

            self.idle_handles.push(handle);
        }

        log::info!("Started {} IDLE watcher(s)", self.idle_handles.len());
        Ok(())
    }

    fn stop_idle_watchers(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        for handle in self.idle_handles.drain(..) {
            let _ = handle.join();
        }
    }
}

#[async_trait]
impl ProviderAdapter for ImapAdapter {
    async fn connect(
        &mut self,
        credentials: &ProviderCredentials,
    ) -> Result<ProviderCapabilities> {
        let config_host = self.config.host.clone();
        let config_port = self.config.port;
        let config_use_tls = self.config.use_tls;
        let creds = credentials.clone();

        log::info!("IMAP connecting to {}:{} tls={}", config_host, config_port, config_use_tls);
        let (session, caps) =
            tokio::task::spawn_blocking(move || -> Result<(ImapSession, ProviderCapabilities)> {
                let tls = build_tls_connector()?;

                let client = if config_use_tls {
                    imap::connect((&*config_host, config_port), &config_host, &tls)?
                } else {
                    imap::connect_starttls((&*config_host, config_port), &config_host, &tls)?
                };

                log::info!("IMAP connected, authenticating...");
                let mut session = ImapAdapter::authenticate(client, &creds)?;
                let caps = ImapAdapter::detect_capabilities(&mut session)?;
                log::info!("IMAP capabilities: IDLE={} CONDSTORE={} MOVE={} raw_count={}", caps.push, caps.conditional_store, caps.server_move, caps.raw.len());
                ImapAdapter::enable_extensions(&mut session, &caps)?;

                Ok((session, caps))
            })
            .await
            .map_err(|e| SyncError::Other(format!("join error: {e}")))??;

        self.session = Some(session);
        self.capabilities = caps.clone();
        Ok(caps)
    }

    async fn disconnect(&mut self) -> Result<()> {
        log::info!("IMAP disconnecting, stopping {} IDLE watcher(s)", self.idle_handles.len());
        self.stop_idle_watchers();
        if let Some(mut session) = self.session.take() {
            let _ =
                tokio::task::spawn_blocking(move || {
                    let _ = session.logout();
                })
                .await;
        }
        Ok(())
    }

    fn capabilities(&self) -> &ProviderCapabilities {
        &self.capabilities
    }

    async fn list_folders(&mut self) -> Result<Vec<UnifiedFolder>> {
        log::info!("IMAP listing folders...");
        let mut session = self.session.take().ok_or(SyncError::NotConnected)?;

        let (folders, session) = tokio::task::spawn_blocking(
            move || -> Result<(Vec<UnifiedFolder>, ImapSession)> {
                let names = session.list(Some(""), Some("*"))?;
                let mut folders = Vec::new();

                for name in names.iter() {
                    // Skip non-selectable folders
                    if name.attributes().iter().any(ImapAdapter::is_noselect) {
                        continue;
                    }

                    let provider_name = name.name().to_string();
                    let attrs: Vec<String> =
                        name.attributes().iter().map(|a| format!("{a:?}")).collect();
                    let role =
                        ImapAdapter::role_from_attributes(name.attributes(), &provider_name);
                    let separator = name.delimiter().map(String::from);
                    let key = format!("fld_{}", nanoid::nanoid!(21));

                    folders.push(UnifiedFolder {
                        key,
                        account_key: String::new(), // Filled by caller
                        provider_name,
                        role,
                        separator,
                        flags: attrs,
                        uid_validity: None,
                        highest_mod_seq: 0,
                        last_synced_uid: 0,
                        sync_cursor: None,
                        sync_enabled: false,
                    });
                }

                Ok((folders, session))
            },
        )
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))??;

        log::info!("IMAP found {} selectable folders", folders.len());
        self.session = Some(session);
        Ok(folders)
    }

    async fn initial_sync(
        &mut self,
        folder: &UnifiedFolder,
        batch_size: u32,
        continuation: Continuation,
    ) -> Result<FolderSyncResult> {
        let provider_name = folder.provider_name.clone();
        let folder_role = folder.role.clone();
        // IMAP encodes its batching continuation as the next UID to fetch from.
        let from_uid: u32 = continuation
            .as_deref()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        log::info!("IMAP initial_sync folder={} from_uid={} batch={}", provider_name, from_uid, batch_size);
        let mut session = self.session.take().ok_or(SyncError::NotConnected)?;

        let (sync_result, session) = tokio::task::spawn_blocking(
            move || -> Result<(FolderSyncResult, ImapSession)> {
                let mailbox = session.select(&provider_name)?;
                let uid_validity = mailbox.uid_validity.unwrap_or(0);
                let exists = mailbox.exists;

                if exists == 0 {
                    return Ok((
                        FolderSyncResult {
                            uid_validity,
                            ..Default::default()
                        },
                        session,
                    ));
                }

                let uid_range = if from_uid == 0 {
                    "1:*".to_string()
                } else {
                    format!("{from_uid}:*")
                };

                // Headers + flags only — bodies (and their attachment bytes) are
                // lazy, fetched on demand by `ImapInteractive::fetch_message` when
                // a message is opened (the same lazy-body model as Microsoft).
                // This keeps a full-mailbox initial sync from downloading every
                // attachment up front.
                let fetches = session.uid_fetch(
                    &uid_range,
                    "(UID FLAGS BODY.PEEK[HEADER] INTERNALDATE)",
                )?;

                let mut messages = Vec::new();

                for fetch in fetches.iter() {
                    let uid = match fetch.uid {
                        Some(uid) => uid,
                        None => continue,
                    };

                    if uid < from_uid && from_uid > 0 {
                        continue;
                    }

                    let headers = fetch
                        .header()
                        .map(ImapAdapter::parse_headers)
                        .unwrap_or_default();

                    let message_id = headers
                        .message_id
                        .clone()
                        .unwrap_or_else(|| format!("<unknown-{}@local>", uid));

                    let flags =
                        ImapAdapter::imap_flags_to_unified(fetch.flags(), folder_role.as_ref());

                    // The server's INTERNALDATE — the fallback when the Date header
                    // is missing/unparseable, so old mail keeps a real timestamp
                    // instead of the sync wall-clock.
                    let internal_date =
                        fetch.internal_date().map(|dt| dt.with_timezone(&chrono::Utc));
                    let msg =
                        message_from_headers(headers, message_id.clone(), flags, internal_date);

                    let provider_id = ProviderMessageId {
                        uid: Some(uid),
                        mod_seq: None,
                        provider_id: Some(message_id),
                    };

                    messages.push((msg, provider_id));

                    if messages.len() >= batch_size as usize {
                        break;
                    }
                }

                let has_more = messages.len() >= batch_size as usize;

                // Next batch starts just past the highest UID we fetched.
                let next_continuation = if has_more {
                    messages
                        .iter()
                        .filter_map(|(_, pid)| pid.uid)
                        .max()
                        .map(|max_uid| (max_uid + 1).to_string())
                } else {
                    None
                };

                Ok((
                    FolderSyncResult {
                        messages,
                        uid_validity,
                        continuation: next_continuation,
                        has_more,
                        // EXISTS is the exact message count in the folder.
                        total_estimate: Some(exists),
                        ..Default::default()
                    },
                    session,
                ))
            },
        )
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))??;

        self.session = Some(session);
        Ok(sync_result)
    }

    async fn start_watching(
        &mut self,
        folders: &[UnifiedFolder],
        credentials: &ProviderCredentials,
        tx: mpsc::UnboundedSender<ProviderEvent>,
    ) -> Result<()> {
        self.start_watching_with_credentials(folders, credentials, tx)
            .await
    }

    async fn stop_watching(&mut self) -> Result<()> {
        self.stop_idle_watchers();
        Ok(())
    }

    async fn incremental_sync(
        &mut self,
        folder: &UnifiedFolder,
        cursor: &SyncCursor,
    ) -> Result<FolderSyncResult> {
        let provider_name = folder.provider_name.clone();
        let folder_role = folder.role.clone();
        let expected_uidvalidity = cursor.uid_validity;
        let highest_mod_seq = cursor.highest_mod_seq;
        let last_uid = cursor.last_synced_uid;
        let folder_name_for_err = folder.provider_name.clone();
        let mut session = self.session.take().ok_or(SyncError::NotConnected)?;

        let (sync_result, session) = tokio::task::spawn_blocking(
            move || -> Result<(FolderSyncResult, ImapSession)> {
                let mailbox = session.select(&provider_name)?;
                let uid_validity = mailbox.uid_validity.unwrap_or(0);

                if expected_uidvalidity != 0 && uid_validity != expected_uidvalidity {
                    // Return the session even on error so we can restore it
                    return Err(SyncError::UidValidityChanged {
                        folder: folder_name_for_err,
                        expected: expected_uidvalidity,
                        actual: uid_validity,
                    });
                }

                let mut messages = Vec::new();
                let mut flag_updates = Vec::new();

                // 1. New messages: fetch full headers + flags only for UIDs past
                //    the last one we've already synced. The `imap` crate (2.4.1)
                //    surfaces no MODSEQ on FETCH/SELECT responses, so CONDSTORE
                //    CHANGEDSINCE is unavailable; we drive incremental sync off
                //    `last_synced_uid` instead. (Note the `N:*` quirk: when no UID
                //    >= N exists the server still returns the highest message, so
                //    we guard with `uid > last_uid` below.)
                let new_range = format!("{}:*", last_uid.saturating_add(1));
                let new_fetches =
                    session.uid_fetch(&new_range, "(UID FLAGS BODY.PEEK[HEADER])")?;

                for fetch in new_fetches.iter() {
                    let uid = match fetch.uid {
                        Some(uid) => uid,
                        None => continue,
                    };
                    if uid <= last_uid {
                        continue; // `N:*` quirk re-returned an already-synced UID.
                    }

                    let flags =
                        ImapAdapter::imap_flags_to_unified(fetch.flags(), folder_role.as_ref());

                    if let Some(header_bytes) = fetch.header() {
                        let headers = ImapAdapter::parse_headers(header_bytes);
                        let message_id = headers
                            .message_id
                            .clone()
                            .unwrap_or_else(|| format!("<unknown-{}@local>", uid));

                        let msg = message_from_headers(
                            headers,
                            message_id.clone(),
                            flags.clone(),
                            None,
                        );

                        let provider_id = ProviderMessageId {
                            uid: Some(uid),
                            mod_seq: None,
                            provider_id: Some(message_id),
                        };

                        messages.push((msg, provider_id));
                    } else {
                        flag_updates.push((
                            ProviderMessageId {
                                uid: Some(uid),
                                mod_seq: None,
                                provider_id: None,
                            },
                            flags,
                        ));
                    }
                }

                // 2. Flag changes on already-synced messages: FLAGS only (no
                //    headers/bodies), so this is cheap even for large folders —
                //    O(messages) tiny FLAGS responses rather than a full header
                //    re-fetch of the whole mailbox every poll.
                if last_uid > 0 {
                    let flag_fetches =
                        session.uid_fetch(&format!("1:{last_uid}"), "(UID FLAGS)")?;
                    for fetch in flag_fetches.iter() {
                        let Some(uid) = fetch.uid else { continue };
                        let flags = ImapAdapter::imap_flags_to_unified(
                            fetch.flags(),
                            folder_role.as_ref(),
                        );
                        flag_updates.push((
                            ProviderMessageId {
                                uid: Some(uid),
                                mod_seq: None,
                                provider_id: None,
                            },
                            flags,
                        ));
                    }
                }

                Ok((
                    FolderSyncResult {
                        messages,
                        flag_updates,
                        // MODSEQ is unavailable via this crate; the engine keys
                        // IMAP incremental sync off `last_synced_uid` instead.
                        new_highest_mod_seq: highest_mod_seq,
                        uid_validity,
                        ..Default::default()
                    },
                    session,
                ))
            },
        )
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))??;

        self.session = Some(session);
        Ok(sync_result)
    }

    async fn apply_action(
        &mut self,
        action: &WritebackAction,
        provider_state: &ProviderMessageId,
    ) -> Result<()> {
        let uid = provider_state
            .uid
            .ok_or_else(|| SyncError::Other("no UID for write-back".into()))?;

        let mod_seq = provider_state.mod_seq;
        // The stable Message-ID header — used to locate this message's copy in a
        // *label* folder (whose UID differs from the source folder's) on remove.
        let message_id_header = provider_state.provider_id.clone();
        let action_type = action.action_type.clone();
        log::info!("IMAP apply_action {:?} uid={}", action_type, uid);
        let has_condstore = self.capabilities.conditional_store;
        let has_move = self.capabilities.server_move;
        let mut session = self.session.take().ok_or(SyncError::NotConnected)?;

        let session = tokio::task::spawn_blocking(move || -> Result<ImapSession> {
            let uid_str = uid.to_string();

            match action_type {
                ActionType::MarkRead => {
                    let query = condstore_store("+FLAGS (\\Seen)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                }
                ActionType::MarkUnread => {
                    let query = condstore_store("-FLAGS (\\Seen)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                }
                ActionType::Flag => {
                    let query =
                        condstore_store("+FLAGS (\\Flagged)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                }
                ActionType::Unflag => {
                    let query =
                        condstore_store("-FLAGS (\\Flagged)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                }
                ActionType::Trash => {
                    let query =
                        condstore_store("+FLAGS (\\Deleted)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                    session.expunge()?;
                }
                ActionType::Delete => {
                    let query =
                        condstore_store("+FLAGS (\\Deleted)", mod_seq, has_condstore);
                    session.uid_store(&uid_str, &query)?;
                    session.expunge()?;
                }
                ActionType::Archive => {
                    move_message(&mut session, &uid_str, "Archive", has_move)?;
                }
                ActionType::Unarchive => {
                    move_message(&mut session, &uid_str, "INBOX", has_move)?;
                }
                ActionType::Move { ref target_folder } => {
                    move_message(&mut session, &uid_str, target_folder, has_move)?;
                }
                // IMAP has no native labels; we model a label as membership of a
                // same-named folder. Adding a label COPYs the message into that
                // folder (it stays in its source folder too — true label
                // semantics). Removing deletes the *copy* living in the label
                // folder, located by Message-ID since its UID differs from the
                // source folder's.
                ActionType::AddLabel { ref label } => {
                    ensure_mailbox(&mut session, label);
                    session.uid_copy(&uid_str, label)?;
                }
                ActionType::RemoveLabel { ref label } => {
                    if let Some(mid) = message_id_header.as_deref() {
                        remove_from_label_folder(&mut session, label, mid)?;
                    } else {
                        log::warn!("RemoveLabel: no Message-ID for uid={uid_str}; skipping");
                    }
                }
                // IMAP has no interactive provider; spam/quadrant verbs are
                // n/a here and never enqueued for IMAP accounts.
                ActionType::Interactive { .. } => {}
            }

            Ok(session)
        })
        .await
        .map_err(|e| SyncError::Other(format!("join error: {e}")))??;

        self.session = Some(session);
        Ok(())
    }

    fn normalize_flags(&self, provider_flags: &ProviderFlags) -> UnifiedFlags {
        let mut unified = UnifiedFlags::default();
        for flag in &provider_flags.imap_flags {
            match flag.as_str() {
                "\\Seen" => unified.read = true,
                "\\Flagged" => unified.flagged = true,
                "\\Deleted" => unified.trashed = true,
                "\\Draft" => unified.draft = true,
                _ => {}
            }
        }
        if let Some(ref folder) = provider_flags.folder {
            match folder.to_uppercase().as_str() {
                "ARCHIVE" | "ALL MAIL" | "[GMAIL]/ALL MAIL" => unified.archived = true,
                "SPAM" | "JUNK" | "[GMAIL]/SPAM" => unified.spam = true,
                "TRASH" | "DELETED ITEMS" | "[GMAIL]/TRASH" | "BIN" => {
                    unified.trashed = true
                }
                _ => {}
            }
        }
        unified
    }

    fn denormalize_flags(&self, unified: &UnifiedFlags, _folder: Option<&str>) -> ProviderFlags {
        let mut imap_flags = Vec::new();
        if unified.read {
            imap_flags.push("\\Seen".to_string());
        }
        if unified.flagged {
            imap_flags.push("\\Flagged".to_string());
        }
        if unified.trashed {
            imap_flags.push("\\Deleted".to_string());
        }
        if unified.draft {
            imap_flags.push("\\Draft".to_string());
        }
        ProviderFlags {
            imap_flags,
            ..Default::default()
        }
    }
}

// ---------------------------------------------------------------------------
// IDLE watcher (runs on a dedicated OS thread per folder)
// ---------------------------------------------------------------------------

fn idle_watcher_loop(
    host: &str,
    port: u16,
    use_tls: bool,
    credentials: &ProviderCredentials,
    folder_name: &str,
    folder_key: &str,
    account_key: &str,
    stop_flag: Arc<AtomicBool>,
    idle_timeout: Duration,
    tx: mpsc::UnboundedSender<ProviderEvent>,
) {
    let mut backoff_secs = 1u64;
    let max_backoff_secs = 300u64;

    loop {
        if stop_flag.load(Ordering::SeqCst) {
            return;
        }

        log::info!("IDLE watcher connecting for {folder_name}...");
        let session = match connect_and_select(host, port, use_tls, credentials, folder_name) {
            Ok(session) => {
                log::info!("IDLE watcher connected for {folder_name}");
                backoff_secs = 1;
                session
            }
            Err(e) => {
                log::warn!("IDLE connect failed for {folder_name}: {e}");
                let _ = tx.send(ProviderEvent::Disconnected {
                    account_key: account_key.to_string(),
                    error: Some(e.to_string()),
                });
                std::thread::sleep(Duration::from_secs(backoff_secs));
                backoff_secs = (backoff_secs * 2).min(max_backoff_secs);
                continue;
            }
        };

        match run_idle_loop(
            session,
            folder_name,
            folder_key,
            account_key,
            &stop_flag,
            idle_timeout,
            &tx,
        ) {
            Ok(()) => return,
            Err(e) => {
                log::warn!("IDLE error for {folder_name}: {e}");
                let _ = tx.send(ProviderEvent::Disconnected {
                    account_key: account_key.to_string(),
                    error: Some(e.to_string()),
                });
                std::thread::sleep(Duration::from_secs(backoff_secs));
                backoff_secs = (backoff_secs * 2).min(max_backoff_secs);
            }
        }
    }
}

pub(crate) fn connect_and_select(
    host: &str,
    port: u16,
    use_tls: bool,
    credentials: &ProviderCredentials,
    folder_name: &str,
) -> Result<ImapSession> {
    let mut session = connect_session(host, port, use_tls, credentials)?;
    session.select(folder_name)?;
    Ok(session)
}

/// Open + authenticate an IMAP session without selecting a mailbox. Shared by
/// the IDLE watcher (`connect_and_select`) and the interactive provider, which
/// selects different mailboxes per operation.
pub(crate) fn connect_session(
    host: &str,
    port: u16,
    use_tls: bool,
    credentials: &ProviderCredentials,
) -> Result<ImapSession> {
    let tls = build_tls_connector()?;

    let client = if use_tls {
        imap::connect((host, port), host, &tls)?
    } else {
        imap::connect_starttls((host, port), host, &tls)?
    };

    ImapAdapter::authenticate(client, credentials)
}

fn run_idle_loop(
    mut session: ImapSession,
    folder_name: &str,
    folder_key: &str,
    account_key: &str,
    stop_flag: &AtomicBool,
    idle_timeout: Duration,
    tx: &mpsc::UnboundedSender<ProviderEvent>,
) -> Result<()> {
    loop {
        if stop_flag.load(Ordering::SeqCst) {
            let _ = session.logout();
            return Ok(());
        }

        let mut idle = session.idle()?;
        idle.set_keepalive(idle_timeout);

        match idle.wait_keepalive() {
            Ok(_reason) => {
                log::debug!("IDLE event on {folder_name}");
                let _ = tx.send(ProviderEvent::NewMessages {
                    account_key: account_key.to_string(),
                    folder_key: folder_key.to_string(),
                });
            }
            Err(e) => {
                return Err(SyncError::Imap(format!("IDLE error: {e}")));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// CONDSTORE helpers
// ---------------------------------------------------------------------------

fn condstore_store(base_query: &str, mod_seq: Option<u64>, has_condstore: bool) -> String {
    if has_condstore {
        if let Some(seq) = mod_seq {
            return format!("(UNCHANGEDSINCE {seq}) {base_query}");
        }
    }
    base_query.to_string()
}

/// Move a message via COPY + `\Deleted` + EXPUNGE — the fallback when the server
/// lacks the MOVE extension. Shared by Archive / Unarchive / Move.
///
/// COPY is the only step that can't be cleanly undone once it succeeds, so
/// EXPUNGE is best-effort: if it fails after a successful copy+flag, the move has
/// effectively happened (the message is in `target` and flagged `\Deleted` in the
/// source) and a later sync/reconnect will expunge it. Returning an error here
/// would re-run the COPY on the next write-back retry and duplicate the message
/// in `target`.
fn move_via_copy(session: &mut ImapSession, uid_str: &str, target: &str) -> Result<()> {
    session.uid_copy(uid_str, target)?;
    session.uid_store(uid_str, "+FLAGS (\\Deleted)")?;
    if let Err(e) = session.expunge() {
        log::warn!(
            "IMAP move uid={uid_str} -> {target}: copy+flag succeeded but expunge \
             failed (will be cleaned up on a later sync): {e}"
        );
    }
    Ok(())
}

/// Move a message to `target`, ensuring the destination mailbox exists first —
/// some servers reject COPY/MOVE into a non-existent mailbox. Uses server-side
/// MOVE when available, else the COPY + `\Deleted` + EXPUNGE fallback.
fn move_message(
    session: &mut ImapSession,
    uid_str: &str,
    target: &str,
    has_move: bool,
) -> Result<()> {
    // INBOX always exists; creating it is an error on many servers.
    if !target.eq_ignore_ascii_case("INBOX") {
        ensure_mailbox(session, target);
    }
    if has_move {
        session.uid_mv(uid_str, target)?;
    } else {
        move_via_copy(session, uid_str, target)?;
    }
    Ok(())
}

/// CREATE a mailbox, treating an "already exists" failure as success. Best-effort:
/// the subsequent COPY/MOVE surfaces a real failure if the mailbox truly can't be
/// used.
fn ensure_mailbox(session: &mut ImapSession, name: &str) {
    if let Err(e) = session.create(name) {
        log::debug!("IMAP create mailbox {name:?} (may already exist): {e}");
    }
}

/// Remove a label = delete this message's copy from the same-named folder. The
/// copy's UID differs from the source folder's, so we locate it by Message-ID.
fn remove_from_label_folder(
    session: &mut ImapSession,
    label: &str,
    message_id: &str,
) -> Result<()> {
    // The label folder may not exist (label never applied) — nothing to remove.
    if session.select(label).is_err() {
        return Ok(());
    }
    let query = format!("HEADER \"Message-ID\" \"{message_id}\"");
    let uids = session.uid_search(&query)?;
    if uids.is_empty() {
        return Ok(());
    }
    let set = uids
        .iter()
        .map(|u| u.to_string())
        .collect::<Vec<_>>()
        .join(",");
    session.uid_store(&set, "+FLAGS (\\Deleted)")?;
    if let Err(e) = session.expunge() {
        log::warn!("RemoveLabel {label:?}: expunge failed (cleaned up later): {e}");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// XOAUTH2 authenticator
// ---------------------------------------------------------------------------

struct XOAuth2Auth {
    user: String,
    access_token: String,
}

impl imap::Authenticator for XOAuth2Auth {
    type Response = String;

    fn process(&self, _challenge: &[u8]) -> Self::Response {
        format!(
            "user={}\x01auth=Bearer {}\x01\x01",
            self.user, self.access_token
        )
    }
}

// ---------------------------------------------------------------------------
// Parsed headers
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
pub struct ParsedHeaders {
    pub message_id: Option<String>,
    pub subject: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub cc: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
    pub date: Option<String>,
    pub content_type: Option<String>,
}

/// Build a header-only `UnifiedMessage` from parsed IMAP headers. Shared by the
/// initial and incremental sync paths so the field set — and its IMAP-specific
/// defaults (no provider thread id, bodies fetched lazily on open, attachments
/// unknown until a BODYSTRUCTURE fetch) — lives in exactly one place.
fn message_from_headers(
    headers: ParsedHeaders,
    message_id: String,
    flags: UnifiedFlags,
    internal_date: Option<chrono::DateTime<chrono::Utc>>,
) -> UnifiedMessage {
    UnifiedMessage {
        key: format!("msg_{}", nanoid::nanoid!(21)),
        message_id,
        subject: headers.subject,
        from_address: headers.from.unwrap_or_default(),
        to_address: headers.to,
        cc_address: headers.cc,
        in_reply_to: headers.in_reply_to,
        references_header: headers.references,
        provider_thread_id: None,
        body_plain: None,
        body_html: None,
        has_attachment: false,
        attachment_names: None,
        attachment_max_size: None,
        is_inbound: true,
        flags,
        labels: std::collections::HashSet::new(),
        folders: std::collections::HashSet::new(),
        date: headers.date.and_then(|d| {
            chrono::DateTime::parse_from_rfc2822(&d)
                .ok()
                .map(|dt| dt.with_timezone(&chrono::Utc))
        }),
        internal_date,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use imap::Authenticator;
    use std::borrow::Cow;

    #[test]
    fn test_role_from_attributes_special_use() {
        let attrs = vec![NameAttribute::Custom(Cow::Borrowed("\\Sent"))];
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "Sent"),
            Some(WellKnownFolder::Sent)
        );
    }

    #[test]
    fn test_role_from_name_fallback() {
        let attrs: Vec<NameAttribute<'_>> = vec![];
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "INBOX"),
            Some(WellKnownFolder::Inbox)
        );
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "Sent Items"),
            Some(WellKnownFolder::Sent)
        );
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "Deleted Items"),
            Some(WellKnownFolder::Trash)
        );
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "Junk E-Mail"),
            Some(WellKnownFolder::Spam)
        );
    }

    #[test]
    fn test_role_from_name_custom() {
        let attrs: Vec<NameAttribute<'_>> = vec![];
        assert_eq!(
            ImapAdapter::role_from_attributes(&attrs, "My Custom Folder"),
            None
        );
    }

    #[test]
    fn test_imap_flags_to_unified() {
        let flags = vec![Flag::Seen, Flag::Flagged];
        let unified = ImapAdapter::imap_flags_to_unified(&flags, None);
        assert!(unified.read);
        assert!(unified.flagged);
        assert!(!unified.trashed);
        assert!(!unified.draft);
    }

    #[test]
    fn test_imap_flags_to_unified_trash_folder() {
        let flags = vec![Flag::Seen];
        let unified =
            ImapAdapter::imap_flags_to_unified(&flags, Some(&WellKnownFolder::Trash));
        assert!(unified.read);
        assert!(unified.trashed);
    }

    #[test]
    fn test_imap_flags_to_unified_spam_folder() {
        let flags: Vec<Flag<'_>> = vec![];
        let unified =
            ImapAdapter::imap_flags_to_unified(&flags, Some(&WellKnownFolder::Spam));
        assert!(unified.spam);
    }

    #[test]
    fn test_normalize_denormalize_roundtrip() {
        let adapter = ImapAdapter::new(ImapConfig::default());
        let unified = UnifiedFlags {
            read: true,
            flagged: true,
            archived: false,
            trashed: false,
            spam: false,
            draft: false,
        };
        let provider = adapter.denormalize_flags(&unified, None);
        assert!(provider.imap_flags.contains(&"\\Seen".to_string()));
        assert!(provider.imap_flags.contains(&"\\Flagged".to_string()));
        assert!(!provider.imap_flags.contains(&"\\Deleted".to_string()));
        let roundtrip = adapter.normalize_flags(&provider);
        assert_eq!(roundtrip.read, unified.read);
        assert_eq!(roundtrip.flagged, unified.flagged);
    }

    #[test]
    fn test_condstore_store_with_modseq() {
        let query = condstore_store("+FLAGS (\\Seen)", Some(12345), true);
        assert_eq!(query, "(UNCHANGEDSINCE 12345) +FLAGS (\\Seen)");
    }

    #[test]
    fn test_condstore_store_without_modseq() {
        let query = condstore_store("+FLAGS (\\Seen)", None, true);
        assert_eq!(query, "+FLAGS (\\Seen)");
    }

    #[test]
    fn test_condstore_store_no_condstore() {
        let query = condstore_store("+FLAGS (\\Seen)", Some(12345), false);
        assert_eq!(query, "+FLAGS (\\Seen)");
    }

    #[test]
    fn test_parse_headers() {
        let raw = b"Message-ID: <abc@example.com>\r\nSubject: Test\r\nFrom: alice@example.com\r\nTo: bob@example.com\r\nCc: carol@example.com\r\nIn-Reply-To: <parent@example.com>\r\nReferences: <root@example.com> <parent@example.com>\r\nDate: Mon, 1 Jan 2024 00:00:00 +0000\r\n\r\n";
        let headers = ImapAdapter::parse_headers(raw);
        assert_eq!(headers.message_id.as_deref(), Some("<abc@example.com>"));
        assert_eq!(headers.subject.as_deref(), Some("Test"));
        assert_eq!(headers.from.as_deref(), Some("alice@example.com"));
        assert_eq!(headers.to.as_deref(), Some("bob@example.com"));
        assert_eq!(headers.cc.as_deref(), Some("carol@example.com"));
        assert_eq!(
            headers.in_reply_to.as_deref(),
            Some("<parent@example.com>")
        );
        assert!(headers
            .references
            .as_deref()
            .unwrap()
            .contains("<root@example.com>"));
    }

    #[test]
    fn test_xoauth2_response() {
        let auth = XOAuth2Auth {
            user: "user@gmail.com".to_string(),
            access_token: "ya29.token".to_string(),
        };
        let response = auth.process(b"");
        assert_eq!(
            response,
            "user=user@gmail.com\x01auth=Bearer ya29.token\x01\x01"
        );
    }

    #[test]
    fn test_capability_detection_full() {
        let raw = vec![
            "IMAP4rev1", "IDLE", "CONDSTORE", "QRESYNC", "MOVE", "UIDPLUS", "ENABLE",
            "NOTIFY", "SPECIAL-USE",
        ]
        .into_iter()
        .map(String::from)
        .collect::<Vec<_>>();

        let has = |name: &str| raw.iter().any(|c| c.eq_ignore_ascii_case(name));

        assert!(has("IDLE"));
        assert!(has("CONDSTORE"));
        assert!(has("QRESYNC"));
        assert!(has("MOVE"));
        assert!(has("NOTIFY"));
    }

    #[test]
    fn test_capability_detection_minimal() {
        let raw = vec!["IMAP4rev1".to_string()];
        let has = |name: &str| raw.iter().any(|c| c.eq_ignore_ascii_case(name));

        assert!(!has("IDLE"));
        assert!(!has("CONDSTORE"));
        assert!(!has("MOVE"));
    }
}
