//! `SyncStore` — engine settings, the AI triage/summary work queue, and the
//! thread-text read + result write used by [`crate::ai_worker::TriageWorker`].
//!
//! The queue is priority-ordered by the conversation's `updated_at` (RFC3339,
//! which sorts chronologically) so the newest conversations are processed first.
//! Lifecycle of a job: `pending` → (claimed) `processing` → deleted on success,
//! or `failed` (+attempts) on error. A new message landing on a thread re-upserts
//! its row back to `pending` (see [`enqueue_triage_job`]) — that overwrite is the
//! re-classification trigger and also protects against a completion deleting a
//! row that was re-enqueued mid-generation (completion only deletes `processing`).

use super::*;
use crate::triage::{JevMessage, ProcessingWindow, SpaceDef, TriageLabel, TriageLabelDef};

/// Give up on a conversation after this many failed generation attempts so one
/// poison thread can't wedge the queue.
const TRIAGE_MAX_ATTEMPTS: i64 = 3;
/// A `processing` row whose worker died is reclaimed after this long.
const TRIAGE_STALE_PROCESSING_SECS: i64 = 300;
/// After a job fails, skip it for this long before it's claimable again — so one failing
/// thread doesn't block the queue head; the worker drains other jobs first, then retries it.
const TRIAGE_FAIL_BACKOFF_SECS: i64 = 90;
/// After a job is deferred (no usable model / assets not ready), wait this long before
/// reactivating it — otherwise a model that reports "available" but errors on every call
/// (e.g. Apple Intelligence `assetsUnavailable` while assets download) re-tries every tick.
const TRIAGE_DEFER_BACKOFF_SECS: i64 = 60;
/// How many times one job may defer (model reported ready but errored "unavailable" on
/// this thread, or it stayed ambiguous) before it's treated like exhausted poison and
/// given the deterministic fallback label. Without this cap a single thread that always
/// trips `is_model_unavailable` loops defer→reactivate forever and wedges the "Catching
/// up" bar one short of 100% (defers never charge an `attempts`, so poison never triggers).
const TRIAGE_MAX_DEFERS: i64 = 10;
/// How many of a thread's most recent messages feed the prompt.
const TRIAGE_THREAD_MESSAGES: usize = 8;
/// Per-message body cap fed to the prompt (keeps the on-device context small).
const TRIAGE_BODY_CHARS: usize = 1500;

/// The `engine_settings` key holding the [`ProcessingWindow`].
const PROCESSING_WINDOW_KEY: &str = "processing_window";
/// When the window is `new_only`, the moment it was picked (RFC3339).
const PROCESSING_WINDOW_SINCE_KEY: &str = "processing_window_since";
/// The effective Space list (org + personal, normalized JSON) the stored
/// `space_slug`s were filed against. Absent (a fresh store, or one still holding
/// the old LLM classifier's verdicts) or different = re-file everything.
const SPACES_FILED_KEY: &str = "space_taxonomy_filed";
/// The `engine_settings` key holding this device's personal Spaces (JSON
/// `[SpaceDef,…]`). Absent = [`crate::triage::default_personal_spaces`].
const PERSONAL_SPACES_KEY: &str = "personal_spaces";
const SPACE_CLASSIFY_ENABLED_KEY: &str = "space_classify_enabled";
/// The `engine_settings` key holding the org Space taxonomy Jev files into: JSON
/// `[{slug,name,description,not_for},…]` (legacy `[["slug","description"],…]`
/// still reads), pushed by the client from the org's classifiable spaces.
const SPACE_TAXONOMY_KEY: &str = "space_taxonomy";
/// The `engine_settings` key holding the triage label list (built-ins + custom),
/// JSON `[TriageLabelDef,…]` in position order. Absent = the built-ins.
const TRIAGE_LABELS_KEY: &str = "triage_labels";
/// The `vector_settings` key holding the embedding window (its own, wider bound
/// than triage's — semantic embedding over a deep archive is the costly part).
const EMBEDDING_WINDOW_KEY: &str = "embedding_window";
/// Embedding defaults to a year of history (vs triage's one month).
const EMBEDDING_WINDOW_DEFAULT: ProcessingWindow = ProcessingWindow::OneYear;

/// Thread text + staleness key for one conversation, assembled for the worker.
pub struct TriageInput {
    pub subject: Option<String>,
    /// Assembled recent-message text (direction + sender + body), newest last.
    pub thread_text: String,
    /// The conversation's newest message key at read time — the staleness anchor.
    pub newest_msg_key: String,
    /// When that newest message was sent (as stored) — the summary lane resolves
    /// "next Friday" in a detected meeting against it.
    pub newest_at: Option<String>,
    /// A high-confidence deterministic verdict from [`detect_label`] (bills,
    /// invoices, calendar invites, signatures, password resets, marketing, …),
    /// or `None` when the thread needs the model's judgment.
    pub deterministic: Option<TriageLabel>,
    /// The deciding rule when `deterministic` is `Some` (e.g. `rule:action`); ""
    /// otherwise. Stored as `triage_source` provenance.
    pub det_source: &'static str,
    /// The mailbox address the thread belongs to (the Jev `owner`); "" when unknown.
    pub owner: String,
    /// The same recent messages as `thread_text`, structured for the Jev `state`
    /// (oldest first, quotes stripped, each capped at `TRIAGE_BODY_CHARS`).
    pub messages: Vec<JevMessage>,
    /// All raw signals that fired (comma-separated), recorded even when deferring
    /// to the model. Stored as `triage_signals` for later heuristic tuning.
    pub signals: String,
}

/// The bill-wording rule. Unlike the other rules it only stands in for Jev:
/// "invoice", "statement", "autopay" also fill paid receipts and statements to
/// review, so with a Jev key Jev picks among payment_due / receipt / to_review
/// (2026-10-20) and the rule labels only when Jev isn't there or doesn't answer.
pub const RULE_PAYMENT: &str = "rule:payment";

impl TriageInput {
    /// The rule fired but Jev should decide when it can (see [`RULE_PAYMENT`]).
    pub fn rule_defers_to_jev(&self) -> bool {
        self.det_source == RULE_PAYMENT
    }
}

/// One fixture message for [`SyncStore::seed_eval_thread`] (the triage eval harness).
pub struct EvalSeedMessage<'a> {
    pub from: Option<&'a str>,
    pub message_id_header: Option<&'a str>,
    pub body_plain: &'a str,
    pub body_html: Option<&'a str>,
    /// `true` = the inbox owner sent it (direction-tagged "From the owner (sent)").
    pub sent_by_owner: bool,
}

/// What a conversation already carries, for the worker's fast path.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct TriageMeta {
    /// The staleness anchor the stored bundle was written for.
    pub msg_key: Option<String>,
    pub label: Option<String>,
    pub priority: Option<f64>,
    pub space: Option<String>,
    /// `triage_source` as stored (the fast path adds its `jev:` part to it).
    pub source: Option<String>,
    /// `ai_summary_short` as stored (rides on the fast path's `triage-updated`).
    pub summary_short: Option<String>,
    /// `ai_summary_medium` as stored (kept by a re-run with no summary lane).
    pub summary_medium: Option<String>,
    /// The user placed `space` by hand: nothing automatic may move it.
    pub space_manual: bool,
    /// The newest message key when the user set `label` by hand; the label
    /// sticks while this is still the thread's newest message.
    pub label_manual_msg_key: Option<String>,
}

impl TriageMeta {
    /// Whether a hand-set label still holds for a thread whose newest message is
    /// `newest_msg_key` (no new mail since the user picked it).
    pub fn label_is_manual(&self, newest_msg_key: &str) -> bool {
        self.label_manual_msg_key.as_deref() == Some(newest_msg_key)
    }
}

/// Counts driving the clients' progress bar.
pub struct TriageProgress {
    /// Conversations eligible for triage — inside the processing window, or open
    /// (in the inbox) whatever their age (the denominator).
    pub in_window: i64,
    /// Eligible conversations the worker has processed (current bundle written)
    /// and that have no claimable job left (the numerator). Not "has a label":
    /// without a Jev key ambiguous threads are processed but stay unlabelled.
    pub done: i64,
    /// Jobs still claimable in the queue.
    pub pending: i64,
    /// Conversation date (RFC3339) of the newest job still to be processed — the
    /// "frontier" the worker is at, since it runs newest-first. `None` when the queue
    /// is drained. Drives the date shown beside the progress label.
    pub current_date: Option<String>,
}

/// Diagnostic breakdown of the triage queue + in-window coverage, for investigating a
/// wedged "Catching up" bar. Logged by the worker each non-idle drain pass — NOT sent to
/// clients. See [`SyncStore::triage_diagnostics`].
pub struct TriageDiagnostics {
    /// Queue rows by status.
    pub q_pending: i64,
    pub q_processing: i64,
    pub q_failed: i64,
    pub q_deferred: i64,
    /// Rows out of attempts (`attempts >= MAX`) — excluded from the claimable set.
    pub poison: i64,
    /// Min/max attempts across the still-claimable set (`min == 0` while stuck ⇒ churn).
    pub min_attempts: i64,
    pub max_attempts: i64,
    /// In-window conversations with no label AND no queue row — the enqueue/backfill gap.
    pub unenqueued_in_window: i64,
}

// ---------------------------------------------------------------------------
// Free functions — operate on an already-locked connection (called from the
// message upsert path, which holds the store lock; the store's own methods
// would deadlock the non-reentrant mutex).
// ---------------------------------------------------------------------------

