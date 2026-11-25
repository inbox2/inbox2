use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

// ---------------------------------------------------------------------------
// Well-known folder roles
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WellKnownFolder {
    Inbox,
    Sent,
    Drafts,
    Archive,
    Trash,
    Spam,
    Other(String),
}

impl WellKnownFolder {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Inbox => "inbox",
            Self::Sent => "sent",
            Self::Drafts => "drafts",
            Self::Archive => "archive",
            Self::Trash => "trash",
            Self::Spam => "spam",
            Self::Other(s) => s.as_str(),
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "inbox" => Self::Inbox,
            "sent" => Self::Sent,
            "drafts" => Self::Drafts,
            "archive" => Self::Archive,
            "trash" => Self::Trash,
            "spam" | "junk" => Self::Spam,
            other => Self::Other(other.to_string()),
        }
    }

    /// Map a provider folder *display name* (case-insensitive) to a well-known
    /// role. The union of the spellings Graph mailboxes and common IMAP servers
    /// use — shared by the Microsoft adapter and the IMAP adapter's
    /// attribute-less fallback so the name lists can't drift apart.
    pub fn from_display_name(name: &str) -> Option<Self> {
        match name.to_lowercase().as_str() {
            "inbox" => Some(Self::Inbox),
            "sent" | "sent items" | "sent messages" => Some(Self::Sent),
            "drafts" | "draft" => Some(Self::Drafts),
            "archive" | "all mail" | "all" => Some(Self::Archive),
            "trash" | "deleted items" | "deleted messages" | "bin" => Some(Self::Trash),
            "spam" | "junk" | "junk email" | "junk e-mail" | "bulk mail" => Some(Self::Spam),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Unified folder
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnifiedFolder {
    pub key: String,
    pub account_key: String,
    pub provider_name: String,
    pub role: Option<WellKnownFolder>,
    pub separator: Option<String>,
    pub flags: Vec<String>,
    pub uid_validity: Option<u32>,
    pub highest_mod_seq: u64,
    pub last_synced_uid: u32,
    /// Opaque provider cursor (Gmail historyId, Microsoft deltaLink); None for IMAP.
    pub sync_cursor: Option<String>,
    pub sync_enabled: bool,
}

// ---------------------------------------------------------------------------
// Unified flags
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnifiedFlags {
    pub read: bool,
    pub flagged: bool,
    pub archived: bool,
    pub trashed: bool,
    pub spam: bool,
    pub draft: bool,
}

// ---------------------------------------------------------------------------
// Unified message
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnifiedMessage {
    pub key: String,
    /// RFC 5322 Message-ID header.
    pub message_id: String,
    pub subject: Option<String>,
    pub from_address: String,
    pub to_address: Option<String>,
    pub cc_address: Option<String>,
    pub in_reply_to: Option<String>,
    pub references_header: Option<String>,
    /// Provider-native thread id (Gmail `threadId`, Microsoft `conversationId`).
    /// `None` for IMAP, which has no native threading. This is the most
    /// reliable threading signal when present.
    pub provider_thread_id: Option<String>,
    pub body_plain: Option<String>,
    pub body_html: Option<String>,
    /// True when the message carries a real (non-inline) attachment. Drives the
    /// paperclip indicator in the list/grid via `conversations.has_attachment`.
    pub has_attachment: bool,
    /// Space-joined filenames of the real (non-inline) attachments, when the
    /// provider exposes them at sync time (Gmail). Folded into the FTS index so
    /// a search for a document name surfaces the mail. `None` when unknown —
    /// IMAP/Microsoft backfill it on first open (see `fetch_message`).
    pub attachment_names: Option<String>,
    /// Size in bytes of the largest real attachment, when the provider exposes
    /// it at sync time (Gmail). Backs the `larger:`/`smaller:` search filters.
    /// `None` when unknown — backfilled on first open alongside the filenames.
    pub attachment_max_size: Option<i64>,
    pub is_inbound: bool,
    pub flags: UnifiedFlags,
    pub labels: HashSet<String>,
    pub folders: HashSet<String>,
    pub date: Option<DateTime<Utc>>,
    pub internal_date: Option<DateTime<Utc>>,
}

// ---------------------------------------------------------------------------
// Provider message ID (provider-specific tracking)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderMessageId {
    /// IMAP UID (numeric). None for label/folder providers (Gmail/Microsoft).
    pub uid: Option<u32>,
    /// IMAP MODSEQ (CONDSTORE). None for others.
    pub mod_seq: Option<u64>,
    /// Stable per-provider message identifier: IMAP Message-ID header,
    /// Gmail `messages.id`, Microsoft Graph message `id`.
    pub provider_id: Option<String>,
}

/// Opaque continuation token for paginating a batched `initial_sync`.
/// IMAP encodes the next UID; Gmail uses a `pageToken`; Microsoft a `nextLink`.
/// `None` means "start from the beginning" / "no more pages".
pub type Continuation = Option<String>;

// ---------------------------------------------------------------------------
// Folder sync result
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FolderSyncResult {
    pub messages: Vec<(UnifiedMessage, ProviderMessageId)>,
    /// Messages deleted on the provider, identified the same way as `messages`
    /// (by UID for IMAP, by `provider_id` for Gmail/Microsoft).
    pub deletions: Vec<ProviderMessageId>,
    /// Flag-only updates (no body fetched).
    pub flag_updates: Vec<(ProviderMessageId, UnifiedFlags)>,
    /// IMAP highest MODSEQ after this sync (0 for non-CONDSTORE providers).
    pub new_highest_mod_seq: u64,
    /// IMAP UIDVALIDITY (0 for label/folder providers).
    pub uid_validity: u32,
    /// Opaque provider cursor to persist for the next incremental sync
    /// (Gmail historyId, Microsoft deltaLink). `None` leaves the stored cursor
    /// unchanged — engines persist this only when a sync fully completes.
    pub next_token: Option<String>,
    /// Continuation for the next `initial_sync` batch; `None` = folder drained.
    pub continuation: Continuation,
    /// Complete set of provider ids seen during a full sync, used to prune
    /// locally-known messages that have disappeared remotely. `None` when the
    /// provider detects deletions incrementally instead (IMAP).
    pub seen_provider_ids: Option<HashSet<String>>,
    pub has_more: bool,
    /// Provider's estimate of the folder's total message count, for a
    /// deterministic progress bar. Exact for IMAP (`EXISTS`), an estimate for
    /// Gmail (`resultSizeEstimate`), `None` for Microsoft (delta gives no total).
    /// Meaningful on the first batch of an initial sync.
    pub total_estimate: Option<u32>,
}

// ---------------------------------------------------------------------------
// Sync cursor (per folder)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncCursor {
    pub uid_validity: u32,
    pub highest_mod_seq: u64,
    pub last_synced_uid: u32,
    /// Opaque provider cursor (Gmail historyId, Microsoft deltaLink). `None`
    /// for IMAP, which uses uid_validity/highest_mod_seq/last_synced_uid.
    pub token: Option<String>,
}

