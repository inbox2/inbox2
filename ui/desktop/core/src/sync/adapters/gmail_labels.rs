//! Gmail system label IDs, shared across the adapters and interactive paths.
//!
//! Centralized per the "no duplicated enums" rule — these literals were
//! previously repeated across `gmail_mail` (flag derivation + write-back) and
//! `interactive` (the batch-modify verb table). The label→role taxonomy in
//! `gmail_mail::label_role`/`is_flag_label` keeps its own match-arm literals:
//! those *are* the canonical mapping table, not a duplicated constant.

pub(crate) const INBOX: &str = "INBOX";
pub(crate) const UNREAD: &str = "UNREAD";
pub(crate) const STARRED: &str = "STARRED";
pub(crate) const TRASH: &str = "TRASH";
pub(crate) const SPAM: &str = "SPAM";
pub(crate) const DRAFT: &str = "DRAFT";