/// Whether `message_date` (RFC3339) is inside a configured window. `table`/`key`
/// name the settings row; `default` is used when it's missing/garbled. Fails
/// *open* (returns `true`) on a no-bound window, unparseable date, or read error
/// so mail is never silently dropped. `table` is always a hardcoded constant
/// (see callers) — never user input — so interpolating it is injection-safe.
fn within_window(
    conn: &Connection,
    table: &str,
    key: &str,
    default: ProcessingWindow,
    message_date: &str,
) -> bool {
    let window = conn
        .query_row(
            &format!("SELECT value FROM {table} WHERE key = ?1"),
            params![key],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
        .and_then(|s| ProcessingWindow::from_str(&s))
        .unwrap_or(default);

    // `NewOnly` cuts off at the anchor stored beside the window (`<key>_since`).
    let since = conn
        .query_row(
            &format!("SELECT value FROM {table} WHERE key = ?1"),
            params![format!("{key}_since")],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
        .map(|d| d.with_timezone(&Utc));
    let Some(cutoff) = window.cutoff_since(Utc::now(), since) else {
        return true; // Everything → no bound.
    };
    match chrono::DateTime::parse_from_rfc3339(message_date) {
        Ok(dt) => dt.with_timezone(&Utc) >= cutoff,
        Err(_) => true,
    }
}

/// Whether a message dated `message_date` (RFC3339) falls inside the configured
/// triage processing window (`engine_settings.processing_window`, default 1mo).
pub(crate) fn within_processing_window(conn: &Connection, message_date: &str) -> bool {
    within_window(conn, "engine_settings", PROCESSING_WINDOW_KEY, ProcessingWindow::DEFAULT, message_date)
}

/// Whether a new message's conversation gets triaged: the message is inside the
/// processing window, OR the thread is open (in the inbox). The window bounds
/// history only — every thread currently in the inbox is triaged whatever its
/// age. Every other window gate in this file applies the same rule in SQL.
pub(crate) fn triage_eligible(conn: &Connection, conversation_key: &str, message_date: &str) -> bool {
    within_processing_window(conn, message_date)
        || conn
            .query_row(
                "SELECT status = ?2 FROM conversations WHERE key = ?1",
                params![conversation_key, ConversationStatus::Open.as_str()],
                |r| r.get::<_, Option<bool>>(0),
            )
            .ok()
            .flatten()
            .unwrap_or(false)
}

/// Whether a message's date is inside the *embedding* window — a separate,
/// deliberately wider bound than triage's (`vector_settings.embedding_window`,
/// default 1 year), since semantic-search embedding (one on-device inference per
/// message) is the expensive part of syncing a deep archive. Keyword/FTS search
/// is unaffected — it indexes everything regardless.
pub(crate) fn within_embedding_window(conn: &Connection, message_date: &str) -> bool {
    within_window(conn, "vector_settings", EMBEDDING_WINDOW_KEY, EMBEDDING_WINDOW_DEFAULT, message_date)
}

/// Upsert a triage job for a conversation at the given priority (its
/// `updated_at`). Re-enqueue of an existing conversation bumps the priority and
/// resets the row to `pending` in one statement — the re-classification trigger.
pub(crate) fn enqueue_triage_job(
    conn: &Connection,
    conversation_key: &str,
    priority: &str,
) -> rusqlite::Result<()> {
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO ai_triage_queue
           (conversation_key, priority, status, attempts, created_at, updated_at)
         VALUES (?1, ?2, ?4, 0, ?3, ?3)
         ON CONFLICT(conversation_key) DO UPDATE SET
           priority = excluded.priority,
           status = ?4,
           attempts = 0,
           updated_at = excluded.updated_at",
        params![conversation_key, priority, now, TriageStatus::Pending.as_str()],
    )?;
    Ok(())
}

/// High-confidence deterministic classifier for a conversation. Returns a
/// [`TriageLabel`] when the thread carries unambiguous signals, or `None` when it
/// needs the model's judgment. Checked in a priority order that resolves overlaps
/// (e.g. a bill that also has an unsubscribe footer is `action_required`, not
/// `fyi`):
///
/// 1. **payment_due** — bills / invoices / statements / payment / renewal
///    terms (English + Dutch). The owner has to pay.
/// 2. **notification** — a sign-in *code* in the newest inbound message
///    ([`crate::otp::detect`]); outranks "verify your email" below.
/// 3. **action_required** — e-signature requests (DocuSign/HelloSign/Adobe
///    Sign), password resets, account verification. The owner must act.
/// 4. **notification** — a sign-in / magic *link* (after action_required, so a
///    "Verify your account" button stays an action).
/// 5. **scheduling** — calendar invites (inline ICS, "has invited you"),
///    meeting-platform joins, event updates/cancellations, RSVPs, and
///    appointment reminders/confirmations (salon, doctor, service visit —
///    English + Dutch). These are usually automated no-reply mail full of
///    marketing footers, which is why this outranks the fyi signals below.
/// 6. **fyi** — bulk / marketing / newsletter / automated mail, per email-
///    deliverability conventions: unsubscribe / `List-Unsubscribe` footers,
///    view-in-browser / manage-preferences, "you received this because", opt-out,
///    Gmail category tabs, ESP sending domains (Mailchimp/SendGrid/SES/…), `utm_`
///    tracking, ©/no-reply senders. Any STRONG signal, or ≥2 MEDIUM signals.
///
/// All text matching runs in SQLite (`instr`) so the large HTML bodies never leave
/// the DB. The gold-standard `List-Unsubscribe` *header* isn't captured by the
/// sync layer yet — once it is, add it as a strong fyi signal.
/// The outcome of [`detect_label`]: a high-confidence label (or `None` to defer
/// to the model), the deciding rule (`source`), and the raw signals that fired
/// (`signals`, comma-separated) — recorded even when deferring so we can mine
/// "model said X but signals were Y" to tune the rules later.
pub struct ThreadAnalysis {
    pub label: Option<TriageLabel>,
    pub source: &'static str,
    pub signals: String,
}

pub(super) fn detect_label(
    conn: &Connection,
    conversation_key: &str,
    subject: Option<&str>,
) -> Result<ThreadAnalysis> {
    // Granular per-signal flags (each MAX(...) over the thread's messages), so we
    // can both decide the label and record exactly which signals were present.
    let flags: [i64; 14] = conn.query_row(
        "SELECT
           coalesce(MAX(CASE WHEN
             instr(b,'signature requested')>0 OR instr(b,'please sign')>0
             OR instr(b,'sign the document')>0 OR instr(b,'requesting your signature')>0
             OR instr(b,'docusign')>0 OR instr(b,'hellosign')>0 OR instr(b,'adobe sign')>0
             OR instr(b,'adobe acrobat sign')>0
             OR instr(b,'reset your password')>0 OR instr(b,'password reset')>0
             OR instr(b,'verify your account')>0 OR instr(b,'verify your email')>0
             OR instr(b,'confirm your email address')>0
           THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN
             instr(b,'your bill')>0 OR instr(b,'monthly bill')>0 OR instr(b,'bill for account')>0
             OR instr(b,'bill is ready')>0 OR instr(b,'amount due')>0 OR instr(b,'balance due')>0
             OR instr(b,'total due')>0 OR instr(b,'payment due')>0 OR instr(b,'past due')>0
             OR instr(b,'overdue')>0 OR instr(b,'your statement')>0 OR instr(b,'statement is ready')>0
             OR instr(b,'e-bill')>0 OR instr(b,'ebill')>0 OR instr(b,'autopay')>0
             OR instr(b,'make a payment')>0 OR instr(b,'minimum payment')>0 OR instr(b,'invoice')>0
             OR instr(b,'outstanding balance')>0 OR instr(b,'payment failed')>0
             OR instr(b,'payment reminder')>0 OR instr(b,'renew your subscription')>0
             OR instr(b,'subscription will expire')>0 OR instr(b,'subscription has expired')>0
             OR instr(b,'uw rekening')>0 OR instr(b,'te betalen')>0 OR instr(b,'factuur')>0
             OR instr(b,'betalingskenmerk')>0 OR instr(b,'bedrag:')>0
           THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN
             instr(b,'begin:vcalendar')>0 OR instr(b,'begin:vevent')>0 OR instr(b,'dtstart')>0
             OR instr(b,'has invited you')>0 OR instr(b,'you have been invited')>0
             OR instr(b,'invitation from')>0 OR instr(b,'join zoom meeting')>0
             OR instr(b,'microsoft teams meeting')>0 OR instr(b,'join the meeting')>0
             OR instr(b,'meet.google.com')>0 OR instr(b,'event has been updated')>0
             OR instr(b,'event has been canceled')>0 OR instr(b,'event has been cancelled')>0
             OR instr(b,'this event has been')>0
             OR instr(b,'appointment reminder')>0 OR instr(b,'appointment confirmation')>0
             OR instr(b,'appointment confirmed')>0 OR instr(b,'appointment is confirmed')>0
             OR instr(b,'your appointment is')>0 OR instr(b,'your appointment at')>0
             OR instr(b,'your appointment with')>0 OR instr(b,'your upcoming appointment')>0
             OR instr(b,'reminder for your appointment')>0 OR instr(b,'reschedule your appointment')>0
             OR instr(b,'afspraakherinnering')>0 OR instr(b,'afspraakbevestiging')>0
             OR instr(b,'afspraakgegevens')>0
             OR instr(b,'je afspraak bij')>0 OR instr(b,'uw afspraak bij')>0
             OR instr(b,'je afspraak op')>0 OR instr(b,'uw afspraak op')>0
             OR instr(b,'verplaats je afspraak')>0 OR instr(b,'afspraak verzetten')>0
           THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'unsubscribe')>0 OR instr(b,'list-unsubscribe')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'view in browser')>0 OR instr(b,'view this email')>0
             OR instr(b,'view it in your browser')>0 OR instr(b,'view online')>0
             OR instr(b,'view as a web')>0 OR instr(b,'see it in your browser')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'email preferences')>0 OR instr(b,'manage preferences')>0
             OR instr(b,'manage your preferences')>0 OR instr(b,'update your preferences')>0
             OR instr(b,'notification preferences')>0 OR instr(b,'subscription preferences')>0
             OR instr(b,'communication preferences')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'you received this')>0 OR instr(b,'you are receiving this')>0
             OR instr(b,'re receiving this')>0 OR instr(b,'received this email because')>0
             OR instr(b,'because you subscribed')>0 OR instr(b,'because you signed up')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'opt out')>0 OR instr(b,'opt-out')>0
             OR instr(b,'no longer wish to receive')>0 OR instr(b,'stop receiving')>0
             OR instr(b,'manage subscription')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(lbl,'CATEGORY_PROMOTIONS')>0 OR instr(lbl,'CATEGORY_UPDATES')>0
             OR instr(lbl,'CATEGORY_SOCIAL')>0 OR instr(lbl,'CATEGORY_FORUMS')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN
             instr(fm,'mcdlv.net')>0 OR instr(fm,'mcsv.net')>0 OR instr(fm,'sendgrid')>0
             OR instr(fm,'sparkpost')>0 OR instr(fm,'amazonses')>0 OR instr(fm,'mailgun')>0
             OR instr(fm,'mandrillapp')>0 OR instr(fm,'klaviyomail')>0 OR instr(fm,'hubspotemail')>0
             OR instr(fm,'mktomail')>0 OR instr(fm,'rs6.net')>0 OR instr(fm,'createsend')>0
             OR instr(fm,'cmail')>0 OR instr(fm,'sailthru')>0 OR instr(fm,'postmarkapp')>0
             OR instr(fm,'mailjet')>0 OR instr(fm,'sendinblue')>0 OR instr(fm,'exct.net')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'utm_')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'all rights reserved')>0 OR instr(b,'&copy;')>0 OR instr(b,'©')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN
             instr(f,'noreply')>0 OR instr(f,'no-reply')>0 OR instr(f,'no_reply')>0
             OR instr(f,'donotreply')>0 OR instr(f,'do-not-reply')>0
             OR instr(f,'newsletter')>0 OR instr(f,'marketing@')>0 OR instr(f,'mailer')>0
             OR instr(f,'notifications@')>0 OR instr(f,'notification@')>0
             OR instr(f,'updates@')>0 OR instr(f,'news@')>0 OR instr(f,'campaign')>0
             OR instr(f,'digest@')>0 THEN 1 ELSE 0 END),0),
           coalesce(MAX(CASE WHEN instr(b,'add us to your address book')>0 OR instr(b,'add to your address book')>0 OR instr(b,'add this address')>0 THEN 1 ELSE 0 END),0)
         FROM (
           SELECT lower(coalesce(m.body_plain,'') || ' ' || coalesce(m.body_html,'')) AS b,
                  lower(coalesce(m.from_address,'')) AS f,
                  lower(coalesce(m.from_address,'') || ' ' || coalesce(m.message_id_header,'')) AS fm,
                  coalesce(mps.labels,'') AS lbl
           FROM messages m
           LEFT JOIN message_provider_state mps ON mps.message_key = m.key
           WHERE m.conversation_key = ?1
         )",
        params![conversation_key],
        |r| {
            Ok([
                r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?,
                r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?, r.get(10)?, r.get(11)?, r.get(12)?, r.get(13)?,
            ])
        },
    )?;

    let [action, pay, sched_body, s_unsub, s_view, s_prefs, s_recv, s_optout, s_gcat, s_esp, m_utm, m_copy, m_noreply, m_addr] =
        flags;
    let sched_subject = subject_is_scheduling(subject);

    // Record every signal that fired (comma-separated), for later tuning.
    let mut sig: Vec<&str> = Vec::new();
    for (flag, tag) in [
        (action, "action"),
        (pay, "pay"),
        (sched_body, "sched_body"),
        (s_unsub, "unsub"),
        (s_view, "viewbrowser"),
        (s_prefs, "prefs"),
        (s_recv, "recv_because"),
        (s_optout, "optout"),
        (s_gcat, "gmail_cat"),
        (s_esp, "esp"),
        (m_utm, "utm"),
        (m_copy, "copyright"),
        (m_noreply, "noreply"),
        (m_addr, "addrbook"),
    ] {
        if flag != 0 {
            sig.push(tag);
        }
    }
    if sched_subject {
        sig.push("sched_subject");
    }
    // A sign-in code or magic link in the newest message, if someone else sent it.
    let newest: Option<(Option<String>, Option<String>, i64)> = conn
        .query_row(
            "SELECT body_plain, body_html, coalesce(is_inbound,1) FROM messages WHERE conversation_key = ?1
             ORDER BY created_at DESC, key DESC LIMIT 1",
            params![conversation_key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let otp = newest
        .filter(|(_, _, inbound)| *inbound != 0)
        .and_then(|(plain, html, _)| crate::otp::detect(subject, plain.as_deref(), html.as_deref(), None));
    if otp.is_some() {
        sig.push("otp");
    }
    let signals = sig.join(",");

    let strong = s_unsub | s_view | s_prefs | s_recv | s_optout | s_gcat | s_esp;
    let medium_count = m_utm + m_copy + m_noreply + m_addr;

    // Priority order resolves overlaps (a bill with an unsubscribe footer is an
    // action, not marketing).
    // A sign-in code outranks "verify your email" (it is the code mail itself),
    // but not a bill: "log in to pay, reference code 12345678" reads as one.
    let (label, source) = if pay != 0 {
        (Some(TriageLabel::PaymentDue), RULE_PAYMENT)
    } else if matches!(otp, Some(crate::otp::Otp::Code { .. })) {
        (Some(TriageLabel::Notification), "rule:otp")
    } else if action != 0 {
        (Some(TriageLabel::ActionRequired), "rule:action")
    // A sign-in LINK alone doesn't decide the label (newsletters looked like one,
    // 2026-10-20): Jev judges it — `notification` is one of its choices.
    } else if sched_body != 0 {
        (Some(TriageLabel::Scheduling), "rule:scheduling")
    } else if sched_subject {
        (Some(TriageLabel::Scheduling), "rule:scheduling_subject")
    } else if strong != 0 {
        (Some(TriageLabel::Fyi), "rule:marketing_strong")
    } else if medium_count >= 2 {
        (Some(TriageLabel::Fyi), "rule:marketing_medium")
    } else {
        (None, "")
    };

    Ok(ThreadAnalysis { label, source, signals })
}

/// Calendar-invite subject conventions (Google/Microsoft): "Invitation:",
/// "Updated invitation:", "Canceled event:", and RSVP responses "Accepted:" /
/// "Declined:" / "Tentative:" — plus appointment-reminder subjects from booking
/// services (Treatwell-style, English + Dutch).
fn subject_is_scheduling(subject: Option<&str>) -> bool {
    let Some(s) = subject else { return false };
    let s = s.trim().to_lowercase();
    const PREFIXES: [&str; 12] = [
        "invitation:",
        "updated invitation",
        "canceled event",
        "cancelled event",
        "accepted:",
        "declined:",
        "tentative:",
        "new invitation",
        "appointment reminder",
        "appointment confirmation",
        "afspraakherinnering",
        "afspraakbevestiging",
    ];
    PREFIXES.iter().any(|p| s.starts_with(p) || s.contains(p))
}

impl SyncStore {
    // -----------------------------------------------------------------------
    // Engine settings (core-owned key/value)
    // -----------------------------------------------------------------------

    pub fn get_engine_setting(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT value FROM engine_settings WHERE key = ?1",
            params![key],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn set_engine_setting(&self, key: &str, value: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO engine_settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// The configured processing window, defaulting to [`ProcessingWindow::DEFAULT`].
    pub fn processing_window(&self) -> ProcessingWindow {
        self.get_engine_setting(PROCESSING_WINDOW_KEY)
            .ok()
            .flatten()
            .and_then(|s| ProcessingWindow::from_str(&s))
            .unwrap_or(ProcessingWindow::DEFAULT)
    }

    pub fn set_processing_window(&self, window: ProcessingWindow) -> Result<()> {
        // Picking "new mail only" anchors it now; re-picking keeps the anchor so
        // mail that arrived since stays in window.
        if window == ProcessingWindow::NewOnly && self.processing_window() != ProcessingWindow::NewOnly {
            self.set_engine_setting(PROCESSING_WINDOW_SINCE_KEY, &Utc::now().to_rfc3339())?;
        }
        self.set_engine_setting(PROCESSING_WINDOW_KEY, window.as_str())
    }

    /// The window's cutoff as RFC3339 (`None` = Everything). Resolves the
    /// `NewOnly` anchor. Call before taking `self.conn` (it locks internally).
    pub fn processing_cutoff(&self) -> Option<String> {
        let since = self
            .get_engine_setting(PROCESSING_WINDOW_SINCE_KEY)
            .ok()
            .flatten()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(&s).ok())
            .map(|d| d.with_timezone(&Utc));
        self.processing_window()
            .cutoff_since(Utc::now(), since)
            .map(|c| c.to_rfc3339())
    }

    /// Whether the on-device Space classifier (gated TEST path) is enabled.
    /// Off by default — local-channel volume is high, so this is opt-in for
    /// testing classification quality and is meant to be disabled in normal use.
    pub fn space_classify_enabled(&self) -> bool {
        self.get_engine_setting(SPACE_CLASSIFY_ENABLED_KEY)
            .ok()
            .flatten()
            .map(|s| s == "true")
            .unwrap_or(false)
    }

    pub fn set_space_classify_enabled(&self, enabled: bool) -> Result<()> {
        self.set_engine_setting(SPACE_CLASSIFY_ENABLED_KEY, if enabled { "true" } else { "false" })
    }

    /// The org Space taxonomy as pushed — empty when the client hasn't pushed
    /// one. Jev files into [`Self::effective_spaces`], not this alone.
    pub fn space_taxonomy(&self) -> Vec<SpaceDef> {
        self.get_engine_setting(SPACE_TAXONOMY_KEY)
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<Vec<SpaceDef>>(&raw).ok())
            .unwrap_or_default()
    }

    /// Store the org Space taxonomy: `[{slug,name,description,not_for},…]` or the
    /// legacy `[["slug","description"],…]` pairs, stored normalized as objects.
    /// Rejects anything else so a bad push can't silently disable sorting.
    /// Re-files when the effective list changed ([`Self::refile_spaces_if_changed`]);
    /// returns how many threads were queued for that — callers wake the worker.
    pub fn set_space_taxonomy(&self, json: &str) -> Result<usize> {
        let spaces = serde_json::from_str::<Vec<SpaceDef>>(json)
            .map_err(|e| SyncError::Parse(format!("space taxonomy: {e}")))?;
        let normalized = serde_json::to_string(&spaces).map_err(|e| SyncError::Parse(e.to_string()))?;
        self.set_engine_setting(SPACE_TAXONOMY_KEY, &normalized)?;
        self.refile_spaces_if_changed()
    }

    /// This device's personal Spaces (never shown to the team), defaulting to
    /// [`crate::triage::default_personal_spaces`].
    pub fn personal_spaces(&self) -> Vec<SpaceDef> {
        self.get_engine_setting(PERSONAL_SPACES_KEY)
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<Vec<SpaceDef>>(&raw).ok())
            .unwrap_or_else(crate::triage::default_personal_spaces)
    }

    /// Validate ([`crate::triage::validate_personal_spaces`]) and store the
    /// personal Spaces. Re-files exactly like an org taxonomy change. Returns the
    /// list as stored + how many threads were queued for re-filing.
    pub fn set_personal_spaces(&self, spaces: Vec<SpaceDef>) -> Result<(Vec<SpaceDef>, usize)> {
        let spaces = crate::triage::validate_personal_spaces(spaces).map_err(SyncError::Parse)?;
        let json = serde_json::to_string(&spaces).map_err(|e| SyncError::Parse(e.to_string()))?;
        self.set_engine_setting(PERSONAL_SPACES_KEY, &json)?;
        Ok((spaces, self.refile_spaces_if_changed()?))
    }

    /// The Spaces Jev files into: the org's (as pushed), then the personal ones
    /// whose slug doesn't collide with an org Space.
    pub fn effective_spaces(&self) -> Vec<SpaceDef> {
        let mut spaces = self.space_taxonomy();
        for p in self.personal_spaces() {
            if !spaces.iter().any(|s| s.slug == p.slug) {
                spaces.push(p);
            }
        }
        spaces
    }

    /// When the effective Space list differs from the one the stored verdicts were
    /// filed against (a Space added, renamed or re-described, org or personal) —
    /// or no list was ever recorded, which also clears the old LLM classifier's
    /// verdicts (incl. the retired `spam`) — clear every thread's Space so Jev
    /// re-files it. A Space the user placed by hand (`space_manual`) is kept while
    /// its slug is still in the list (or the holding pen); one whose Space is gone
    /// goes back to Jev like the rest. Returns how many eligible threads were
    /// queued for that.
    fn refile_spaces_if_changed(&self) -> Result<usize> {
        let effective = self.effective_spaces();
        let normalized = serde_json::to_string(&effective).map_err(|e| SyncError::Parse(e.to_string()))?;
        if self.get_engine_setting(SPACES_FILED_KEY)?.as_deref() == Some(normalized.as_str()) {
            return Ok(0);
        }
        let mut valid: Vec<&str> = effective.iter().map(|s| s.slug.as_str()).collect();
        valid.push(crate::triage::HOLDING_PEN);
        let valid = serde_json::to_string(&valid).map_err(|e| SyncError::Parse(e.to_string()))?;
        self.conn.lock().execute(
            "UPDATE conversations SET space_slug = NULL, space_manual = 0
             WHERE space_slug IS NOT NULL
               AND (space_manual = 0 OR space_slug NOT IN (SELECT value FROM json_each(?1)))",
            params![valid],
        )?;
        self.set_engine_setting(SPACES_FILED_KEY, &normalized)?;
        if self.space_classify_enabled() && !effective.is_empty() {
            self.backfill_space_queue()
        } else {
            Ok(0)
        }
    }

    /// The triage labels (built-ins + custom), position order. Falls back to the
    /// built-ins when unset/unreadable, and merges in any built-in the stored
    /// list lacks (one added in a later release) — see
    /// [`crate::triage::merge_builtin_labels`].
    pub fn triage_labels(&self) -> Vec<TriageLabelDef> {
        let labels: Vec<TriageLabelDef> = self
            .get_engine_setting(TRIAGE_LABELS_KEY)
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        crate::triage::merge_builtin_labels(labels)
    }

    /// Validate ([`crate::triage::validate_labels`]) and store the label list.
    /// Returns the normalized list as stored.
    pub fn set_triage_labels(&self, labels: Vec<TriageLabelDef>) -> Result<Vec<TriageLabelDef>> {
        let labels = crate::triage::validate_labels(labels).map_err(SyncError::Parse)?;
        self.set_engine_setting(TRIAGE_LABELS_KEY, &serde_json::to_string(&labels).map_err(|e| SyncError::Parse(e.to_string()))?)?;
        Ok(labels)
    }

    /// What one conversation already carries (anchor, label, priority, space) —
    /// the worker's fast-path check: when the anchor still matches the newest
    /// message the summaries are fresh and only missing Jev fields need work.
    /// `None` = unknown conversation.
    pub fn triage_meta(&self, conversation_key: &str) -> Result<Option<TriageMeta>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT ai_meta_msg_key, triage_label, triage_priority, space_slug, triage_source, ai_summary_short,
                    ai_summary_medium, space_manual, label_manual_msg_key
             FROM conversations WHERE key = ?1",
            params![conversation_key],
            |r| {
                Ok(TriageMeta {
                    msg_key: r.get(0)?,
                    label: r.get(1)?,
                    priority: r.get(2)?,
                    space: r.get(3)?,
                    source: r.get(4)?,
                    summary_short: r.get(5)?,
                    summary_medium: r.get(6)?,
                    space_manual: r.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0,
                    label_manual_msg_key: r.get(8)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
    }

    /// A Jev key just arrived: enqueue every processed eligible thread (open, or
    /// inside the window) still missing what Jev fills — no label, no priority, or (when sorting is on)
    /// no space. They take the worker's fast path (one Jev call, summaries
    /// kept). Returns the count enqueued.
    pub fn requeue_for_jev(&self) -> Result<usize> {
        let window_cutoff = self.processing_cutoff();
        let spaces = self.space_classify_enabled() && !self.effective_spaces().is_empty();
        let conn = self.conn.lock();
        let cutoff = window_cutoff;
        let n = conn.execute(
            "INSERT INTO ai_triage_queue
               (conversation_key, priority, status, attempts, created_at, updated_at)
             SELECT c.key, c.updated_at, ?3, 0, ?1, ?1
             FROM conversations c
             WHERE c.ai_meta_msg_key IS NOT NULL
               AND (c.triage_label IS NULL OR c.triage_priority IS NULL
                    OR (?4 AND c.space_slug IS NULL))
               AND (?2 IS NULL OR c.updated_at >= ?2 OR c.status = ?5)
             ON CONFLICT(conversation_key) DO UPDATE SET status = excluded.status,
               attempts = 0, defer_count = 0, updated_at = excluded.updated_at",
            params![
                Utc::now().to_rfc3339(),
                cutoff,
                TriageStatus::Pending.as_str(),
                spaces,
                ConversationStatus::Open.as_str()
            ],
        )?;
        Ok(n)
    }

    /// Enqueue every eligible conversation (open, or inside the window) that has no Space yet — run when
    /// Space classification is switched on, so the already-triaged backlog gets
    /// routed. The worker's fast path skips the label/summary re-run for fresh
    /// threads, so these jobs cost one classify call each, not a full triage.
    pub fn backfill_space_queue(&self) -> Result<usize> {
        let window_cutoff = self.processing_cutoff();
        let conn = self.conn.lock();
        let cutoff = window_cutoff;
        let n = conn.execute(
            "INSERT INTO ai_triage_queue
               (conversation_key, priority, status, attempts, created_at, updated_at)
             SELECT c.key, c.updated_at, ?3, 0, ?1, ?1
             FROM conversations c
             WHERE c.space_slug IS NULL
               AND (?2 IS NULL OR c.updated_at >= ?2 OR c.status = ?4)
             ON CONFLICT(conversation_key) DO NOTHING",
            params![
                Utc::now().to_rfc3339(),
                cutoff,
                TriageStatus::Pending.as_str(),
                ConversationStatus::Open.as_str()
            ],
        )?;
        Ok(n)
    }

    /// Persist the classified Space slug, staleness-checked exactly like
    /// [`Self::write_triage_result`]: if a newer message arrived mid-generation
    /// the write is refused (returns `false`) so the job is reclassified. A
    /// hand-placed Space (`space_manual`) is never overwritten (also `false`).
    pub fn write_space_result(
        &self,
        conversation_key: &str,
        space_slug: &str,
        expected_msg_key: &str,
    ) -> Result<bool> {
        let conn = self.conn.lock();
        if newest_message_key(&conn, conversation_key)?.as_deref() != Some(expected_msg_key) {
            return Ok(false);
        }
        let n = conn.execute(
            "UPDATE conversations SET space_slug = ?2 WHERE key = ?1 AND space_manual = 0",
            params![conversation_key, space_slug],
        )?;
        Ok(n > 0)
    }

    /// Put a thread in a Space by hand (already validated by the caller). It
    /// sticks: re-filing and the worker leave it alone until "Re-run Jev"
    /// ([`Self::clear_manual_triage`]). `false` = unknown conversation.
    pub fn set_manual_space(&self, conversation_key: &str, space_slug: &str) -> Result<bool> {
        let n = self.conn.lock().execute(
            "UPDATE conversations SET space_slug = ?2, space_manual = 1 WHERE key = ?1",
            params![conversation_key, space_slug],
        )?;
        Ok(n > 0)
    }

    /// Set a thread's label by hand (already validated by the caller):
    /// `triage_source` = [`crate::triage::MANUAL_SOURCE`], anchored to the
    /// thread's newest message so the worker keeps it until new mail arrives.
    /// Priority and summaries are untouched. `false` = unknown conversation or
    /// one with no messages.
    pub fn set_manual_label(&self, conversation_key: &str, label: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let Some(anchor) = newest_message_key(&conn, conversation_key)? else {
            return Ok(false);
        };
        let n = conn.execute(
            "UPDATE conversations SET triage_label = ?2, triage_source = ?3, label_manual_msg_key = ?4
             WHERE key = ?1",
            params![conversation_key, label, crate::triage::MANUAL_SOURCE, anchor],
        )?;
        super::lore_triage::refresh_next_action(&conn, conversation_key)?;
        Ok(n > 0)
    }

    /// Drop both manual marks ("Re-run Jev": the user asks Jev again, so its
    /// answer may replace the hand-picked label and Space).
    pub fn clear_manual_triage(&self, conversation_key: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE conversations SET space_manual = 0, label_manual_msg_key = NULL WHERE key = ?1",
            params![conversation_key],
        )?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Triage work queue
    // -----------------------------------------------------------------------

    /// Claim the highest-priority job (newest conversation first), marking it
    /// `processing`. Also reclaims a stale `processing` row whose worker died.
    /// Returns the conversation key, or `None` when the queue is empty.
    pub fn claim_next_triage_job(&self) -> Result<Option<String>> {
        // Only claim eligible jobs — inside the processing window, or on an open
        // (inbox) thread: narrowing the window leaves older queued jobs parked
        // (they resume if it's widened again) instead of spending Jev calls on a
        // backlog the user opted out of; archiving an old thread parks its job too.
        // ponytail: parked rows are skipped one PK lookup each while scanning in
        // priority order; fine at inbox scale, prune parked rows if it ever shows.
        let window_cutoff = self.processing_cutoff();
        let conn = self.conn.lock();
        let stale =
            (Utc::now() - chrono::Duration::seconds(TRIAGE_STALE_PROCESSING_SECS)).to_rfc3339();
        let fail_cutoff =
            (Utc::now() - chrono::Duration::seconds(TRIAGE_FAIL_BACKOFF_SECS)).to_rfc3339();
        // Claimable: a fresh `pending` row, a `failed` row whose backoff has elapsed (so a
        // failing thread is skipped and retried later rather than blocking the queue head),
        // or a stale `processing` row whose worker died. ALL branches are bounded by
        // `attempts < MAX` — including `processing`, so a job that never completes (e.g. the
        // app is suspended mid-generation every time, which never records a failure) can't
        // be reclaimed forever; it marches to the attempt cap and drops out instead of
        // wedging the "Catching up" bar at a partial count.
        let next: Option<(String, String)> = conn
            .query_row(
                "SELECT q.conversation_key, q.status FROM ai_triage_queue q
                 WHERE q.attempts < ?1
                   AND (q.status = ?3
                        OR (q.status = ?4 AND q.updated_at <= ?6)
                        OR (q.status = ?5 AND q.updated_at <= ?2))
                   AND (?7 IS NULL OR q.priority >= ?7
                        OR EXISTS (SELECT 1 FROM conversations c
                                   WHERE c.key = q.conversation_key AND c.status = ?8))
                 ORDER BY q.priority DESC
                 LIMIT 1",
                params![
                    TRIAGE_MAX_ATTEMPTS,
                    stale,
                    TriageStatus::Pending.as_str(),
                    TriageStatus::Failed.as_str(),
                    TriageStatus::Processing.as_str(),
                    fail_cutoff,
                    window_cutoff,
                    ConversationStatus::Open.as_str()
                ],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((ref key, ref status)) = next {
            // Reclaiming a stale `processing` row means its previous attempt was lost
            // without recording a failure (the worker died), so charge it an attempt.
            // That's what lets a perpetually-dying job reach `attempts == MAX` and
            // become poison instead of looping. A fresh claim isn't charged here —
            // `fail_triage_job` counts genuine generation failures.
            let reclaim = status == TriageStatus::Processing.as_str();
            conn.execute(
                "UPDATE ai_triage_queue
                 SET status = ?3, updated_at = ?2, attempts = attempts + ?4
                 WHERE conversation_key = ?1",
                params![
                    key,
                    Utc::now().to_rfc3339(),
                    TriageStatus::Processing.as_str(),
                    i64::from(reclaim)
                ],
            )?;
        }
        Ok(next.map(|(k, _)| k))
    }

    /// Finish a job successfully — but only if it's still `processing`. If a new
    /// message re-enqueued it (back to `pending`) mid-generation, the delete
    /// no-ops so the fresher job survives. Returns whether a row was removed.
    pub fn complete_triage_job(&self, conversation_key: &str) -> Result<bool> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "DELETE FROM ai_triage_queue WHERE conversation_key = ?1 AND status = ?2",
            params![conversation_key, TriageStatus::Processing.as_str()],
        )?;
        Ok(n > 0)
    }

    /// Hand a claimed job back untouched (Jev is paused — credits, billing): it
    /// goes back to `pending` with no attempt or defer charged, so an outage of
    /// any length never pushes a thread toward the poison fallback.
    pub fn release_triage_job(&self, conversation_key: &str) -> Result<()> {
        self.conn.lock().execute(
            "UPDATE ai_triage_queue SET status = ?2 WHERE conversation_key = ?1 AND status = ?3",
            params![conversation_key, TriageStatus::Pending.as_str(), TriageStatus::Processing.as_str()],
        )?;
        Ok(())
    }

    /// Park an ambiguous job that can't be classified without a model. `deferred`
    /// rows are excluded from `claim_next_triage_job`, so the worker doesn't spin
    /// on them; [`reactivate_deferred_triage`](Self::reactivate_deferred_triage)
    /// re-queues them once a model is configured.
    pub fn defer_triage_job(&self, conversation_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE ai_triage_queue SET status = ?3, defer_count = defer_count + 1, updated_at = ?2
             WHERE conversation_key = ?1 AND status = ?4",
            params![
                conversation_key,
                Utc::now().to_rfc3339(),
                TriageStatus::Deferred.as_str(),
                TriageStatus::Processing.as_str()
            ],
        )?;
        Ok(())
    }

    /// Re-queue deferred jobs (a model just became available), except those past
    /// `TRIAGE_MAX_DEFERS` — a thread that keeps re-deferring (model reports ready but
    /// errors "unavailable" on it every time) is left parked for `finalize_exhausted` to
    /// poison-label, so it can't loop defer→reactivate forever. Returns count.
    pub fn reactivate_deferred_triage(&self) -> Result<usize> {
        let conn = self.conn.lock();
        // Only reactivate jobs deferred more than the backoff ago — so a model that reports
        // "available" but errors on every call (Apple Intelligence `assetsUnavailable` while
        // assets download) retries on a sane cadence instead of every drain tick.
        let cutoff =
            (Utc::now() - chrono::Duration::seconds(TRIAGE_DEFER_BACKOFF_SECS)).to_rfc3339();
        let n = conn.execute(
            "UPDATE ai_triage_queue SET status = ?2, updated_at = ?1
             WHERE status = ?3 AND updated_at <= ?4 AND defer_count < ?5",
            params![
                Utc::now().to_rfc3339(),
                TriageStatus::Pending.as_str(),
                TriageStatus::Deferred.as_str(),
                cutoff,
                TRIAGE_MAX_DEFERS,
            ],
        )?;
        Ok(n)
    }

    /// One-shot recovery, run once when a usable model first appears: re-queue `failed`
    /// jobs whose error was the model being *unavailable* — they were really deferrals
    /// misfiled as failures by the optimistic `isAvailable()` (the worker tried, then
    /// the lane reported "Model is unavailable"). Reset their attempts for a fresh try.
    ///
    /// This MUST NOT run every pass: a thread the model still can't handle would loop
    /// reactivate → re-fail → reactivate forever, both wasting cycles and keeping the
    /// progress bar from ever completing. Genuine poison (unparseable output, a
    /// generation timeout) doesn't match the error filter, so it stays `failed` and is
    /// excluded from the bar. Returns count re-queued.
    pub fn reactivate_unavailable_failures(&self) -> Result<usize> {
        let conn = self.conn.lock();
        let n = conn.execute(
            "UPDATE ai_triage_queue SET status = ?2, attempts = 0, updated_at = ?1
             WHERE status = ?3 AND (
                  error_message LIKE '%unavailable%'
               OR error_message LIKE '%no on-device generator%'
               OR error_message LIKE '%no OpenAI key%')",
            params![
                Utc::now().to_rfc3339(),
                TriageStatus::Pending.as_str(),
                TriageStatus::Failed.as_str(),
            ],
        )?;
        Ok(n)
    }

    /// Conversation keys whose triage job is exhausted — out of `attempts` (genuine
    /// failures) or past `TRIAGE_MAX_DEFERS` (always reports the model unavailable) — but
    /// which still have no label. The worker writes a deterministic fallback label so they stop
    /// holding the "Catching up" bar short of 100% forever (a thread the model can't parse,
    /// times out on, or rejects for locale never gets classified otherwise). See
    /// [`crate::ai_worker::TriageWorker::finalize_exhausted`].
    pub fn exhausted_unlabeled_triage_keys(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT q.conversation_key FROM ai_triage_queue q
             JOIN conversations c ON c.key = q.conversation_key
             WHERE c.triage_label IS NULL AND (q.attempts >= ?1 OR q.defer_count >= ?2)",
        )?;
        let rows = stmt
            .query_map(params![TRIAGE_MAX_ATTEMPTS, TRIAGE_MAX_DEFERS], |r| r.get(0))?
            .collect::<std::result::Result<Vec<String>, _>>()?;
        Ok(rows)
    }

    /// Remove a queue row outright — used after an exhausted job has been given its
    /// deterministic fallback label, so it leaves the queue for good.
    pub fn delete_triage_job(&self, conversation_key: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM ai_triage_queue WHERE conversation_key = ?1",
            params![conversation_key],
        )?;
        Ok(())
    }

    /// Mark a job failed (+1 attempt), unless it was re-enqueued mid-generation.
    pub fn fail_triage_job(&self, conversation_key: &str, error: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE ai_triage_queue
             SET status = ?4, attempts = attempts + 1, error_message = ?2, updated_at = ?3
             WHERE conversation_key = ?1 AND status = ?5",
            params![
                conversation_key,
                error,
                Utc::now().to_rfc3339(),
                TriageStatus::Failed.as_str(),
                TriageStatus::Processing.as_str()
            ],
        )?;
        Ok(())
    }

    /// One-time repair of the summaries written before the worker asked the model
    /// for marketing/fyi threads: those were the SUBJECT verbatim, which is useless
    /// as a list preview. Clearing the staleness anchor makes them look untriaged,
    /// so the backfill below re-enqueues them and the worker regenerates a real
    /// summary. Marker-gated — without it a model-less run would rewrite the same
    /// echo and re-clear it on every backfill, forever.
    fn clear_echo_summaries(&self) -> Result<()> {
        const MARKER: &str = "echo_summaries_cleared";
        if self.get_engine_setting(MARKER)?.is_some() {
            return Ok(());
        }
        let n = self.conn.lock().execute(
            // The echo is `truncate(subject, 90)`, so a long subject's copy ends in an
            // ellipsis — compare against the same-length prefix rather than the whole
            // subject. `fallback:*` rows are the exhausted-poison threads; re-running
            // them only burns attempts again.
            "UPDATE conversations SET ai_meta_msg_key = NULL
             WHERE ai_summary_short IS NOT NULL
               AND ifnull(triage_source, '') NOT LIKE 'fallback:%'
               AND substr(subject, 1, length(rtrim(ai_summary_short, '…')))
                     = rtrim(ai_summary_short, '…')",
            [],
        )?;
        self.set_engine_setting(MARKER, "1")?;
        if n > 0 {
            log::info!("[triage] cleared {n} subject-echo summaries for regeneration");
        }
        Ok(())
    }

    /// Enqueue eligible conversations (open, or inside the window) that have never been processed
    /// (`ai_meta_msg_key IS NULL`), newest first. Called after the user widens
    /// the window so newly-eligible backlog gets picked up. Returns the count
    /// enqueued.
    pub fn backfill_triage_queue(&self) -> Result<usize> {
        let window_cutoff = self.processing_cutoff();
        self.clear_echo_summaries()?;
        let conn = self.conn.lock();
        let cutoff = window_cutoff;
        // `cutoff IS NULL` (Everything) selects all; otherwise in window or open.
        let n = conn.execute(
            "INSERT INTO ai_triage_queue
               (conversation_key, priority, status, attempts, created_at, updated_at)
             SELECT c.key, c.updated_at, ?3, 0, ?1, ?1
             FROM conversations c
             WHERE c.ai_meta_msg_key IS NULL
               AND (?2 IS NULL OR c.updated_at >= ?2 OR c.status = ?4)
             ON CONFLICT(conversation_key) DO NOTHING",
            params![
                Utc::now().to_rfc3339(),
                cutoff,
                TriageStatus::Pending.as_str(),
                ConversationStatus::Open.as_str()
            ],
        )?;
        Ok(n)
    }

    /// Progress snapshot for the clients' progress bar.
    pub fn triage_progress(&self) -> Result<TriageProgress> {
        let window_cutoff = self.processing_cutoff();
        let conn = self.conn.lock();
        let cutoff = window_cutoff;
        let open = ConversationStatus::Open.as_str();
        // "In window" = eligible: inside the window or open (the inbox is always
        // triaged). Every count below uses the same set.
        let in_window: i64 = conn.query_row(
            "SELECT COUNT(*) FROM conversations WHERE (?1 IS NULL OR updated_at >= ?1 OR status = ?2)",
            params![cutoff, open],
            |r| r.get(0),
        )?;
        let done: i64 = conn.query_row(
            "SELECT COUNT(*) FROM conversations c
             WHERE c.ai_meta_msg_key IS NOT NULL AND (?1 IS NULL OR c.updated_at >= ?1 OR c.status = ?6)
               AND NOT EXISTS (SELECT 1 FROM ai_triage_queue q
                               WHERE q.conversation_key = c.key
                                 AND q.status IN (?2, ?3, ?4) AND q.attempts < ?5)",
            params![
                cutoff,
                TriageStatus::Pending.as_str(),
                TriageStatus::Processing.as_str(),
                TriageStatus::Failed.as_str(),
                TRIAGE_MAX_ATTEMPTS,
                open,
            ],
            |r| r.get(0),
        )?;
        // Count only *claimable, IN-WINDOW* work — the bar reports catch-up over the
        // processing window (its `done`/`in_window` are window-scoped), so `pending` must
        // be too. Out-of-window queue rows (older mail synced in, or a thread whose date
        // fell out of the window) still get drained by the worker, but they must NOT keep
        // the "Catching up" bar visible after the window itself is caught up (`isActive`
        // is `pending > 0`). `attempts < MAX` is load-bearing: a row stuck in `processing`
        // (worker killed mid-generation) must drop out once exhausted, else it wedges the
        // bar at a partial count. Exhausted poison (attempts == MAX) drops out too.
        let pending: i64 = conn.query_row(
            "SELECT COUNT(*) FROM ai_triage_queue q
             JOIN conversations c ON c.key = q.conversation_key
             WHERE q.status IN (?1, ?2, ?3) AND q.attempts < ?4
               AND (?5 IS NULL OR c.updated_at >= ?5 OR c.status = ?6)",
            params![
                TriageStatus::Pending.as_str(),
                TriageStatus::Processing.as_str(),
                TriageStatus::Failed.as_str(),
                TRIAGE_MAX_ATTEMPTS,
                cutoff,
                open,
            ],
            |r| r.get(0),
        )?;
        // The newest still-claimable IN-WINDOW job's date — the frontier the worker is at
        // (newest-first), or NULL when the window is drained. Same set as `pending`.
        let current_date: Option<String> = conn.query_row(
            "SELECT MAX(q.priority) FROM ai_triage_queue q
             JOIN conversations c ON c.key = q.conversation_key
             WHERE q.status IN (?1, ?2, ?3) AND q.attempts < ?4
               AND (?5 IS NULL OR c.updated_at >= ?5 OR c.status = ?6)",
            params![
                TriageStatus::Pending.as_str(),
                TriageStatus::Processing.as_str(),
                TriageStatus::Failed.as_str(),
                TRIAGE_MAX_ATTEMPTS,
                cutoff,
                open,
            ],
            |r| r.get(0),
        )?;
        Ok(TriageProgress { in_window, done, pending, current_date })
    }

    /// Full queue + coverage breakdown for diagnosing a wedged "Catching up" bar.
    /// Logged once per non-idle drain pass (see [`crate::ai_worker::TriageWorker`]).
    /// The smoking guns this separates:
    ///   - `q_processing` high + `done` frozen → jobs claimed but never completing
    ///     (a `Stale` cycle: see the STALE log in `write_triage_result`).
    ///   - `poison` rising → genuine generation failures parking out (the bar will
    ///     finish below 100%).
    ///   - `unenqueued_in_window` > 0 with low `pending` → in-window mail that never
    ///     got a queue row (a backfill/enqueue gap), so `done` can't reach `in_window`.
    ///   - `min_attempts == 0` while `done` is high and stuck → re-enqueue churn
    ///     (something keeps resetting `attempts`, so jobs never poison out).
    pub fn triage_diagnostics(&self) -> Result<TriageDiagnostics> {
        let window_cutoff = self.processing_cutoff();
        let conn = self.conn.lock();
        let cutoff = window_cutoff;

        let status_count = |status: &str| -> Result<i64> {
            Ok(conn.query_row(
                "SELECT COUNT(*) FROM ai_triage_queue WHERE status = ?1",
                params![status],
                |r| r.get(0),
            )?)
        };
        let q_pending = status_count(TriageStatus::Pending.as_str())?;
        let q_processing = status_count(TriageStatus::Processing.as_str())?;
        let q_failed = status_count(TriageStatus::Failed.as_str())?;
        let q_deferred = status_count(TriageStatus::Deferred.as_str())?;
        // Poison: rows the claimer skips because they're out of attempts.
        let poison: i64 = conn.query_row(
            "SELECT COUNT(*) FROM ai_triage_queue WHERE attempts >= ?1",
            params![TRIAGE_MAX_ATTEMPTS],
            |r| r.get(0),
        )?;
        // Attempts spread over the still-claimable set — `min==0` while the bar is
        // stuck is the re-enqueue-churn tell (attempts keep getting reset).
        let (min_attempts, max_attempts): (i64, i64) = conn
            .query_row(
                "SELECT COALESCE(MIN(attempts), 0), COALESCE(MAX(attempts), 0)
                 FROM ai_triage_queue
                 WHERE status IN (?1, ?2, ?3) AND attempts < ?4",
                params![
                    TriageStatus::Pending.as_str(),
                    TriageStatus::Processing.as_str(),
                    TriageStatus::Failed.as_str(),
                    TRIAGE_MAX_ATTEMPTS,
                ],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .unwrap_or((0, 0));
        // In-window conversations never processed AND with no queue row at all — the
        // enqueue/backfill gap (these never reach the worker, so `done` can't catch up).
        let unenqueued_in_window: i64 = conn.query_row(
            "SELECT COUNT(*) FROM conversations c
             WHERE (?1 IS NULL OR c.updated_at >= ?1 OR c.status = ?2)
               AND c.ai_meta_msg_key IS NULL
               AND NOT EXISTS (SELECT 1 FROM ai_triage_queue q WHERE q.conversation_key = c.key)",
            params![cutoff, ConversationStatus::Open.as_str()],
            |r| r.get(0),
        )?;

        Ok(TriageDiagnostics {
            q_pending,
            q_processing,
            q_failed,
            q_deferred,
            poison,
            min_attempts,
            max_attempts,
            unenqueued_in_window,
        })
    }

    // -----------------------------------------------------------------------
    // Thread read + result write (used by the worker)
    // -----------------------------------------------------------------------

    /// Assemble the thread text + staleness anchor for a conversation, or `None`
    /// if it has no messages (e.g. deleted between enqueue and processing).
    pub fn conversation_triage_input(&self, conversation_key: &str) -> Result<Option<TriageInput>> {
        let conn = self.conn.lock();
        let subject: Option<String> = conn
            .query_row(
                "SELECT subject FROM conversations WHERE key = ?1",
                params![conversation_key],
                |r| r.get(0),
            )
            .optional()?
            .flatten();

        // Most recent messages, newest first; we reverse to chronological for the
        // prompt and take the newest's key as the staleness anchor. is_inbound lets
        // us label direction so the model can tell needs_answer (they wrote last)
        // from waiting_reply (the owner wrote last).
        //
        // The `key DESC` tiebreaker is load-bearing: messages can share a
        // `created_at` (second-granularity provider timestamps, bulk imports), and
        // `write_triage_result` recomputes the newest key with the IDENTICAL order.
        // Without a deterministic tiebreaker the two queries can pick different
        // messages for a tie, so every write looks stale (wrote=false) and the job
        // loops forever as `Outcome::Stale` — wedging the "Catching up" bar.
        let mut stmt = conn.prepare(
            "SELECT key, from_address, body_plain, is_inbound, created_at FROM messages
             WHERE conversation_key = ?1
             ORDER BY created_at DESC, key DESC
             LIMIT ?2",
        )?;
        let rows: Vec<(String, Option<String>, Option<String>, i64, Option<String>)> = stmt
            .query_map(params![conversation_key, TRIAGE_THREAD_MESSAGES as i64], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get::<_, i64>(3)?, r.get(4)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let Some((newest_msg_key, newest_at)) = rows.first().map(|r| (r.0.clone(), r.4.clone())) else {
            return Ok(None);
        };

        // A ghost shell (provider sync artifact): no subject and not one message
        // with a sender or body. There is nothing to classify — labeling it makes
        // the Bridge brief announce phantom mail. Drop it like an orphan job.
        let has_content = subject.as_deref().is_some_and(|s| !s.trim().is_empty())
            || rows.iter().any(|(_, from, body, _, _)| {
                from.as_deref().is_some_and(|s| !s.trim().is_empty())
                    || body.as_deref().is_some_and(|s| !s.trim().is_empty())
            });
        if !has_content {
            return Ok(None);
        }

        // The thread's mailbox (the Jev `owner`): the account any of its messages came through.
        let owner: String = conn
            .query_row(
                "SELECT a.email_address FROM messages m JOIN external_accounts a ON a.key = m.account_key
                 WHERE m.conversation_key = ?1 LIMIT 1",
                params![conversation_key],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default();

        let mut thread_text = String::new();
        let mut messages = Vec::with_capacity(rows.len());
        for (_, from, body, is_inbound, _) in rows.iter().rev() {
            let from = from.as_deref().unwrap_or("(unknown)");
            // Strip each message's quoted/forwarded trailer: every earlier message is
            // already its own row here, so the quoted copy is redundant — and keeping it
            // makes summaries (and the spoken read-out built from them) parrot the prior
            // thread or a forwarded block instead of the new message. A bare forward strips
            // to empty, leaving only the subject/sender as context.
            let body = crate::quotes::strip_quoted_text(body.as_deref().unwrap_or(""));
            let body: String = body.chars().take(TRIAGE_BODY_CHARS).collect();
            // Direction from the inbox owner's perspective.
            if *is_inbound == 0 {
                thread_text.push_str("From the owner (sent): ");
            } else {
                thread_text.push_str("From ");
                thread_text.push_str(from);
                thread_text.push_str(" (received): ");
            }
            thread_text.push('\n');
            thread_text.push_str(body.trim());
            thread_text.push_str("\n\n");
            messages.push(JevMessage {
                direction: if *is_inbound == 0 { "sent" } else { "received" }.to_string(),
                from: from.to_string(),
                text: body.trim().to_string(),
            });
        }

        let analysis = detect_label(&conn, conversation_key, subject.as_deref())?;
        Ok(Some(TriageInput {
            subject,
            thread_text,
            newest_msg_key,
            newest_at,
            deterministic: analysis.label,
            det_source: analysis.source,
            signals: analysis.signals,
            owner,
            messages,
        }))
    }

    /// Seed one fixture thread for the triage eval harness ([`crate::triage_eval`])
    /// into an (ephemeral) store, so [`conversation_triage_input`] — and with it the
    /// deterministic `detect_label` SQL — runs over fixture mail exactly as it does
    /// over synced mail. Messages get sequential `created_at` stamps in array order
    /// (oldest first), matching how a real thread accretes.
    pub fn seed_eval_thread(
        &self,
        conversation_key: &str,
        subject: Option<&str>,
        messages: &[EvalSeedMessage<'_>],
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO conversations (key, organization_id, subject, updated_at)
             VALUES (?1, 'eval', ?2, '2024-01-01T00:00:00+00:00')",
            params![conversation_key, subject],
        )?;
        for (i, m) in messages.iter().enumerate() {
            let created = format!("2024-01-01T00:00:{:02}+00:00", i.min(59));
            conn.execute(
                "INSERT INTO messages
                   (key, conversation_key, organization_id, from_address, message_id_header,
                    body_plain, body_html, is_inbound, created_at)
                 VALUES (?1, ?2, 'eval', ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    format!("{conversation_key}_m{i}"),
                    conversation_key,
                    m.from,
                    m.message_id_header,
                    m.body_plain,
                    m.body_html,
                    if m.sent_by_owner { 0 } else { 1 },
                    created,
                ],
            )?;
        }
        Ok(())
    }

    /// Build an eval-harness case ([`crate::triage_eval::EvalCase`]) from a REAL
    /// conversation — the Triage Lab's "add a message from my mail" path. Reads
    /// the same last-8-messages window the worker classifies, oldest first.
    /// Plain bodies are capped like the worker's prompt; HTML keeps a generous
    /// cap so end-of-body footer signals (unsubscribe links) survive for the
    /// deterministic rules. `expected` is left empty for the user to fill.
    pub fn eval_case_for_conversation(
        &self,
        conversation_key: &str,
    ) -> Result<Option<crate::triage_eval::EvalCase>> {
        let conn = self.conn.lock();
        let subject: Option<String> = conn
            .query_row(
                "SELECT subject FROM conversations WHERE key = ?1",
                params![conversation_key],
                |r| r.get(0),
            )
            .optional()?
            .flatten();

        let mut stmt = conn.prepare(
            "SELECT from_address, message_id_header, body_plain, body_html, is_inbound
             FROM messages WHERE conversation_key = ?1
             ORDER BY created_at DESC LIMIT ?2",
        )?;
        let mut rows: Vec<crate::triage_eval::EvalMessage> = stmt
            .query_map(params![conversation_key, TRIAGE_THREAD_MESSAGES as i64], |r| {
                let cap = |s: Option<String>, max: usize| {
                    s.map(|s| s.chars().take(max).collect::<String>()).filter(|s| !s.is_empty())
                };
                Ok(crate::triage_eval::EvalMessage {
                    from: r.get::<_, Option<String>>(0)?,
                    message_id: r.get::<_, Option<String>>(1)?,
                    body: cap(r.get::<_, Option<String>>(2)?, TRIAGE_BODY_CHARS).unwrap_or_default(),
                    html: cap(r.get::<_, Option<String>>(3)?, 8000),
                    sent_by_owner: r.get::<_, i64>(4)? == 0,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        if rows.is_empty() {
            return Ok(None);
        }
        rows.reverse(); // chronological, oldest first — the fixture order

        // A readable, unique-ish case name from the subject.
        let slug: String = subject
            .as_deref()
            .unwrap_or(conversation_key)
            .to_lowercase()
            .chars()
            .map(|c| if c.is_alphanumeric() { c } else { '-' })
            .collect::<String>()
            .split('-')
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("-")
            .chars()
            .take(40)
            .collect();

        Ok(Some(crate::triage_eval::EvalCase {
            name: if slug.is_empty() { conversation_key.to_string() } else { slug },
            subject,
            expected: None,
            messages: rows,
        }))
    }

    /// Write the triage label (a built-in or custom slug; `None` = unlabelled),
    /// priority + medium/short summaries, but only if the conversation's newest
    /// message is still `expected_msg_key` (compare-and-set staleness guard — a
    /// message that arrived mid-generation makes the result stale and the row is
    /// left for reprocessing). Returns whether it wrote.
    #[allow(clippy::too_many_arguments)]
    pub fn write_triage_result(
        &self,
        conversation_key: &str,
        label: Option<&str>,
        priority: Option<f64>,
        medium: &str,
        short: &str,
        expected_msg_key: &str,
        source: &str,
        signals: &str,
    ) -> Result<bool> {
        let conn = self.conn.lock();
        let current_newest = newest_message_key(&conn, conversation_key)?;
        if current_newest.as_deref() != Some(expected_msg_key) {
            // The result is for a message that's no longer the thread's newest. Normally a
            // genuinely newer message arrived mid-generation (the upsert re-enqueued the
            // job → it reruns against the new newest). But if this repeats for the SAME
            // conversation across passes WITHOUT the newest actually changing, it's a
            // staleness false-fail that wedges the bar — this log is how we tell them apart.
            log::info!(
                "[triage] {conversation_key}: STALE write — expected newest={expected_msg_key} current={current_newest:?}; label NOT written"
            );
            return Ok(false);
        }
        conn.execute(
            "UPDATE conversations
             SET triage_label = ?2, ai_summary_medium = ?3, ai_summary_short = ?4,
                 ai_meta_msg_key = ?5, triage_source = ?6, triage_signals = ?7, triage_priority = ?8
             WHERE key = ?1",
            params![conversation_key, label, medium, short, expected_msg_key, source, signals, priority],
        )?;
        super::lore_triage::refresh_next_action(&conn, conversation_key)?;
        Ok(true)
    }

    /// Fill in Jev fields on a thread whose summaries are already current (the
    /// worker's fast path after a key arrives): `label`/`priority` only replace
    /// when `Some`. Staleness-checked like [`Self::write_triage_result`].
    pub fn write_jev_fill(
        &self,
        conversation_key: &str,
        label: Option<&str>,
        priority: Option<f64>,
        expected_msg_key: &str,
        source: &str,
    ) -> Result<bool> {
        let conn = self.conn.lock();
        if newest_message_key(&conn, conversation_key)?.as_deref() != Some(expected_msg_key) {
            return Ok(false);
        }
        conn.execute(
            "UPDATE conversations
             SET triage_label = COALESCE(?2, triage_label), triage_priority = COALESCE(?3, triage_priority),
                 triage_source = ?4
             WHERE key = ?1",
            params![conversation_key, label, priority, source],
        )?;
        super::lore_triage::refresh_next_action(&conn, conversation_key)?;
        Ok(true)
    }

    /// The meeting JSON the summary lane found in this message's thread, if any
    /// (docs/Meeting-Invites.md "Detected meetings").
    pub fn detected_meeting(&self, message_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        Ok(conn
            .query_row("SELECT detected_meeting FROM messages WHERE key = ?1", params![message_key], |r| r.get(0))
            .optional()?
            .flatten())
    }

    /// Record (or clear, with `None`) the detected meeting on the message the
    /// summary was written for.
    pub fn write_detected_meeting(&self, message_key: &str, json: Option<&str>) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE messages SET detected_meeting = ?2 WHERE key = ?1 AND detected_meeting IS NOT ?2",
            params![message_key, json],
        )?;
        Ok(())
    }

    /// Record (or clear, with `None`) the Lore to-do title the summary lane wrote
    /// (docs/Triage.md "Next-action fields").
    pub fn write_next_action_title(&self, conversation_key: &str, title: Option<&str>) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE conversations SET next_action_title = ?2 WHERE key = ?1 AND next_action_title IS NOT ?2",
            params![conversation_key, title],
        )?;
        Ok(())
    }
}

/// The thread's newest message key. Must match `conversation_triage_input`'s
/// ordering EXACTLY (including the `key DESC` tiebreaker) so a tie on
/// `created_at` resolves to the same message in both places — otherwise every
/// staleness check false-fails and the job loops forever as `Outcome::Stale`,
/// wedging the progress bar.
fn newest_message_key(conn: &Connection, conversation_key: &str) -> Result<Option<String>> {
    conn.query_row(
        "SELECT key FROM messages WHERE conversation_key = ?1
         ORDER BY created_at DESC, key DESC LIMIT 1",
        params![conversation_key],
        |r| r.get(0),
    )
    .optional()
    .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::model::ProviderType;

    fn store() -> SyncStore {
        SyncStore::new_in_memory().unwrap()
    }

    #[test]
    fn processing_window_defaults_and_persists() {
        let s = store();
        // Default seeded by the schema.
        assert_eq!(s.processing_window(), ProcessingWindow::LastMonth);
        s.set_processing_window(ProcessingWindow::OneYear).unwrap();
        assert_eq!(s.processing_window(), ProcessingWindow::OneYear);
    }

    #[test]
    fn within_window_gates_by_date() {
        let s = store();
        s.set_processing_window(ProcessingWindow::LastMonth).unwrap();
        let conn = s.conn.lock();
        let recent = Utc::now().to_rfc3339();
        let old = (Utc::now() - chrono::Duration::days(200)).to_rfc3339();
        assert!(within_processing_window(&conn, &recent));
        assert!(!within_processing_window(&conn, &old));
        drop(conn);
        // Everything → even very old mail is in-window.
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        let conn = s.conn.lock();
        assert!(within_processing_window(&conn, &old));
    }

    #[test]
    fn embedding_window_defaults_to_one_year_and_is_independent_of_triage() {
        let s = store();
        let conn = s.conn.lock();
        // Schema seeds embedding_window='1_year' (wider than the 1-month triage
        // default), so ~6-month-old mail is embedded even though triage skips it.
        let six_months = (Utc::now() - chrono::Duration::days(182)).to_rfc3339();
        let two_years = (Utc::now() - chrono::Duration::days(730)).to_rfc3339();
        assert!(within_embedding_window(&conn, &six_months));
        assert!(!within_embedding_window(&conn, &two_years));
        // Triage's narrower default window excludes the same 6-month-old mail.
        assert!(!within_processing_window(&conn, &six_months));
    }

    #[test]
    fn queue_claim_complete_and_priority_order() {
        let s = store();
        // Window-independent queue mechanics — pin to Everything so `pending` (now
        // in-window-scoped) counts these old-dated fixtures.
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        // Seed two conversations directly (the message path is covered elsewhere).
        {
            let conn = s.conn.lock();
            for (k, updated) in [("conv_old", "2020-01-01T00:00:00+00:00"), ("conv_new", "2024-01-01T00:00:00+00:00")] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at) VALUES (?1, 'org', ?2)",
                    params![k, updated],
                )
                .unwrap();
                enqueue_triage_job(&conn, k, updated).unwrap();
            }
        }
        // Newest conversation is claimed first.
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("conv_new"));
        // A processing row isn't re-claimed; the older one comes next.
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("conv_old"));
        assert_eq!(s.claim_next_triage_job().unwrap(), None);
        // Complete the new one — only the processing row is removed.
        assert!(s.complete_triage_job("conv_new").unwrap());
        let pending = s.triage_progress().unwrap().pending;
        assert_eq!(pending, 1, "only conv_old should remain queued");
    }

    #[test]
    fn backfill_reruns_subject_echo_summaries_once() {
        let s = store();
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        let long = "A very long subject line that runs well past the ninety character truncation limit used by the rule path";
        {
            let conn = s.conn.lock();
            for (k, subject, short, source) in [
                ("conv_echo", "Weekly newsletter", "Weekly newsletter", "rule:marketing_strong"),
                ("conv_echo_cut", long, &format!("{}…", &long[..90]) as &str, "rule:marketing_strong"),
                ("conv_real", "Invoice 4021", "Pay €240 before 3 March", "rule:action+model:openai"),
                ("conv_poison", "Stuck thread", "Stuck thread", "fallback:exhausted"),
            ] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at, subject,
                       ai_summary_short, ai_meta_msg_key, triage_source)
                     VALUES (?1, 'org', '2024-01-01T00:00:00+00:00', ?2, ?3, 'msg1', ?4)",
                    params![k, subject, short, source],
                )
                .unwrap();
            }
        }
        // Both echoes (exact and truncated) lose their anchor and get re-enqueued; the
        // real summary and the poison row are left alone.
        assert_eq!(s.backfill_triage_queue().unwrap(), 2);
        let cleared = |k: &str| -> bool {
            s.conn
                .lock()
                .query_row(
                    "SELECT ai_meta_msg_key IS NULL FROM conversations WHERE key = ?1",
                    params![k],
                    |r| r.get::<_, bool>(0),
                )
                .unwrap()
        };
        assert!(cleared("conv_echo"));
        assert!(cleared("conv_echo_cut"));
        assert!(!cleared("conv_real"));
        assert!(!cleared("conv_poison"));
        // Marker-gated: a second pass must not re-clear anything (a model-less rerun
        // would otherwise rewrite the echo and loop forever).
        {
            let conn = s.conn.lock();
            conn.execute("UPDATE conversations SET ai_meta_msg_key = 'msg1'", []).unwrap();
            conn.execute("DELETE FROM ai_triage_queue", []).unwrap();
        }
        assert_eq!(s.backfill_triage_queue().unwrap(), 0);
        assert!(!cleared("conv_echo"));
    }

    #[test]
    fn deferral_cap_stops_the_reactivate_loop_and_finalizes() {
        // A thread the model always reports "unavailable" on defers every pass. Without a
        // cap it loops defer→reactivate forever and wedges the "Catching up" bar one short
        // of 100%. Past TRIAGE_MAX_DEFERS it must stop reactivating and become claimable
        // poison (listed by exhausted_unlabeled_triage_keys for a fallback label).
        let s = store();
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        let updated = "2024-01-01T00:00:00+00:00";
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, updated_at) VALUES ('conv_x', 'org', ?1)",
                params![updated],
            )
            .unwrap();
            enqueue_triage_job(&conn, "conv_x", updated).unwrap();
        }
        let age_past_backoff = |s: &SyncStore| {
            let conn = s.conn.lock();
            let past = (Utc::now() - chrono::Duration::seconds(TRIAGE_DEFER_BACKOFF_SECS + 1)).to_rfc3339();
            conn.execute(
                "UPDATE ai_triage_queue SET updated_at = ?1 WHERE conversation_key = 'conv_x'",
                params![past],
            )
            .unwrap();
        };
        for round in 1..=TRIAGE_MAX_DEFERS {
            assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("conv_x"), "round {round} claim");
            s.defer_triage_job("conv_x").unwrap();
            age_past_backoff(&s);
            let revived = s.reactivate_deferred_triage().unwrap();
            if round < TRIAGE_MAX_DEFERS {
                assert_eq!(revived, 1, "round {round}: under cap, must reactivate");
            } else {
                assert_eq!(revived, 0, "at cap: must NOT reactivate (would loop forever)");
            }
        }
        // Bar can complete: nothing claimable keeps it visible, and the wedged thread is
        // now listed for the deterministic poison label.
        assert_eq!(s.triage_progress().unwrap().pending, 0, "capped job must not hold the bar");
        assert_eq!(s.exhausted_unlabeled_triage_keys().unwrap(), vec!["conv_x".to_string()]);
    }

    #[test]
    fn pending_excludes_out_of_window_jobs() {
        // The bar reports catch-up over the window, so an out-of-window claimable job must
        // not keep it visible after the window itself is done (the "100% but still showing"
        // bug). The worker doesn't claim them either (no Jev calls outside the window)
        // until the window is widened again.
        let s = store(); // default window = LastMonth
        let recent = Utc::now().to_rfc3339();
        let old = (Utc::now() - chrono::Duration::days(400)).to_rfc3339();
        {
            let conn = s.conn.lock();
            // Out-of-window history is archived: an OPEN thread is always eligible.
            for (k, d) in [("in_win", recent.as_str()), ("out_win", old.as_str())] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at, status) VALUES (?1, 'org', ?2, 'archived')",
                    params![k, d],
                )
                .unwrap();
                enqueue_triage_job(&conn, k, d).unwrap();
            }
        }
        let p = s.triage_progress().unwrap();
        assert_eq!(p.pending, 1, "only the in-window job counts toward the bar");
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("in_win"));
        assert_eq!(s.claim_next_triage_job().unwrap(), None, "out-of-window job stays parked");
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("out_win"));
    }

    #[test]
    fn new_only_window_triages_only_mail_after_it_was_picked() {
        let s = store();
        s.set_processing_window(ProcessingWindow::NewOnly).unwrap();
        let before = (Utc::now() - chrono::Duration::minutes(5)).to_rfc3339();
        let after = (Utc::now() + chrono::Duration::seconds(1)).to_rfc3339();
        {
            let conn = s.conn.lock();
            for (k, d) in [("old", before.as_str()), ("new", after.as_str())] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at, status) VALUES (?1, 'org', ?2, 'archived')",
                    params![k, d],
                )
                .unwrap();
                enqueue_triage_job(&conn, k, d).unwrap();
            }
            assert!(!within_processing_window(&conn, &before), "history is out of window");
            assert!(within_processing_window(&conn, &after), "new mail is in window");
        }
        assert_eq!(s.triage_progress().unwrap().in_window, 1);
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("new"));
        assert_eq!(s.claim_next_triage_job().unwrap(), None);
        // Re-picking keeps the anchor instead of moving it forward.
        let anchor = s.processing_cutoff();
        s.set_processing_window(ProcessingWindow::NewOnly).unwrap();
        assert_eq!(s.processing_cutoff(), anchor);
    }

    #[test]
    fn old_open_thread_is_triaged_but_old_archived_is_not() {
        // The window bounds history only: an open (inbox) thread older than the
        // window is claimable and counted; an archived one of the same age isn't.
        let s = store(); // default window = LastMonth
        let old = (Utc::now() - chrono::Duration::days(400)).to_rfc3339();
        {
            let conn = s.conn.lock();
            for (k, status) in [("old_open", "open"), ("old_arch", "archived")] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at, status) VALUES (?1, 'org', ?2, ?3)",
                    params![k, old, status],
                )
                .unwrap();
            }
            // The upsert gate: the open thread's old message still enqueues.
            assert!(triage_eligible(&conn, "old_open", &old));
            assert!(!triage_eligible(&conn, "old_arch", &old));
        }
        // Backfill (startup / key / window change) picks up only the open one.
        assert_eq!(s.backfill_triage_queue().unwrap(), 1);
        s.conn.lock().execute("DELETE FROM ai_triage_queue", []).unwrap();
        {
            let conn = s.conn.lock();
            enqueue_triage_job(&conn, "old_open", &old).unwrap();
            enqueue_triage_job(&conn, "old_arch", &old).unwrap();
        }
        let p = s.triage_progress().unwrap();
        assert_eq!((p.in_window, p.done, p.pending), (1, 0, 1));
        assert_eq!(s.triage_diagnostics().unwrap().unenqueued_in_window, 0);
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("old_open"));
        assert_eq!(s.claim_next_triage_job().unwrap(), None, "old archived job stays parked");

        // Archiving the old open thread parks its job too.
        s.complete_triage_job("old_open").unwrap();
        {
            let conn = s.conn.lock();
            enqueue_triage_job(&conn, "old_open", &old).unwrap();
            conn.execute("UPDATE conversations SET status = 'archived' WHERE key = 'old_open'", []).unwrap();
        }
        assert_eq!(s.claim_next_triage_job().unwrap(), None);
        let p = s.triage_progress().unwrap();
        assert_eq!((p.in_window, p.pending), (0, 0));
    }

    #[test]
    fn effective_spaces_are_org_then_personal_without_collisions() {
        let s = store();
        // Nothing pushed: the personal defaults alone.
        let slugs = |v: Vec<SpaceDef>| v.into_iter().map(|d| d.slug).collect::<Vec<_>>();
        assert_eq!(slugs(s.effective_spaces()), ["reading", "personal"]);
        s.set_space_taxonomy(
            r#"[{"slug":"sales","name":"Sales","description":"deals"},{"slug":"reading","name":"Reading list","description":"org's"}]"#,
        )
        .unwrap();
        let eff = s.effective_spaces();
        assert_eq!(slugs(eff.clone()), ["sales", "reading", "personal"]);
        assert_eq!(eff[1].name, "Reading list", "the org's Space wins a slug collision");
    }

    #[test]
    fn changing_personal_spaces_refiles_and_validates() {
        let s = store();
        s.set_space_classify_enabled(true).unwrap();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, updated_at, space_slug)
                 VALUES ('c1', 'org', ?1, 'personal')",
                params![Utc::now().to_rfc3339()],
            )
            .unwrap();
        }
        let space_of = |s: &SyncStore| -> Option<String> {
            s.conn.lock().query_row("SELECT space_slug FROM conversations WHERE key='c1'", [], |r| r.get(0)).unwrap()
        };
        // First set records the filed list (no list recorded yet → re-file).
        let defaults = crate::triage::default_personal_spaces();
        assert_eq!(s.set_personal_spaces(defaults.clone()).unwrap().1, 1);
        s.conn.lock().execute("DELETE FROM ai_triage_queue", []).unwrap();
        s.conn.lock().execute("UPDATE conversations SET space_slug = 'personal'", []).unwrap();
        // Same list → nothing re-filed.
        assert_eq!(s.set_personal_spaces(defaults.clone()).unwrap().1, 0);
        assert_eq!(space_of(&s).as_deref(), Some("personal"));
        // A re-described personal Space re-files.
        let mut edited = defaults.clone();
        edited[1].description = "Family only".into();
        let (stored, requeued) = s.set_personal_spaces(edited).unwrap();
        assert_eq!((stored[1].description.as_str(), requeued), ("Family only", 1));
        assert_eq!(space_of(&s), None);
        assert_eq!(s.personal_spaces(), stored);
        // Refused: bad/reserved/duplicate slugs, empty name. Nothing changes.
        for bad in ["Bad Slug", "triage", "no_match", "reading", ""] {
            let mut l = stored.clone();
            l.push(SpaceDef { slug: bad.into(), ..stored[0].clone() });
            assert!(s.set_personal_spaces(l).is_err(), "{bad:?} must be refused");
        }
        let mut l = stored.clone();
        l.push(SpaceDef { slug: "kids-club".into(), name: " ".into(), ..stored[0].clone() });
        assert!(s.set_personal_spaces(l).is_err(), "a name is required");
        assert_eq!(s.personal_spaces(), stored);
        // An empty personal list is allowed (org Spaces only).
        assert!(s.set_personal_spaces(Vec::new()).unwrap().0.is_empty());
    }

    #[test]
    fn personal_spaces_alone_ask_the_space_question() {
        let s = store();
        s.set_space_classify_enabled(true).unwrap();
        assert!(s.space_taxonomy().is_empty(), "no org taxonomy pushed");
        let q = crate::triage::jev_questions(&s.triage_labels(), &s.effective_spaces(), true);
        let space = q.space.expect("personal Spaces are enough to ask the space question");
        let slugs: Vec<&str> = space.criteria.0.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(slugs, ["reading", "personal", "no_match"]);
    }

    #[test]
    fn changed_taxonomy_refiles_spaces_and_identical_push_is_a_noop() {
        let s = store();
        s.set_space_classify_enabled(true).unwrap();
        let recent = Utc::now().to_rfc3339();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, updated_at, space_slug)
                 VALUES ('c1', 'org', ?1, 'spam')",
                params![recent],
            )
            .unwrap();
        }
        let tax = r#"[{"slug":"finance","name":"Finance","description":"invoices"}]"#;
        // First push after the Jev switch clears the old classifier's verdicts.
        assert_eq!(s.set_space_taxonomy(tax).unwrap(), 1);
        let slug: Option<String> = s
            .conn
            .lock()
            .query_row("SELECT space_slug FROM conversations WHERE key = 'c1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(slug, None);
        s.conn.lock().execute("DELETE FROM ai_triage_queue", []).unwrap();
        s.conn.lock().execute("UPDATE conversations SET space_slug = 'finance'", []).unwrap();
        // The same list again (every app load pushes it) changes nothing.
        assert_eq!(s.set_space_taxonomy(tax).unwrap(), 0);
        // A re-described Space re-files.
        assert_eq!(
            s.set_space_taxonomy(r#"[{"slug":"finance","name":"Finance","description":"bills"}]"#).unwrap(),
            1
        );
    }

    #[test]
    fn reactivates_unavailable_failures_but_not_poison() {
        let s = store();
        // Window-independent queue mechanics — pin to Everything so `pending` (in-window-
        // scoped) counts these old-dated fixtures.
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        {
            let conn = s.conn.lock();
            // Three conversations, all in the queue as `failed` with attempts maxed.
            for (k, err) in [
                ("conv_unavail", "on-device generator unavailable"),
                ("conv_apple", "assetsUnavailable(... \"Model is unavailable\")"),
                ("conv_poison", "unparseable triage response: blah"),
            ] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at)
                     VALUES (?1, 'org', '2024-01-01T00:00:00+00:00')",
                    params![k],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO ai_triage_queue
                       (conversation_key, priority, status, attempts, error_message, created_at, updated_at)
                     VALUES (?1, '2024-01-01T00:00:00+00:00', ?2, 3, ?3, '2024', '2024')",
                    params![k, TriageStatus::Failed.as_str(), err],
                )
                .unwrap();
            }
        }

        // Before: all three are failed+exhausted, so none are claimable and none
        // count toward the "still working" total.
        assert_eq!(s.claim_next_triage_job().unwrap(), None, "exhausted failures aren't claimed");
        assert_eq!(s.triage_progress().unwrap().pending, 0, "poison must not wedge the bar");

        // Deferred reactivation must NOT touch failures (no deferred rows here).
        assert_eq!(s.reactivate_deferred_triage().unwrap(), 0, "deferred pass leaves failures alone");

        // The one-shot recovery re-queues the two availability-failures (attempts
        // reset); the genuine poison is left alone.
        let n = s.reactivate_unavailable_failures().unwrap();
        assert_eq!(n, 2, "only the two unavailable-error rows reactivate");
        assert_eq!(s.triage_progress().unwrap().pending, 2, "reactivated rows are claimable again");

        let conn = s.conn.lock();
        let poison_attempts: i64 = conn
            .query_row(
                "SELECT attempts FROM ai_triage_queue WHERE conversation_key='conv_poison'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(poison_attempts, 3, "poison stays failed+exhausted, can't loop");
    }

    #[test]
    fn stuck_processing_row_exhausts_instead_of_wedging_the_bar() {
        // The recurring "Catching up" wedge: a row left in `processing` because the
        // worker died mid-generation (the app is suspended/killed during on-device
        // generation). It must be charged an attempt on each stale reclaim so it
        // eventually exhausts, and once exhausted it must neither be claimed nor
        // counted — otherwise `pending` stays > 0 and the bar never completes.
        let s = store();
        // Window-independent queue mechanics — pin to Everything so `pending` (in-window-
        // scoped) counts these old-dated fixtures.
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        {
            let conn = s.conn.lock();
            for (k, attempts) in [("conv_stuck", 0_i64), ("conv_dead", TRIAGE_MAX_ATTEMPTS)] {
                conn.execute(
                    "INSERT INTO conversations (key, organization_id, updated_at)
                     VALUES (?1, 'org', '2024-01-01T00:00:00+00:00')",
                    params![k],
                )
                .unwrap();
                // Stale `processing` (old updated_at), one with retries left and one
                // already at the attempt cap.
                conn.execute(
                    "INSERT INTO ai_triage_queue
                       (conversation_key, priority, status, attempts, created_at, updated_at)
                     VALUES (?1, '2024-01-01T00:00:00+00:00', ?2, ?3, '2024', '2024-01-01T00:00:00+00:00')",
                    params![k, TriageStatus::Processing.as_str(), attempts],
                )
                .unwrap();
            }
        }

        // The exhausted stuck-processing row must drop out of the count (it can never
        // complete); only the row with attempts left is still "working".
        assert_eq!(
            s.triage_progress().unwrap().pending,
            1,
            "exhausted processing must not wedge the bar"
        );

        // Reclaiming the stale row charges it an attempt (its prior attempt died
        // without recording a failure), and the exhausted row is never reclaimed.
        assert_eq!(s.claim_next_triage_job().unwrap().as_deref(), Some("conv_stuck"));
        assert_eq!(
            s.claim_next_triage_job().unwrap(),
            None,
            "exhausted processing row is never reclaimed"
        );
        let conn = s.conn.lock();
        let attempts: i64 = conn
            .query_row(
                "SELECT attempts FROM ai_triage_queue WHERE conversation_key='conv_stuck'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(attempts, 1, "a reclaimed dead processing row is charged an attempt so it can't loop forever");
    }

    #[test]
    fn detects_bulk_from_unsubscribe_in_html() {
        let s = store();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at) VALUES
                 ('cnews','org','Integrate Actors','2024-01-01T00:00:00+00:00'),
                 ('cpers','org','Re: lunch?','2024-01-01T00:00:00+00:00')",
                [],
            ).unwrap();
            // Newsletter: unsubscribe only in the HTML part (not plain) — the common case.
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, body_plain, body_html, created_at)
                 VALUES ('mn','cnews','org','Time to incorporate Actors into your workflow!',
                         '<a href=x>Unsubscribe</a>', '2024-01-01T00:00:00+00:00')",
                [],
            ).unwrap();
            // Personal: no bulk markers.
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, body_plain, body_html, created_at)
                 VALUES ('mp','cpers','org','Are you free for lunch tomorrow?', NULL, '2024-01-01T00:00:00+00:00')",
                [],
            ).unwrap();
        }
        assert_eq!(
            s.conversation_triage_input("cnews").unwrap().unwrap().deterministic,
            Some(TriageLabel::Fyi)
        );
        assert_eq!(
            s.conversation_triage_input("cpers").unwrap().unwrap().deterministic,
            None
        );
    }

    #[test]
    fn deterministic_label_priority() {
        let s = store();
        let insert = |key: &str, subject: &str, from: &str, mid: &str, plain: &str, html: &str| {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at)
                 VALUES (?1,'org',?2,'2024-01-01T00:00:00+00:00')",
                params![key, subject],
            ).unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, message_id_header, body_plain, body_html, created_at)
                 VALUES (?1||'_m', ?1, 'org', ?3, ?4, ?5, ?6, '2024-01-01T00:00:00+00:00')",
                params![key, subject, from, mid, plain, html],
            ).unwrap();
        };
        let det = |key: &str| s.conversation_triage_input(key).unwrap().unwrap().deterministic;

        // Marketing: ESP domain → fyi.
        insert("esp", "Deal", "Brand <hi@brand.com>", "<x@mail.mcdlv.net>", "hello", "");
        assert_eq!(det("esp"), Some(TriageLabel::Fyi), "ESP → fyi");

        // Two medium signals (no-reply + utm) → fyi.
        insert("med2", "News", "noreply@brand.com", "<y@brand.com>", "click https://x?utm_source=news", "");
        assert_eq!(det("med2"), Some(TriageLabel::Fyi), "no-reply + utm → fyi");

        // A single medium signal (no-reply only) is not enough → defer to model.
        insert("med1", "Hello", "noreply@brand.com", "<z@brand.com>", "Thanks for joining us", "");
        assert_eq!(det("med1"), None, "no-reply alone → defer");

        // A sign-in code → notification by rule, even with "verify your email".
        insert("otp", "Your code", "noreply@brand.com", "<o@brand.com>",
               "Verify your email: your one-time code is 123456", "");
        let otp = s.conversation_triage_input("otp").unwrap().unwrap();
        assert_eq!(otp.deterministic, Some(TriageLabel::Notification), "sign-in code → notification");
        assert_eq!(otp.det_source, "rule:otp");
        assert!(otp.signals.contains("otp"), "signals recorded: {}", otp.signals);

        // A magic link alone doesn't decide the label — Jev does (newsletters looked like one).
        insert("magic", "Sign in to Acme", "Acme <hi@acme.com>", "<g@acme.com>", "Click to sign in.",
               "<a href=\"https://acme.com/login?token=abc\">Sign in</a>");
        assert_ne!(det("magic"), Some(TriageLabel::Notification), "magic link → Jev, not the rule");

        // A personal email → defer to the model.
        insert("pers", "Re: lunch?", "Sam <sam@x.com>", "<p@x.com>", "Are you free for lunch tomorrow?", "");
        assert_eq!(det("pers"), None, "personal mail → defer");

        // action_required beats marketing: a signature request even with unsubscribe.
        insert("sig", "Sign", "DocuSign <dse@docusign.net>", "<a@docusign.net>",
               "Signature requested. Please sign the document. unsubscribe", "");
        assert_eq!(det("sig"), Some(TriageLabel::ActionRequired), "signature → action_required");

        // A bill even with an unsubscribe footer → payment_due, not fyi.
        insert("bill", "Bill", "du Billing <billing@du.ae>", "<b@du.ae>",
               "Your monthly bill for account number 28500726 is ready. unsubscribe", "");
        assert_eq!(det("bill"), Some(TriageLabel::PaymentDue), "bill → payment_due");

        // Calendar invite → scheduling (body signal).
        insert("cal", "Invitation: Team sync", "Cal <cal@x.com>", "<c@x.com>",
               "Sam has invited you to the following event. When: Tue 3pm", "");
        assert_eq!(det("cal"), Some(TriageLabel::Scheduling), "invite → scheduling");

        // Calendar RSVP via subject convention only.
        insert("cal2", "Accepted: Q3 review", "Sam <sam@x.com>", "<c2@x.com>", "Yes, I'll be there.", "");
        assert_eq!(det("cal2"), Some(TriageLabel::Scheduling), "RSVP subject → scheduling");

        // Dutch booking-service appointment reminder (Treatwell-style): no-reply
        // sender + marketing footer signals must NOT drag it to fyi.
        insert("apt_nl", "Jouw afspraakherinnering", "Treatwell <noreply@treatwell.nl>", "<t@treatwell.nl>",
               "Het is bijna tijd voor je afspraak bij Amro Style. 12:00 - 12:30 op 12 juni met Ali. \
                Verplaats je afspraak. unsubscribe https://x?utm_source=mail © Treatwell", "");
        assert_eq!(det("apt_nl"), Some(TriageLabel::Scheduling), "Dutch appointment reminder → scheduling");

        // English appointment reminder, body signal only.
        insert("apt_en", "See you soon", "Salon <noreply@booksy.com>", "<a@booksy.com>",
               "This is a reminder for your appointment at Fade Lab, Friday 3:00 PM. unsubscribe", "");
        assert_eq!(det("apt_en"), Some(TriageLabel::Scheduling), "appointment reminder → scheduling");

        // Dutch invoice (Infomedics) → payment_due, with provenance recorded.
        insert("nl", "Uw rekening van Maxim Dental B.V.", "Infomedics <noreply@infomedics.nl>", "<i@infomedics.nl>",
               "Namens Maxim Dental sturen we u deze rekening. U heeft 30 dagen om te betalen. Bedrag: € 32,42", "");
        let nl = s.conversation_triage_input("nl").unwrap().unwrap();
        assert_eq!(nl.deterministic, Some(TriageLabel::PaymentDue), "Dutch invoice → payment_due");
        assert_eq!(nl.det_source, "rule:payment");
        assert!(nl.signals.contains("pay"), "signals recorded: {}", nl.signals);
    }

    #[test]
    fn write_result_respects_staleness() {
        let s = store();
        let acct = s
            .create_account(&crate::sync::model::ExternalAccount {
                key: String::new(),
                display_name: "a@x.com".into(),
                email_address: "a@x.com".into(),
                provider_type: ProviderType::Gmail,
                host: None,
                port: None,
                use_tls: true,
                smtp_host: None,
                smtp_port: None,
                smtp_use_tls: true,
                auth_method: "oauth2".into(),
                status: crate::sync::model::AccountStatus::Disconnected,
                error_message: None,
                last_connected_at: None,
                sort_order: 0,
                avatar_url: None,
            })
            .unwrap();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at) VALUES ('conv1','org','Hi','2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, account_key, created_at)
                 VALUES ('msg1','conv1','org','x@y.com','hello there', ?1, '2024-01-01T00:00:00+00:00')",
                params![acct],
            )
            .unwrap();
        }
        let input = s.conversation_triage_input("conv1").unwrap().unwrap();
        assert_eq!(input.newest_msg_key, "msg1");
        assert!(input.thread_text.contains("hello there"));
        assert_eq!(input.owner, "a@x.com", "the account address is the Jev owner");
        assert_eq!(input.messages.len(), 1);
        assert_eq!(input.messages[0].direction, "received");

        // Correct anchor → writes.
        assert!(s
            .write_triage_result("conv1", Some("needs_answer"), Some(2.5), "med", "short", "msg1", "model:openai", "noreply")
            .unwrap());
        // Stale anchor → refused.
        assert!(!s
            .write_triage_result("conv1", Some("fyi"), None, "m", "s", "msg_gone", "rule:marketing_strong", "unsub")
            .unwrap());
        let conn = s.conn.lock();
        let (label, priority): (String, f64) = conn
            .query_row("SELECT triage_label, triage_priority FROM conversations WHERE key='conv1'", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(label, "needs_answer");
        assert_eq!(priority, 2.5);
    }

    // Regression: two messages sharing a created_at must not wedge the worker.
    // The staleness anchor from conversation_triage_input has to match what
    // write_triage_result recomputes, or the job loops forever as Outcome::Stale
    // and the "Catching up" bar sticks below 100%.
    #[test]
    fn tied_created_at_does_not_false_fail_staleness() {
        let s = store();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at) VALUES ('conv1','org','Hi','2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            // Two messages, identical created_at — the ambiguous tie-break case.
            for k in ["msgA", "msgB"] {
                conn.execute(
                    "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, created_at)
                     VALUES (?1,'conv1','org','x@y.com','hello', '2024-01-01T00:00:00+00:00')",
                    params![k],
                )
                .unwrap();
            }
        }
        // The anchor the worker would carry into write_triage_result.
        let input = s.conversation_triage_input("conv1").unwrap().unwrap();
        // Writing with that exact anchor must succeed (not be judged stale).
        assert!(
            s.write_triage_result("conv1", Some("fyi"), None, "m", "s", &input.newest_msg_key, "rule:x", "sig")
                .unwrap(),
            "tied created_at must not make the write look stale"
        );
        // And it must be repeatable/deterministic across calls.
        let input2 = s.conversation_triage_input("conv1").unwrap().unwrap();
        assert_eq!(input.newest_msg_key, input2.newest_msg_key, "anchor must be deterministic");
    }

    #[test]
    fn space_classify_flag_defaults_off_and_toggles() {
        let s = store();
        assert!(!s.space_classify_enabled(), "off by default");
        s.set_space_classify_enabled(true).unwrap();
        assert!(s.space_classify_enabled());
        s.set_space_classify_enabled(false).unwrap();
        assert!(!s.space_classify_enabled());
    }

    #[test]
    fn space_taxonomy_roundtrips_and_rejects_garbage() {
        let s = store();
        assert!(s.space_taxonomy().is_empty(), "unset by default");
        // Legacy pairs still accepted (name = slug).
        s.set_space_taxonomy(r#"[["support","help desk"],["legal","contracts"]]"#).unwrap();
        let tax = s.space_taxonomy();
        assert_eq!(tax.len(), 2);
        assert_eq!((tax[0].slug.as_str(), tax[0].name.as_str(), tax[0].description.as_str()), ("support", "support", "help desk"));
        // Objects carry name + not_for.
        s.set_space_taxonomy(r#"[{"slug":"sales","name":"Sales","description":"","not_for":"Existing customers"}]"#)
            .unwrap();
        let tax = s.space_taxonomy();
        assert_eq!(tax[0].name, "Sales");
        assert_eq!(tax[0].not_for, "Existing customers");
        // Wrong shape is rejected and doesn't clobber the stored value.
        assert!(s.set_space_taxonomy(r#"{"support":"x"}"#).is_err());
        assert_eq!(s.space_taxonomy().len(), 1);
        s.set_space_taxonomy("[]").unwrap();
        assert!(s.space_taxonomy().is_empty());
    }

    #[test]
    fn triage_labels_default_validate_and_persist() {
        let s = store();
        let labels = s.triage_labels();
        assert_eq!(labels, crate::triage::builtin_labels(), "built-ins by default");

        let mut edited = labels.clone();
        edited.push(TriageLabelDef {
            slug: "legal_review".into(),
            name: "Legal review".into(),
            description: "Contracts legal must read".into(),
            not_for: String::new(),
            color: Some("#aa0000".into()),
            builtin: true, // clients can't promote a custom label
            enabled: true,
        });
        edited[7].enabled = false; // resolved
        let stored = s.set_triage_labels(edited).unwrap();
        assert!(!stored.last().unwrap().builtin);
        assert_eq!(s.triage_labels(), stored);

        // Removing a built-in, disabling fyi, bad/reserved/duplicate slugs are refused.
        let base = s.triage_labels();
        assert!(s.set_triage_labels(base[1..].to_vec()).is_err());
        let mut no_fyi = base.clone();
        no_fyi[6].enabled = false;
        assert!(s.set_triage_labels(no_fyi).is_err());
        for bad in ["Bad Slug", "no_match", "needs_answer", ""] {
            let mut l = base.clone();
            l.push(TriageLabelDef { slug: bad.into(), ..base[8].clone() });
            assert!(s.set_triage_labels(l).is_err(), "{bad:?} must be refused");
        }
        assert_eq!(s.triage_labels(), stored, "a refused write changes nothing");
    }

    #[test]
    fn backfill_space_queue_targets_unspaced_threads_only() {
        let s = store();
        {
            let conn = s.conn.lock();
            // Triaged but unspaced → wanted. Spaced → skipped.
            conn.execute(
                "INSERT INTO conversations (key, organization_id, updated_at, ai_meta_msg_key, space_slug)
                 VALUES ('unspaced','org','2024-01-02T00:00:00+00:00','m1',NULL),
                        ('spaced','org','2024-01-02T00:00:00+00:00','m2','sales')",
                [],
            )
            .unwrap();
        }
        s.set_processing_window(ProcessingWindow::Everything).unwrap();
        assert_eq!(s.backfill_space_queue().unwrap(), 1);
        let conn = s.conn.lock();
        let queued: String = conn
            .query_row("SELECT conversation_key FROM ai_triage_queue", [], |r| r.get(0))
            .unwrap();
        assert_eq!(queued, "unspaced");
    }

    #[test]
    fn triage_meta_reads_anchor_and_slug() {
        let s = store();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, ai_meta_msg_key, space_slug)
                 VALUES ('c','org','m9','support')",
                [],
            )
            .unwrap();
        }
        assert_eq!(
            s.triage_meta("c").unwrap(),
            Some(TriageMeta { msg_key: Some("m9".into()), space: Some("support".into()), ..Default::default() })
        );
        assert_eq!(s.triage_meta("nope").unwrap(), None);
    }

    #[test]
    fn write_space_result_respects_staleness() {
        let s = store();
        {
            let conn = s.conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, updated_at) VALUES ('c','org','Hi','2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO messages (key, conversation_key, organization_id, from_address, body_plain, created_at)
                 VALUES ('m1','c','org','x@y.com','hi','2024-01-01T00:00:00+00:00')",
                [],
            )
            .unwrap();
        }
        // Correct anchor → writes the slug.
        assert!(s.write_space_result("c", "sales", "m1").unwrap());
        // Stale anchor → refused, slug unchanged.
        assert!(!s.write_space_result("c", "finance", "m_gone").unwrap());
        let conn = s.conn.lock();
        let slug: String = conn
            .query_row("SELECT space_slug FROM conversations WHERE key='c'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(slug, "sales");
    }
}