// ---------------------------------------------------------------------------
// Provider events (push notifications)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProviderEvent {
    NewMessages {
        account_key: String,
        folder_key: String,
    },
    FlagsChanged {
        account_key: String,
        folder_key: String,
    },
    MessagesExpunged {
        account_key: String,
        folder_key: String,
        uids: Vec<u32>,
    },
    Disconnected {
        account_key: String,
        error: Option<String>,
    },
    Reconnected {
        account_key: String,
    },
}

// ---------------------------------------------------------------------------
// Write-back actions
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionType {
    MarkRead,
    MarkUnread,
    Flag,
    Unflag,
    Archive,
    Unarchive,
    Trash,
    Delete,
    Move { target_folder: String },
    AddLabel { label: String },
    RemoveLabel { label: String },
    /// Escape hatch for actions the structured variants don't model
    /// (spam/unspam/untrash, set_quadrant:KEY, clear_quadrant). The write-back
    /// loop applies these by calling the provider's `perform_action(verb)` path,
    /// reusing its label/category logic — so they get the same durable retry as
    /// the structured actions instead of a fire-and-forget direct call.
    Interactive { verb: String },
}

impl ActionType {
    pub fn as_str(&self) -> &str {
        match self {
            Self::MarkRead => "mark_read",
            Self::MarkUnread => "mark_unread",
            Self::Flag => "flag",
            Self::Unflag => "unflag",
            Self::Archive => "archive",
            Self::Unarchive => "unarchive",
            Self::Trash => "trash",
            Self::Delete => "delete",
            Self::Move { .. } => "move",
            Self::AddLabel { .. } => "add_label",
            Self::RemoveLabel { .. } => "remove_label",
            Self::Interactive { .. } => "interactive",
        }
    }

    /// Whether a banner for this message's thread is stale once the action
    /// lands: it was read or it left the inbox. Drives the cross-device clear
    /// (docs/Cloud-Push.md "Clearing channel banners").
    pub fn clears_banner(&self) -> bool {
        match self {
            Self::MarkRead | Self::Archive | Self::Trash | Self::Delete | Self::Move { .. } => true,
            Self::Interactive { verb } => matches!(verb.as_str(), "spam" | "trash" | "archive" | "delete"),
            _ => false,
        }
    }

    /// Parse a write-back action name + its optional fields. The inverse of
    /// [`as_str`]; single source for both the Tauri command and the bus RPC.
    pub fn from_request(
        name: &str,
        target_folder: Option<String>,
        label: Option<String>,
    ) -> Result<Self, String> {
        Ok(match name {
            "mark_read" => Self::MarkRead,
            "mark_unread" => Self::MarkUnread,
            "flag" => Self::Flag,
            "unflag" => Self::Unflag,
            "archive" => Self::Archive,
            "unarchive" => Self::Unarchive,
            "trash" => Self::Trash,
            "delete" => Self::Delete,
            "move" => Self::Move {
                target_folder: target_folder.ok_or("move requires target_folder")?,
            },
            "add_label" => Self::AddLabel {
                label: label.ok_or("add_label requires label")?,
            },
            "remove_label" => Self::RemoveLabel {
                label: label.ok_or("remove_label requires label")?,
            },
            other => return Err(format!("unknown action: {other}")),
        })
    }

    /// Whether incoming provider flags already reflect this action's intent —
    /// i.e. the provider has caught up with the optimistic local mutation, so a
    /// sync that mirrors these flags onto the conversation would *agree* with
    /// the local state rather than resurrect the pre-mutation one. The
    /// sync-vs-writeback guard uses this to decide when a *completed* action can
    /// stop protecting a message: the local intent wins until the provider's
    /// flags settle to it, after which the mirror is a no-op anyway.
    ///
    /// Only the actions that drive the status/read mirror (`from_flags` +
    /// `read`) are meaningful here. Flag/move/label/quadrant verbs never feed
    /// that mirror, so they're always "settled" — they can't cause resurrection.
    pub fn settled_by_flags(&self, flags: &UnifiedFlags) -> bool {
        match self {
            Self::Archive => flags.archived,
            Self::Unarchive => !flags.archived && !flags.trashed && !flags.spam,
            Self::Trash | Self::Delete => flags.trashed,
            Self::MarkRead => flags.read,
            Self::MarkUnread => !flags.read,
            Self::Interactive { verb } => match verb.as_str() {
                "spam" | "junk" => flags.spam,
                "unspam" => !flags.spam,
                "untrash" => !flags.trashed,
                "open" | "unarchive" => !flags.archived && !flags.trashed && !flags.spam,
                "mark_read" => flags.read,
                "mark_unread" => !flags.read,
                // set_quadrant/clear_quadrant/label verbs don't drive the mirror.
                _ => true,
            },
            // Flag/Unflag/Move/AddLabel/RemoveLabel never feed the status/read mirror.
            _ => true,
        }
    }

}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
}

