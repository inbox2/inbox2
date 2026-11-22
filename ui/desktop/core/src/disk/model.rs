//! Shapes shared by the store, the API client and the FFI.

use serde::Deserialize;

/// The File Provider root container. Its children are the drive roots
/// ("My files" for C:\ and one folder per share).
pub const ROOT_ID: &str = "root";
/// File Provider's trash container. Disk trash stays in inbox2; we never put
/// items here, but the OS may ask for it.
pub const TRASH_ID: &str = "trash";

/// The content version of a file with no version yet (Disk::Upload::NO_VERSION).
pub const NO_VERSION: &str = "none";

pub const KIND_FOLDER: &str = "folder";
pub const KIND_FILE: &str = "file";
pub const KIND_PAGE: &str = "page";

/// What Finder shows for a Disk page (a read-only stub that opens inbox2).
pub const PAGE_EXTENSION: &str = "page";
/// The virtual folder for items shared from someone else's C:\.
pub const SHARED_ID: &str = "shared-with-me";
pub const SHARED_WITH_ME: &str = "Shared with me";
/// The folder name for the member's C:\ drive root.
pub const MY_FILES: &str = "My files";

/// One item as the extension hands it to macOS.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "mobile-ffi", derive(uniffi::Record))]
pub struct DiskItem {
    pub id: String,
    /// `ROOT_ID` for a drive root.
    pub parent_id: String,
    /// The display name, decrypted for sealed items; ".page" added for pages.
    pub filename: String,
    pub kind: String,
    pub mime: Option<String>,
    /// Plaintext bytes (0 for folders).
    pub size: u64,
    /// Seconds since the epoch.
    pub modified_at: i64,
    /// The current version's id, or the node id for folders and pages. This is
    /// the content version macOS hands back as the base of an edit.
    pub content_version: String,
    /// Bumps on every metadata change (rename, move).
    pub metadata_version: String,
    pub can_write: bool,
    pub sealed: bool,
    /// Set when the item's name or content can't be opened on this Mac (a
    /// sealed share whose key isn't on this device).
    pub locked: bool,
    /// A drive root under "Keep on this Mac": macOS downloads everything
    /// beneath it and keeps it.
    pub keep_downloaded: bool,
}

/// One page of `changes_since`.
#[derive(Debug, Clone, Default)]
#[cfg_attr(feature = "mobile-ffi", derive(uniffi::Record))]
pub struct DiskChanges {
    pub updated: Vec<DiskItem>,
    pub deleted: Vec<String>,
    pub anchor: u64,
    pub more: bool,
}

/// What `modify_contents` did. A conflict keeps the server's file and uploads
/// the Mac's copy next to it under a "conflicted copy" name.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "mobile-ffi", derive(uniffi::Record))]
pub struct DiskWrite {
    pub item: DiskItem,
    pub conflict_copy: Option<DiskItem>,
}

/// The engine's state for Settings and the tray.
#[derive(Debug, Clone, Default, serde::Serialize)]
#[cfg_attr(feature = "mobile-ffi", derive(uniffi::Record))]
pub struct DiskStatus {
    pub items: u64,
    pub uploading: u64,
    pub last_sync_at: Option<i64>,
    pub last_error: Option<String>,
    pub signed_in: bool,
}

/// Errors the extension maps onto `NSFileProviderError` codes.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
#[cfg_attr(feature = "mobile-ffi", derive(uniffi::Error))]
pub enum DiskError {
    /// No network or the server is down: macOS keeps the change and retries.
    #[error("offline: {0}")]
    Offline(String),
    #[error("signed out")]
    SignedOut,
    #[error("not found")]
    NotFound,
    #[error("no permission: {0}")]
    NoPermission(String),
    #[error("storage full")]
    StorageFull,
    #[error("name taken: {0}")]
    NameTaken(String),
    #[error("name not allowed: {0}")]
    NameNotAllowed(String),
    /// A sealed item whose key isn't on this Mac.
    #[error("locked")]
    Locked,
    #[error("{0}")]
    Other(String),
}

pub type DiskResult<T> = std::result::Result<T, DiskError>;

impl DiskError {
    /// Worth retrying later without anyone doing anything.
    pub fn is_transient(&self) -> bool {
        matches!(self, DiskError::Offline(_))
    }
}

impl From<rusqlite::Error> for DiskError {
    fn from(e: rusqlite::Error) -> Self {
        DiskError::Other(format!("disk store: {e}"))
    }
}

impl From<std::io::Error> for DiskError {
    fn from(e: std::io::Error) -> Self {
        DiskError::Other(format!("file: {e}"))
    }
}

// ── API shapes (docs/Disk-Sync.md, "Server feed") ─────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct ApiVersion {
    pub id: String,
    #[serde(default)]
    pub size_bytes: u64,
    pub wrapped_key: Option<String>,
    pub manifest_ciphertext: Option<String>,
    pub key_epoch: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApiNode {
    pub id: String,
    pub parent_id: Option<String>,
    pub drive: Option<String>,
    pub share_name: Option<String>,
    pub kind: String,
    pub name: Option<String>,
    pub mime: Option<String>,
    #[serde(default)]
    pub sealed: bool,
    pub metadata_ciphertext: Option<String>,
    pub key_epoch: Option<i64>,
    pub seal_scope_id: Option<String>,
    #[serde(default)]
    pub size_bytes: u64,
    pub content_modified_at: Option<String>,
    pub updated_at: Option<String>,
    #[serde(default)]
    pub change_seq: i64,
    pub current_version: Option<ApiVersion>,
    #[serde(default = "yes")]
    pub can_write: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Deserialize)]
pub struct PullPage {
    pub cursor: String,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub cursor_expired: bool,
    #[serde(default)]
    pub reconcile: bool,
    #[serde(default)]
    pub nodes: Vec<ApiNode>,
    #[serde(default)]
    pub deleted: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct KeysPage {
    pub keys: Vec<(String, i64)>,
    pub next: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NodesPage {
    pub nodes: Vec<ApiNode>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApiUpload {
    pub id: String,
    pub state: String,
    pub part_bytes: u64,
    pub part_count: u32,
    pub node_id: Option<String>,
    pub version_id: Option<String>,
    pub key_epoch: Option<i64>,
    pub chunk_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct StoredPart {
    pub number: u32,
    pub size_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct PartUrl {
    pub number: u32,
    pub url: String,
}

#[derive(Debug, Deserialize)]
pub struct ScopeGrant {
    pub epoch: i64,
    pub sealed_key: String,
}

#[derive(Debug, Deserialize)]
pub struct ScopeEpoch {
    pub epoch: i64,
    pub previous_key_wrapped: String,
}

#[derive(Debug, Deserialize)]
pub struct ApiScope {
    pub id: String,
    pub epoch: i64,
    #[serde(default)]
    pub rotation_due: bool,
    #[serde(default)]
    pub grants: Vec<ScopeGrant>,
    #[serde(default)]
    pub epochs: Vec<ScopeEpoch>,
}