impl ActionStatus {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    /// Parse a stored status string — the inverse of [`as_str`]. An unknown
    /// value is a bug (we wrote every row); it's logged and coerced to
    /// `Pending` so the read itself doesn't crash.
    pub fn from_str(s: &str) -> Self {
        match s {
            "pending" => Self::Pending,
            "in_progress" => Self::InProgress,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            other => {
                log::error!("unknown writeback action status {other:?}; treating as pending");
                Self::Pending
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WritebackAction {
    pub key: String,
    pub account_key: String,
    pub action_type: ActionType,
    pub message_key: String,
    pub folder_key: Option<String>,
    /// The message's provider identity captured AT ENQUEUE TIME. Makes the action
    /// self-contained: if the message's `message_provider_state` row is later pruned
    /// by a racing sync, the write-back can still target the server message instead of
    /// silently losing it. `None` only for rows written before this column existed.
    pub provider_snapshot: Option<ProviderMessageId>,
    pub status: ActionStatus,
    pub retry_count: u32,
    pub max_retries: u32,
    pub next_retry_at: Option<DateTime<Utc>>,
    pub error_message: Option<String>,
}

// ---------------------------------------------------------------------------
// Outbox (durable provider sends)
// ---------------------------------------------------------------------------

/// What a queued outbox row does when delivered: send it, or save it as the
/// latest version of a draft (docs/Vector-MCP.md "Queued sends and drafts").
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutboxKind {
    #[default]
    Send,
    Draft,
}

impl OutboxKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Send => "send",
            Self::Draft => "draft",
        }
    }

    pub fn from_str(s: &str) -> Self {
        if s == "draft" { Self::Draft } else { Self::Send }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutboxStatus {
    /// Awaiting (re)delivery — `next_retry_at` gates when it's eligible.
    Pending,
    /// A delivery attempt is in flight.
    Sending,
    /// Accepted by the provider; `provider_message_id` is set.
    Sent,
    /// Exhausted `max_retries`; needs a manual retry to leave this state.
    Failed,
    /// The queued send was cancelled and its row removed. Never persisted to the
    /// status column (the row is deleted); only emitted on the `outbox-changed`
    /// event so a listening UI can drop the entry.
    Deleted,
}

impl OutboxStatus {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Pending => "pending",
            Self::Sending => "sending",
            Self::Sent => "sent",
            Self::Failed => "failed",
            Self::Deleted => "deleted",
        }
    }

    /// Parse a stored status string — the inverse of [`as_str`]. An unknown
    /// value is a bug (we wrote every row); it's logged and coerced to
    /// `Pending` so the read itself doesn't crash.
    pub fn from_str(s: &str) -> Self {
        match s {
            "pending" => Self::Pending,
            "sending" => Self::Sending,
            "sent" => Self::Sent,
            "failed" => Self::Failed,
            "deleted" => Self::Deleted,
            other => {
                log::error!("unknown outbox status {other:?}; treating as pending");
                Self::Pending
            }
        }
    }
}

/// Lifecycle status of an `embedding_queue` row. The `embedding_queue` table is
/// shared across crates — `inbox2-core` enqueues new messages (`Pending`) and the
/// desktop vector pipeline processes them (`Completed`/`Failed`) — so these wire
/// values live here as the single source of truth for both. Never hardcode them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EmbeddingStatus {
    Pending,
    Completed,
    Failed,
}

impl EmbeddingStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }
}

/// Lifecycle status of an `ai_triage_queue` row. A job is `Pending` → (claimed)
/// `Processing` → deleted on success, `Failed` (+attempts) on error, or
/// `Deferred` when it needs a model that isn't configured yet. There is no
/// `Completed` variant — a successful job deletes its row. These string values
/// are the single source of truth for the triage-queue SQL; never hardcode them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriageStatus {
    Pending,
    Processing,
    Deferred,
    Failed,
}

impl TriageStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Processing => "processing",
            Self::Deferred => "deferred",
            Self::Failed => "failed",
        }
    }
}

/// A queued provider send. `message` is the composed payload; the row is the
/// single source of truth for delivery until it reaches `Sent`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutboxMessage {
    pub key: String,
    pub account_key: String,
    #[serde(default)]
    pub kind: OutboxKind,
    /// Drafts only: which draft this row is a version of.
    #[serde(default)]
    pub draft_key: Option<String>,
    pub message: crate::sync::interactive::OutgoingMessage,
    pub status: OutboxStatus,
    pub retry_count: u32,
    pub max_retries: u32,
    pub next_retry_at: Option<DateTime<Utc>>,
    pub provider_message_id: Option<String>,
    pub error_message: Option<String>,
}

/// Outcome of enqueuing a send: returned to the UI so it can distinguish a
/// confirmed send (`Sent`, with a provider id) from one that's durably queued
/// and will retry (`Pending`, optionally with the first attempt's error).
#[derive(Debug, Clone, Serialize)]
pub struct OutboxSendResult {
    pub outbox_key: String,
    pub status: OutboxStatus,
    pub provider_message_id: Option<String>,
    pub error_message: Option<String>,
}

// ---------------------------------------------------------------------------
// Provider / account enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderType {
    Imap,
    Gmail,
    Microsoft,
    /// Meta BYOK channels — each is its own account/provider but shares one
    /// `MetaAdapter` implementation switched by channel. See docs/Channels.md
    /// (Meta section) and docs/Cloud-Push.md (Meta relay).
    Instagram,
    Messenger,
    WhatsApp,
}

impl ProviderType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Imap => "imap",
            Self::Gmail => "gmail",
            Self::Microsoft => "microsoft",
            Self::Instagram => "instagram",
            Self::Messenger => "messenger",
            Self::WhatsApp => "whatsapp",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "imap" => Some(Self::Imap),
            "gmail" => Some(Self::Gmail),
            "microsoft" => Some(Self::Microsoft),
            "instagram" => Some(Self::Instagram),
            "messenger" => Some(Self::Messenger),
            "whatsapp" => Some(Self::WhatsApp),
            _ => None,
        }
    }

    /// Whether this provider supports Rails-backed cloud push (Gmail Pub/Sub watch,
    /// Microsoft Graph subscriptions). IMAP uses IDLE instead. See docs/Cloud-Push.md.
    pub fn supports_cloud_push(&self) -> bool {
        matches!(self, Self::Gmail | Self::Microsoft)
    }

    /// The Meta channels (Instagram DMs/comments, Facebook Messenger + Page
    /// comments, WhatsApp). They share one BYOK adapter and the Meta webhook
    /// relay rather than the mail providers' poll/cloud-push path.
    pub fn is_meta(&self) -> bool {
        matches!(self, Self::Instagram | Self::Messenger | Self::WhatsApp)
    }

    /// The [`MetaChannel`] for a Meta provider type, else `None`.
    pub fn meta_channel(&self) -> Option<MetaChannel> {
        match self {
            Self::Instagram => Some(MetaChannel::Instagram),
            Self::Messenger => Some(MetaChannel::Messenger),
            Self::WhatsApp => Some(MetaChannel::WhatsApp),
            _ => None,
        }
    }
}

/// Which Meta surface a [`MetaAdapter`](crate::sync::adapters::MetaAdapter)
/// instance serves. One adapter implementation, switched by this field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MetaChannel {
    /// Instagram DMs + comments + @mentions (linked via a Facebook Page).
    Instagram,
    /// Facebook Messenger DMs + Facebook Page feed comments.
    Messenger,
    /// WhatsApp Business messages + delivery/read statuses.
    WhatsApp,
}

impl MetaChannel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Instagram => "instagram",
            Self::Messenger => "messenger",
            Self::WhatsApp => "whatsapp",
        }
    }

    pub fn provider_type(&self) -> ProviderType {
        match self {
            Self::Instagram => ProviderType::Instagram,
            Self::Messenger => ProviderType::Messenger,
            Self::WhatsApp => ProviderType::WhatsApp,
        }
    }
}

/// How an account authenticates with its provider. The canonical persisted /
/// IPC strings are `"oauth2"` and `"password"`. `from_str` also accepts the
/// `"xoauth2"` synonym (IMAP SASL name) for OAuth2 and the `"plain"` synonym for
/// password, collapsing the duplicated synonym matches that previously lived in
/// the FFI and Tauri add-account paths.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthMethod {
    OAuth2,
    Password,
}

impl AuthMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::OAuth2 => "oauth2",
            Self::Password => "password",
        }
    }

    /// Parse an auth-method string. `"xoauth2"` (the IMAP SASL name) is an alias
    /// of OAuth2; `"plain"` an alias of Password — both arrive live from the FFI
    /// and Tauri add-account paths. Anything else is a bug; it's logged and
    /// coerced to `Password` (the safe, non-OAuth default).
    pub fn from_str(s: &str) -> Self {
        match s {
            "oauth2" | "xoauth2" => Self::OAuth2,
            "password" | "plain" => Self::Password,
            other => {
                log::error!("unknown auth method {other:?}; treating as password");
                Self::Password
            }
        }
    }

    /// Whether this method authenticates via OAuth2 (vs. a stored password).
    pub fn is_oauth(&self) -> bool {
        matches!(self, Self::OAuth2)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AccountStatus {
    Disconnected,
    Connecting,
    Connected,
    Error,
    /// The stored OAuth/credentials are dead (refresh failed, or the provider
    /// returned 401/403). Unlike `Error` — a transient failure that the next
    /// sync recovers from — this is sticky until the user re-authenticates, so
    /// clients surface a "Reconnect" prompt for it.
    #[serde(rename = "needs_reauth")]
    NeedsReauth,
}

impl AccountStatus {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Disconnected => "disconnected",
            Self::Connecting => "connecting",
            Self::Connected => "connected",
            Self::Error => "error",
            Self::NeedsReauth => "needs_reauth",
        }
    }

    /// Parse a stored status string — the inverse of [`as_str`]. An unknown
    /// value is a bug (we wrote every row); it's logged and coerced to
    /// `Disconnected` so the read itself doesn't crash.
    pub fn from_str(s: &str) -> Self {
        match s {
            "disconnected" => Self::Disconnected,
            "connecting" => Self::Connecting,
            "connected" => Self::Connected,
            "error" => Self::Error,
            "needs_reauth" => Self::NeedsReauth,
            other => {
                log::error!("unknown account status {other:?}; treating as disconnected");
                Self::Disconnected
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Conversation status
// ---------------------------------------------------------------------------

/// Lifecycle state of a conversation, mirrored into the `conversations.status`
/// column. Derived from a message's [`UnifiedFlags`] at sync time and read back
/// to decide inbox visibility (spam/trash are filtered out).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConversationStatus {
    Open,
    Archived,
    Spam,
    Trash,
}

impl ConversationStatus {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Open => "open",
            Self::Archived => "archived",
            Self::Spam => "spam",
            Self::Trash => "trash",
        }
    }

    /// Parse a stored status string — the inverse of [`as_str`]. An unknown
    /// value is a bug (we wrote every row); it's logged and coerced to `Open`
    /// so the read itself doesn't crash.
    pub fn from_str(s: &str) -> Self {
        match s {
            "open" => Self::Open,
            "archived" => Self::Archived,
            "spam" => Self::Spam,
            "trash" => Self::Trash,
            other => {
                log::error!("unknown conversation status {other:?}; treating as open");
                Self::Open
            }
        }
    }

    /// Derive the conversation status implied by a message's flags. Trash wins
    /// over spam wins over archived; otherwise the conversation is open. This is
    /// the single source for the status assigned when threading a message.
    pub fn from_flags(flags: &UnifiedFlags) -> Self {
        if flags.trashed {
            Self::Trash
        } else if flags.spam {
            Self::Spam
        } else if flags.archived {
            Self::Archived
        } else {
            Self::Open
        }
    }

    /// Whether a conversation in this state is hidden from the inbox list
    /// (and so should not raise a new-message notification).
    pub fn is_hidden_from_inbox(&self) -> bool {
        matches!(self, Self::Spam | Self::Trash)
    }
}

/// Map a user-action verb to the local conversation state it implies, so the
/// action can be applied optimistically before its write-back reaches the
/// provider. Returns `(status, read)` where a `None` field means "leave
/// unchanged". Verbs that touch neither status nor read (flag, move, label,
/// set/clear quadrant) return `(None, None)`. This is the single source mapping
/// an action to local state — used by `perform_conversation_action`.
pub fn local_state_for_action(action: &str) -> (Option<ConversationStatus>, Option<bool>) {
    match action {
        "archive" => (Some(ConversationStatus::Archived), None),
        "trash" | "delete" => (Some(ConversationStatus::Trash), None),
        "spam" | "junk" => (Some(ConversationStatus::Spam), None),
        "unarchive" | "untrash" | "unspam" | "open" => (Some(ConversationStatus::Open), None),
        "mark_read" => (None, Some(true)),
        "mark_unread" => (None, Some(false)),
        _ => (None, None),
    }
}

// ---------------------------------------------------------------------------
// Triage quadrant
// ---------------------------------------------------------------------------

/// Eisenhower triage quadrant, the named form of a conversation's
/// (urgent, important) priority pair. Single source for the quadrant keys used
/// in `set_quadrant:KEY` write-back verbs and for the provider-side
/// `inbox2/<Name>` label names (Gmail labels, Graph categories, and IMAP
/// label-folders all share them).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quadrant {
    DoFirst,
    Delegate,
    Schedule,
    Later,
}

impl Quadrant {
    pub const ALL: [Quadrant; 4] =
        [Quadrant::DoFirst, Quadrant::Delegate, Quadrant::Schedule, Quadrant::Later];

    pub fn as_str(self) -> &'static str {
        match self {
            Quadrant::DoFirst => "DO_FIRST",
            Quadrant::Delegate => "DELEGATE",
            Quadrant::Schedule => "SCHEDULE",
            Quadrant::Later => "LATER",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s {
            "DO_FIRST" => Quadrant::DoFirst,
            "DELEGATE" => Quadrant::Delegate,
            "SCHEDULE" => Quadrant::Schedule,
            "LATER" => Quadrant::Later,
            _ => return None,
        })
    }

    /// The quadrant implied by an (urgent, important) priority pair.
    pub fn from_priority(urgent: bool, important: bool) -> Self {
        match (urgent, important) {
            (true, true) => Quadrant::DoFirst,
            (true, false) => Quadrant::Delegate,
            (false, true) => Quadrant::Schedule,
            (false, false) => Quadrant::Later,
        }
    }

    /// The (urgent, important) pair this quadrant maps back to.
    pub fn priority(self) -> (bool, bool) {
        match self {
            Quadrant::DoFirst => (true, true),
            Quadrant::Delegate => (true, false),
            Quadrant::Schedule => (false, true),
            Quadrant::Later => (false, false),
        }
    }

    /// Provider-side label name (Gmail label, Graph category, IMAP label-folder).
    pub fn folder_name(self) -> &'static str {
        match self {
            Quadrant::DoFirst => "inbox2/Priority",
            Quadrant::Delegate => "inbox2/Delegate",
            Quadrant::Schedule => "inbox2/Schedule",
            Quadrant::Later => "inbox2/Later",
        }
    }

    /// The interactive write-back verb that sets this quadrant.
    pub fn set_verb(self) -> String {
        format!("set_quadrant:{}", self.as_str())
    }
}

// ---------------------------------------------------------------------------
// Provider capabilities
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProviderCapabilities {
    /// IMAP IDLE / Gmail push / Graph subscriptions.
    pub push: bool,
    /// IMAP QRESYNC / Gmail historyId / Graph delta.
    pub incremental_sync: bool,
    /// IMAP CONDSTORE UNCHANGEDSINCE.
    pub conditional_store: bool,
    /// IMAP UID MOVE (not COPY+DELETE).
    pub server_move: bool,
    /// Gmail label model.
    pub labels: bool,
    /// Custom keywords/flags (\* in PERMANENTFLAGS).
    pub custom_keywords: bool,
    /// IMAP NOTIFY (RFC 5465) — multi-folder push on one connection.
    pub notify: bool,
    /// Raw capability strings for debugging.
    pub raw: Vec<String>,
}

// ---------------------------------------------------------------------------
// Provider-native flags (opaque to engine)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProviderFlags {
    pub imap_flags: Vec<String>,
    pub gmail_labels: Vec<String>,
    pub ms_categories: Vec<String>,
    pub folder: Option<String>,
}

// ---------------------------------------------------------------------------
// Authentication credentials
// ---------------------------------------------------------------------------

/// BYOK Meta credentials for one connected channel. The customer creates their
/// own Meta app and supplies these per connection; the System User token is
/// non-expiring (no refresh path). The shared app secret bundle (`app_id`,
/// `app_secret`, `system_user_token`) plus the asset IDs relevant to the channel
/// live here, encrypted on-device. `app_secret` and `system_user_token` never
/// leave the device. Asset IDs not relevant to a channel are `None`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetaCredentials {
    pub app_id: String,
    pub app_secret: String,
    pub system_user_token: String,
    pub facebook_page_id: Option<String>,
    pub instagram_account_id: Option<String>,
    pub whatsapp_phone_number_id: Option<String>,
    pub whatsapp_business_account_id: Option<String>,
    // ── Instagram-Login path (vs the Facebook-Login/Page path above) ──
    // Instagram channels can connect via "Instagram API with Instagram login":
    // a separate Instagram app + an OAuth user token against graph.instagram.com,
    // instead of the System User token + linked Page. When `instagram_user_token`
    // is set, the adapter uses the Instagram-Login endpoints. The app id/secret
    // back the OAuth code exchange + the 60-day token refresh.
    #[serde(default)]
    pub instagram_app_id: Option<String>,
    #[serde(default)]
    pub instagram_app_secret: Option<String>,
    #[serde(default)]
    pub instagram_user_token: Option<String>,
    /// RFC-3339 expiry of the long-lived IG user token (refreshed before this).
    #[serde(default)]
    pub instagram_token_expires_at: Option<String>,
}

#[derive(Debug, Clone)]
pub enum ProviderCredentials {
    Password { username: String, password: String },
    OAuth2 {
        username: String,
        access_token: String,
        refresh_token: Option<String>,
    },
    /// Meta BYOK channels (Instagram/Messenger/WhatsApp). No OAuth refresh —
    /// the System User token is permanent.
    Meta(MetaCredentials),
}

/// On-disk serialization mirror of [`ProviderCredentials`]. `ProviderCredentials`
/// deliberately does *not* derive `Serialize`/`Deserialize` so credentials can
/// never be logged or sent by accident; this explicit, opt-in payload is the
/// only path to (de)serialize them, used by the encrypted credential store.
#[derive(Serialize, Deserialize)]
pub(crate) enum CredentialPayload {
    Password { username: String, password: String },
    OAuth2 {
        username: String,
        access_token: String,
        refresh_token: Option<String>,
    },
    Meta(MetaCredentials),
}

impl From<&ProviderCredentials> for CredentialPayload {
    fn from(creds: &ProviderCredentials) -> Self {
        match creds {
            ProviderCredentials::Password { username, password } => CredentialPayload::Password {
                username: username.clone(),
                password: password.clone(),
            },
            ProviderCredentials::OAuth2 {
                username,
                access_token,
                refresh_token,
            } => CredentialPayload::OAuth2 {
                username: username.clone(),
                access_token: access_token.clone(),
                refresh_token: refresh_token.clone(),
            },
            ProviderCredentials::Meta(m) => CredentialPayload::Meta(m.clone()),
        }
    }
}

impl From<CredentialPayload> for ProviderCredentials {
    fn from(payload: CredentialPayload) -> Self {
        match payload {
            CredentialPayload::Password { username, password } => {
                ProviderCredentials::Password { username, password }
            }
            CredentialPayload::OAuth2 {
                username,
                access_token,
                refresh_token,
            } => ProviderCredentials::OAuth2 {
                username,
                access_token,
                refresh_token,
            },
            CredentialPayload::Meta(m) => ProviderCredentials::Meta(m),
        }
    }
}

// ---------------------------------------------------------------------------
// Credential vault (zero-knowledge cloud backup) — see docs/E2EE.md
// ---------------------------------------------------------------------------

/// Local mirror of the single-row `vault_state` table. Holds the two wrapped DEK
/// copies + Argon params so the device can re-unlock at boot via the keychain copy
/// without re-deriving from the password. The DEK itself never lands here — it
/// lives only in memory after unlock. `bound_user_id` ties the vault to one inbox2
/// identity so a sign-out / account switch invalidates it.
#[derive(Debug, Clone, Default)]
pub struct VaultState {
    pub enabled: bool,
    pub vault_key: Option<String>,
    pub bound_user_id: Option<String>,
    pub device_wrapped_dek: Option<Vec<u8>>,
    pub device_wrapped_nonce: Option<Vec<u8>>,
    pub passphrase_wrapped_dek: Option<Vec<u8>>,
    pub passphrase_wrapped_nonce: Option<Vec<u8>>,
    pub argon_salt: Option<Vec<u8>>,
    /// `ArgonParams` serialized as JSON (kept as a string here so model.rs has no
    /// dependency on the vault crypto module).
    pub argon_params: Option<String>,
}

// ---------------------------------------------------------------------------
// API context (Rails proxy base + auth for OAuth token refresh)
// ---------------------------------------------------------------------------

/// Pushed from the frontend on boot so the Rust backend can reach the Rails
/// OAuth proxy (`/api/v1/auth/{google,microsoft}/refresh`) for token refresh.
/// The proxy holds the OAuth client secret; Rust never sees it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiContext {
    /// e.g. "http://localhost:4000/api/v1"
    pub api_base: String,
    /// Rails JWT bearer (from the web app's localStorage `inbox2_token`). May be
    /// empty: the OAuth proxy's refresh endpoint is public (needs only `api_base`),
    /// so clients that never sign into Rails (e.g. iOS) leave this blank. Cloud
    /// push, which does need it, guards on it being non-empty.
    pub rails_jwt: String,
}

// ---------------------------------------------------------------------------
// Cloud push (Gmail/Office365) — see docs/Cloud-Push.md
// ---------------------------------------------------------------------------

/// Config the engine fetches from Rails (`GET /channel-push-subscriptions/config`)
/// to create provider-side push subscriptions pointing back at our backend.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PushSubConfig {
    /// Whether push is enabled for this user (gating). False → stay on polling.
    #[serde(default)]
    pub push_enabled: bool,
    /// Cloud Pub/Sub topic for the Gmail `users.watch` call.
    pub gmail_topic: Option<String>,
    /// Full notificationUrl for Microsoft Graph subscriptions.
    pub microsoft_notification_url: Option<String>,
}

/// Locally-persisted push subscription state (one row per account), used by the
/// engine to time renewals. Mirror of `PushSubInfo` plus the account key.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PushSubState {
    pub account_key: String,
    /// The Rails-side subscription public id (cpsub_...), for DELETE on teardown.
    pub rails_key: Option<String>,
    pub provider_subscription_id: Option<String>,
    pub client_state: Option<String>,
    pub expires_at: Option<String>,
}

/// Result of creating/renewing a provider-side push subscription. Contains only
/// subscription metadata — never the OAuth token.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PushSubInfo {
    /// Microsoft Graph subscription id; for Gmail, the watch historyId (informational).
    pub provider_subscription_id: Option<String>,
    /// Secret echoed back by Microsoft Graph notifications (clientState). None for Gmail.
    pub client_state: Option<String>,
    /// Provider-side expiry (ISO 8601). The engine renews before this lapses.
    pub expires_at: Option<String>,
}

// ---------------------------------------------------------------------------
// Sync-integrity report (sync-check CLI)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IntegrityReport {
    pub accounts: i64,
    pub folders: i64,
    pub sync_enabled_folders: i64,
    pub folders_with_cursor: i64,
    pub messages: i64,
    pub conversations: i64,
    pub provider_states: i64,
    pub calendars: i64,
    pub calendar_events: i64,
    // Violations — all should be zero on a healthy sync.
    pub orphan_provider_states: i64,
    pub messages_missing_conversation: i64,
    pub messages_without_provider_state: i64,
    pub duplicate_message_ids: i64,
    pub events_missing_calendar: i64,
}

impl IntegrityReport {
    /// The integrity invariants that must hold after a full sync.
    pub fn violations(&self) -> Vec<String> {
        let mut v = Vec::new();
        if self.orphan_provider_states > 0 {
            v.push(format!("{} provider-state rows reference a missing message", self.orphan_provider_states));
        }
        if self.messages_missing_conversation > 0 {
            v.push(format!("{} messages reference a missing conversation", self.messages_missing_conversation));
        }
        if self.messages_without_provider_state > 0 {
            v.push(format!("{} messages have no provider-state row", self.messages_without_provider_state));
        }
        if self.duplicate_message_ids > 0 {
            v.push(format!("{} Message-IDs are duplicated within an account", self.duplicate_message_ids));
        }
        if self.events_missing_calendar > 0 {
            v.push(format!("{} calendar events reference a missing calendar", self.events_missing_calendar));
        }
        v
    }
}

// ---------------------------------------------------------------------------
// New-message notification payload (emitted to the frontend)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct NewMessageNotification {
    pub key: String,
    pub subject: Option<String>,
    pub from_address: Option<String>,
    pub snippet: Option<String>,
    pub updated_at: Option<String>,
    /// The sender's profile picture when the channel has one (Meta DMs), so the
    /// card shows a face instead of a favicon — see docs/Notifications.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_avatar: Option<String>,
    #[serde(rename = "accountKey")]
    pub account_key: String,
    pub email: String,
    /// The arriving message itself (the `key` above is its *conversation*). The
    /// alert card needs it to look up a meeting invite — see docs/Meeting-Invites.md.
    #[serde(rename = "messageKey")]
    pub message_key: String,
    /// Whether the thread carries an attachment — the gate that keeps the
    /// invite lookup (a live provider fetch) off ordinary mail.
    #[serde(rename = "hasAttachment")]
    pub has_attachment: bool,
    /// A sign-in code or link found in the message (`crate::otp`), so the alert
    /// can offer Copy / Open link — see docs/Notifications.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub otp: Option<crate::otp::Otp>,
}

// ---------------------------------------------------------------------------
// External account (for store/commands)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalAccount {
    pub key: String,
    pub display_name: String,
    pub email_address: String,
    pub provider_type: ProviderType,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub use_tls: bool,
    /// SMTP submission host for IMAP accounts (None for Gmail/Microsoft, which
    /// send via their APIs).
    pub smtp_host: Option<String>,
    /// SMTP submission port (typically 465 implicit-TLS or 587 STARTTLS).
    pub smtp_port: Option<u16>,
    /// SMTP TLS mode: true = implicit TLS (465), false = STARTTLS (587).
    pub smtp_use_tls: bool,
    pub auth_method: String,
    pub status: AccountStatus,
    pub error_message: Option<String>,
    pub last_connected_at: Option<String>,
    pub sort_order: i32,
    pub avatar_url: Option<String>,
}

// ---------------------------------------------------------------------------
// Tests — enum string round-trips and credential serialization
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_status_round_trips_through_strings() {
        for s in [
            AccountStatus::Disconnected,
            AccountStatus::Connecting,
            AccountStatus::Connected,
            AccountStatus::Error,
            AccountStatus::NeedsReauth,
        ] {
            assert_eq!(AccountStatus::from_str(s.as_str()), s);
        }
        // Unknown/legacy values fall back to Disconnected.
        assert_eq!(AccountStatus::from_str("bogus"), AccountStatus::Disconnected);
    }

    #[test]
    fn outbox_status_round_trips_through_strings() {
        for s in [
            OutboxStatus::Pending,
            OutboxStatus::Sending,
            OutboxStatus::Sent,
            OutboxStatus::Failed,
            OutboxStatus::Deleted,
        ] {
            assert_eq!(OutboxStatus::from_str(s.as_str()), s);
        }
        // Unknown/legacy values fall back to Pending.
        assert_eq!(OutboxStatus::from_str("bogus"), OutboxStatus::Pending);
    }

    #[test]
    fn auth_method_round_trips_and_aliases() {
        // Canonical values round-trip.
        assert_eq!(AuthMethod::from_str(AuthMethod::OAuth2.as_str()), AuthMethod::OAuth2);
        assert_eq!(AuthMethod::from_str(AuthMethod::Password.as_str()), AuthMethod::Password);
        // Synonyms collapse onto the canonical variants.
        assert_eq!(AuthMethod::from_str("xoauth2"), AuthMethod::OAuth2);
        assert_eq!(AuthMethod::from_str("plain"), AuthMethod::Password);
        // Unknown values default to Password (non-OAuth).
        assert_eq!(AuthMethod::from_str("bogus"), AuthMethod::Password);
        assert!(AuthMethod::OAuth2.is_oauth());
        assert!(!AuthMethod::Password.is_oauth());
        // The canonical strings stay byte-identical to the persisted/IPC values.
        assert_eq!(AuthMethod::OAuth2.as_str(), "oauth2");
        assert_eq!(AuthMethod::Password.as_str(), "password");
    }

    #[test]
    fn action_status_round_trips_through_strings() {
        for s in [
            ActionStatus::Pending,
            ActionStatus::InProgress,
            ActionStatus::Completed,
            ActionStatus::Failed,
        ] {
            assert_eq!(ActionStatus::from_str(s.as_str()), s);
        }
        assert_eq!(ActionStatus::from_str("bogus"), ActionStatus::Pending);
    }

    #[test]
    fn conversation_status_round_trips_through_strings() {
        for s in [
            ConversationStatus::Open,
            ConversationStatus::Archived,
            ConversationStatus::Spam,
            ConversationStatus::Trash,
        ] {
            assert_eq!(ConversationStatus::from_str(s.as_str()), s);
        }
        assert_eq!(ConversationStatus::from_str("bogus"), ConversationStatus::Open);
    }

    #[test]
    fn local_state_for_action_maps_verbs_to_status_and_read() {
        use ConversationStatus::*;
        // Removal verbs set status, leave read untouched.
        assert_eq!(local_state_for_action("archive"), (Some(Archived), None));
        assert_eq!(local_state_for_action("trash"), (Some(Trash), None));
        assert_eq!(local_state_for_action("delete"), (Some(Trash), None));
        assert_eq!(local_state_for_action("spam"), (Some(Spam), None));
        assert_eq!(local_state_for_action("junk"), (Some(Spam), None));
        // Reverse verbs return to the inbox.
        assert_eq!(local_state_for_action("unarchive"), (Some(Open), None));
        assert_eq!(local_state_for_action("untrash"), (Some(Open), None));
        assert_eq!(local_state_for_action("unspam"), (Some(Open), None));
        assert_eq!(local_state_for_action("open"), (Some(Open), None));
        // Read verbs set read, leave status untouched.
        assert_eq!(local_state_for_action("mark_read"), (None, Some(true)));
        assert_eq!(local_state_for_action("mark_unread"), (None, Some(false)));
        // Verbs that touch neither: no local state change.
        for verb in ["flag", "unflag", "move", "add_label", "set_quadrant:DO_FIRST", "clear_quadrant"] {
            assert_eq!(local_state_for_action(verb), (None, None), "verb {verb}");
        }
    }

    #[test]
    fn quadrant_round_trips_and_maps_priority() {
        for q in Quadrant::ALL {
            assert_eq!(Quadrant::from_str(q.as_str()), Some(q));
            let (urgent, important) = q.priority();
            assert_eq!(Quadrant::from_priority(urgent, important), q);
            assert!(q.folder_name().starts_with("inbox2/"));
        }
        assert_eq!(Quadrant::from_str("BOGUS"), None);
        assert_eq!(Quadrant::DoFirst.set_verb(), "set_quadrant:DO_FIRST");
        assert_eq!(Quadrant::from_priority(true, true), Quadrant::DoFirst);
        assert_eq!(Quadrant::from_priority(true, false), Quadrant::Delegate);
        assert_eq!(Quadrant::from_priority(false, true), Quadrant::Schedule);
        assert_eq!(Quadrant::from_priority(false, false), Quadrant::Later);
    }

    #[test]
    fn conversation_status_from_flags_priority_is_trash_spam_archived_open() {
        let open = UnifiedFlags::default();
        assert_eq!(ConversationStatus::from_flags(&open), ConversationStatus::Open);

        let archived = UnifiedFlags { archived: true, ..Default::default() };
        assert_eq!(ConversationStatus::from_flags(&archived), ConversationStatus::Archived);

        let spam = UnifiedFlags { spam: true, archived: true, ..Default::default() };
        assert_eq!(ConversationStatus::from_flags(&spam), ConversationStatus::Spam);

        // Trash outranks everything else.
        let trash = UnifiedFlags {
            trashed: true,
            spam: true,
            archived: true,
            ..Default::default()
        };
        assert_eq!(ConversationStatus::from_flags(&trash), ConversationStatus::Trash);
    }

    #[test]
    fn action_settled_by_flags_tracks_intent() {
        let inbox = UnifiedFlags::default();
        let trashed = UnifiedFlags { trashed: true, ..Default::default() };
        let archived = UnifiedFlags { archived: true, ..Default::default() };
        let read = UnifiedFlags { read: true, ..Default::default() };
        let spam = UnifiedFlags { spam: true, ..Default::default() };

        // Status/read actions are settled only when the flags reflect the intent.
        assert!(!ActionType::Trash.settled_by_flags(&inbox));
        assert!(ActionType::Trash.settled_by_flags(&trashed));
        assert!(ActionType::Delete.settled_by_flags(&trashed));
        assert!(!ActionType::Archive.settled_by_flags(&inbox));
        assert!(ActionType::Archive.settled_by_flags(&archived));
        assert!(ActionType::Unarchive.settled_by_flags(&inbox));
        assert!(!ActionType::Unarchive.settled_by_flags(&archived));
        assert!(!ActionType::MarkRead.settled_by_flags(&inbox));
        assert!(ActionType::MarkRead.settled_by_flags(&read));
        assert!(ActionType::MarkUnread.settled_by_flags(&inbox));

        // Interactive verbs that drive the mirror.
        let spam_action = ActionType::Interactive { verb: "spam".into() };
        assert!(!spam_action.settled_by_flags(&inbox));
        assert!(spam_action.settled_by_flags(&spam));

        // Actions that never feed the status/read mirror are always "settled",
        // so they can never block (or be blocked by) it.
        assert!(ActionType::Flag.settled_by_flags(&inbox));
        assert!(ActionType::AddLabel { label: "x".into() }.settled_by_flags(&inbox));
        assert!(ActionType::Move { target_folder: "f".into() }.settled_by_flags(&inbox));
        assert!(ActionType::Interactive { verb: "set_quadrant:do".into() }
            .settled_by_flags(&inbox));
    }

    #[test]
    fn conversation_status_hidden_from_inbox_only_for_spam_and_trash() {
        assert!(ConversationStatus::Spam.is_hidden_from_inbox());
        assert!(ConversationStatus::Trash.is_hidden_from_inbox());
        assert!(!ConversationStatus::Open.is_hidden_from_inbox());
        assert!(!ConversationStatus::Archived.is_hidden_from_inbox());
    }

    #[test]
    fn credential_payload_round_trips_both_variants() {
        // Password
        let pw = ProviderCredentials::Password {
            username: "alice".into(),
            password: "s3cret".into(),
        };
        let json = serde_json::to_string(&CredentialPayload::from(&pw)).unwrap();
        let back: ProviderCredentials =
            serde_json::from_str::<CredentialPayload>(&json).unwrap().into();
        match back {
            ProviderCredentials::Password { username, password } => {
                assert_eq!(username, "alice");
                assert_eq!(password, "s3cret");
            }
            _ => panic!("expected Password variant"),
        }

        // OAuth2 with refresh token
        let oauth = ProviderCredentials::OAuth2 {
            username: "bob".into(),
            access_token: "at".into(),
            refresh_token: Some("rt".into()),
        };
        let json = serde_json::to_string(&CredentialPayload::from(&oauth)).unwrap();
        let back: ProviderCredentials =
            serde_json::from_str::<CredentialPayload>(&json).unwrap().into();
        match back {
            ProviderCredentials::OAuth2 { username, access_token, refresh_token } => {
                assert_eq!(username, "bob");
                assert_eq!(access_token, "at");
                assert_eq!(refresh_token.as_deref(), Some("rt"));
            }
            _ => panic!("expected OAuth2 variant"),
        }
    }
}
