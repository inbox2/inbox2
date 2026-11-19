//! Triage classification + processing-window enums.
//!
//! Single source of truth for the triage taxonomy and the sync/processing
//! window, mirroring the `event`/`SyncPhase` enum discipline in
//! [`crate::sync::engine`] (one `as_str`/`from_str` source, no hardcoded strings
//! elsewhere — the "no duplicated enums" rule). Both are serialized to/from
//! SQLite as their `as_str()` form and parsed back with `from_str`.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// How a conversation is triaged. Computed asynchronously by the
/// [`crate::ai_worker::TriageWorker`] off the sync path (never live in the
/// Bridge) and stored in `conversations.triage_label`.
///
/// The wire strings are stable: they are persisted in SQLite, emitted on the
/// `triage-updated` event, and read by every client. The prompt's allowed-label
/// list is rendered from [`TriageLabel::ALL`], so adding a label is a one-line
/// change here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriageLabel {
    /// You need to reply.
    NeedsAnswer,
    /// Someone other than you needs to reply.
    NeedsAnswerOther,
    /// You replied; awaiting their response.
    WaitingReply,
    /// Needs your review / approval / sign-off.
    NeedsApproval,
    /// Scheduling / calendar coordination.
    Scheduling,
    /// A non-reply action is required (pay, sign, upload, …).
    ActionRequired,
    /// Informational; no action needed.
    Fyi,
    /// Thread is closed / resolved.
    Resolved,
    /// A bill / invoice / reminder the owner still has to pay.
    PaymentDue,
    /// A statement, report or shared document to look over.
    ToReview,
    /// A newsletter or article worth reading, not urgent.
    ReadLater,
    /// A record of something done or paid: receipt, order, shipping.
    Receipt,
    /// An automated system message: sign-in code, security or CI alert.
    Notification,
}

impl TriageLabel {
    /// Every label, in display order. Used both for the prompt's allowed set and
    /// for any UI that enumerates the taxonomy.
    pub const ALL: [TriageLabel; 13] = [
        Self::NeedsAnswer,
        Self::NeedsAnswerOther,
        Self::WaitingReply,
        Self::NeedsApproval,
        Self::Scheduling,
        Self::ActionRequired,
        Self::Fyi,
        Self::Resolved,
        Self::PaymentDue,
        Self::ToReview,
        Self::ReadLater,
        Self::Receipt,
        Self::Notification,
    ];

    /// Stable wire/DB string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NeedsAnswer => "needs_answer",
            Self::NeedsAnswerOther => "needs_answer_other",
            Self::WaitingReply => "waiting_reply",
            Self::NeedsApproval => "needs_approval",
            Self::Scheduling => "scheduling",
            Self::ActionRequired => "action_required",
            Self::Fyi => "fyi",
            Self::Resolved => "resolved",
            Self::PaymentDue => "payment_due",
            Self::ToReview => "to_review",
            Self::ReadLater => "read_later",
            Self::Receipt => "receipt",
            Self::Notification => "notification",
        }
    }

    /// Parse a DB value or a model's output token. Returns `None` for anything
    /// unrecognized so callers fail soft (leave the label NULL) rather than guess.
    pub fn from_str(s: &str) -> Option<TriageLabel> {
        match s.trim() {
            "needs_answer" => Some(Self::NeedsAnswer),
            "needs_answer_other" => Some(Self::NeedsAnswerOther),
            "waiting_reply" => Some(Self::WaitingReply),
            "needs_approval" => Some(Self::NeedsApproval),
            "scheduling" => Some(Self::Scheduling),
            "action_required" => Some(Self::ActionRequired),
            "fyi" => Some(Self::Fyi),
            "resolved" => Some(Self::Resolved),
            "payment_due" => Some(Self::PaymentDue),
            "to_review" => Some(Self::ToReview),
            "read_later" => Some(Self::ReadLater),
            "receipt" => Some(Self::Receipt),
            "notification" => Some(Self::Notification),
            _ => None,
        }
    }

    /// Display name — the Jev criterion `name` and the default chip text.
    pub fn name(self) -> &'static str {
        match self {
            Self::NeedsAnswer => "Needs answer",
            Self::NeedsAnswerOther => "Reply from someone else",
            Self::WaitingReply => "Waiting for reply",
            Self::NeedsApproval => "Needs approval",
            Self::Scheduling => "Scheduling",
            Self::ActionRequired => "Action required",
            Self::Fyi => "FYI",
            Self::Resolved => "Resolved",
            Self::PaymentDue => "To pay",
            Self::ToReview => "To review",
            Self::ReadLater => "Read later",
            Self::Receipt => "Receipt",
            Self::Notification => "Notification",
        }
    }

    /// Default description (the Jev criterion `what`). Parity-locked with Rails
    /// (`fixtures/parity/fixtures.json` → `jev_triage.builtin_labels`).
    pub fn description(self) -> &'static str {
        match self {
            Self::NeedsAnswer => "A real person directly asked the owner a question or made a request and is waiting for the owner's personal reply",
            Self::NeedsAnswerOther => "A reply is expected, but from someone other than the owner, for example the owner is only copied or the question is aimed at a colleague",
            Self::WaitingReply => "The owner sent the last message and is waiting for the other side to respond",
            Self::NeedsApproval => "The owner is asked to approve or authorize someone else's request or work: a pull request, a purchase, time off, an expense, or a document prepared for their sign-off",
            Self::Scheduling => "Arranging or changing a meeting or a time, or a reminder or confirmation of an already-booked appointment with a concrete date and time, automated booking mail included",
            Self::ActionRequired => "The owner must personally complete a concrete task with a consequence: sign a contract, cancel a subscription, verify an account, upload a requested file or fill in a requested form",
            Self::Fyi => "Informational, nothing is needed from the owner: announcements, promotions, product and service updates, threads the owner is only copied on, and anything else that asks nothing",
            Self::Resolved => "The matter is concluded and nothing is left to do, such as a closing thanks or a confirmation that it is done",
            Self::PaymentDue => "The owner has to pay something: an invoice, bill, payment reminder, failed direct debit or renewal fee that is not already paid or collected automatically",
            Self::ToReview => "Data or a document for the owner to look over, with nothing to answer or do: bank or card statements, reports, dashboards, analytics, shared spreadsheets",
            Self::ReadLater => "Something worth reading but not urgent: newsletters, articles, essays and product launch letters the owner subscribed to",
            Self::Receipt => "A record of something already done or paid: a receipt, an invoice marked paid or collected automatically, an order, shipping or delivery confirmation",
            Self::Notification => "An automated system message: sign-in codes and links, security alerts, password resets, build, deploy, crash and monitoring alerts, app store processing notices",
        }
    }

    /// Default `not_for` (empty = none).
    pub fn not_for(self) -> &'static str {
        match self {
            Self::NeedsAnswer => "Bulk, marketing, newsletter or automated mail; questions aimed at someone else",
            Self::WaitingReply => "A closing thanks that ends the conversation",
            Self::NeedsApproval => "Bills, invoices or payments the owner has to pay",
            Self::Scheduling => "Order, shipping or delivery updates",
            Self::ActionRequired => "Marketing calls to action such as get started, learn more or upgrade; bills, invoices or statements to pay or look over",
            Self::Fyi => "Newsletters and articles worth reading, receipts and order updates, automated system notifications",
            Self::PaymentDue => "Receipts and invoices that say they are already paid or will be collected automatically",
            Self::ToReview => "Documents the owner must sign or approve",
            Self::ReadLater => "Promotions, sales and discount offers",
            Self::Notification => "Messages written by a real person",
            _ => "",
        }
    }
}

// ---------------------------------------------------------------------------
// Jev (TypeSafe System One) triage — contract: docs/Triage.md
// ---------------------------------------------------------------------------

/// The Space verdict for mail no space clearly covers (the org holding pen).
pub const HOLDING_PEN: &str = "triage";
/// Jev's "none of the spaces" option. Reserved: no custom label may use it.
pub const NO_MATCH: &str = "no_match";
/// `triage_source` of a label the user picked by hand. Sticks until a new
/// message arrives in the thread (then Jev/the rules re-judge it).
pub const MANUAL_SOURCE: &str = "manual";
/// A Space answer below this probability goes to the holding pen.
pub const SPACE_MIN_PROBABILITY: f64 = 0.5;
/// The `priority` Score levels, index = value (0.0–4.0).
pub const PRIORITY_LEVELS: [&str; 5] = [
    "No attention needed: can be ignored, archived, or read whenever",
    "Low: worth reading eventually, no action or deadline",
    "Normal: needs a response or action within the next few days",
    "High: needs a response or action today, or blocks someone's work",
    "Urgent: needs immediate attention, such as an outage, a security incident, or a deadline within hours",
];

/// One triage label, built-in or custom. Stored as the engine setting
/// `triage_labels` (JSON array, position order) and read by every client.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TriageLabelDef {
    pub slug: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub not_for: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub builtin: bool,
    #[serde(default = "enabled_default")]
    pub enabled: bool,
}

fn enabled_default() -> bool {
    true
}

impl From<TriageLabel> for TriageLabelDef {
    fn from(l: TriageLabel) -> Self {
        Self {
            slug: l.as_str().into(),
            name: l.name().into(),
            description: l.description().into(),
            not_for: l.not_for().into(),
            color: None,
            builtin: true,
            enabled: true,
        }
    }
}

/// Built-in `(slug, description, not_for)` as they shipped before the
/// 2026-10-20 rewording. A stored label still carrying one (never edited) gets
/// the current text when the new built-ins are merged in
/// ([`merge_builtin_labels`]). Mirrors Rails `TriageLabel::LEGACY_TEXTS`.
const LEGACY_TEXTS: [(TriageLabel, &str, &str); 3] = [
    (
        TriageLabel::ActionRequired,
        "The owner must personally complete a concrete task with a consequence: pay a bill, invoice or statement, renew or cancel a subscription, sign a contract, verify an account, upload a requested file",
        "Marketing calls to action such as get started, learn more or upgrade",
    ),
    (
        TriageLabel::Fyi,
        "Informational, nothing is needed from the owner: newsletters, marketing, announcements, receipts, shipping and payment confirmations, notifications and digests",
        "",
    ),
    (
        TriageLabel::Scheduling,
        "Arranging or changing a meeting or a time, or a reminder or confirmation of an already-booked appointment with a concrete date and time, automated booking mail included",
        "",
    ),
];

/// A stored label list made before a release added built-ins: append the
/// missing ones (after any custom label, as Rails does) and refresh unedited
/// legacy texts. A complete list is returned unchanged.
pub fn merge_builtin_labels(mut labels: Vec<TriageLabelDef>) -> Vec<TriageLabelDef> {
    let missing: Vec<TriageLabelDef> =
        builtin_labels().into_iter().filter(|b| !labels.iter().any(|l| l.slug == b.slug)).collect();
    if missing.is_empty() {
        return labels;
    }
    if missing.len() < TriageLabel::ALL.len() {
        for (label, description, not_for) in LEGACY_TEXTS {
            if let Some(l) = labels
                .iter_mut()
                .find(|l| l.slug == label.as_str() && l.description == description && l.not_for == not_for)
            {
                l.description = label.description().into();
                l.not_for = label.not_for().into();
            }
        }
    }
    labels.extend(missing);
    labels
}

/// The built-ins with their default texts, in display order.
pub fn builtin_labels() -> Vec<TriageLabelDef> {
    TriageLabel::ALL.into_iter().map(Into::into).collect()
}

/// Validate + normalize a label list before it's stored: slugs `[a-z0-9_]{1,40}`
/// and unique, a name and description on each, every built-in present (they
/// can be disabled, not removed), `fyi` enabled (it's the fallback), and no
/// custom slug equal to `no_match`. `builtin` is recomputed from the slug —
/// clients can't promote a custom label.
pub fn validate_labels(mut labels: Vec<TriageLabelDef>) -> Result<Vec<TriageLabelDef>, String> {
    let mut seen = std::collections::HashSet::new();
    for l in &mut labels {
        l.slug = l.slug.trim().to_string();
        l.name = l.name.trim().to_string();
        l.description = l.description.trim().to_string();
        l.not_for = l.not_for.trim().to_string();
        let ok = (1..=40).contains(&l.slug.len())
            && l.slug.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_');
        if !ok {
            return Err(format!("invalid label slug {:?}: use a-z, 0-9 and _ (max 40)", l.slug));
        }
        if l.slug == NO_MATCH {
            return Err(format!("{NO_MATCH} is reserved"));
        }
        if !seen.insert(l.slug.clone()) {
            return Err(format!("duplicate label slug {}", l.slug));
        }
        if l.name.is_empty() || l.description.is_empty() {
            return Err(format!("label {} needs a name and a description", l.slug));
        }
        l.builtin = TriageLabel::from_str(&l.slug).is_some();
        if l.slug == TriageLabel::Fyi.as_str() && !l.enabled {
            return Err("fyi can't be disabled: it is the fallback label".into());
        }
    }
    if let Some(missing) = TriageLabel::ALL.iter().find(|b| !seen.contains(b.as_str())) {
        return Err(format!("built-in label {} can't be removed (disable it instead)", missing.as_str()));
    }
    Ok(labels)
}

/// One org Space as the classifier sees it. `set_space_taxonomy` accepts these
/// objects or the legacy `["slug","description"]` pairs (name = slug).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(from = "SpaceWire")]
pub struct SpaceDef {
    pub slug: String,
    pub name: String,
    pub description: String,
    pub not_for: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum SpaceWire {
    Pair(String, String),
    Obj {
        slug: String,
        #[serde(default)]
        name: String,
        #[serde(default)]
        description: Option<String>,
        #[serde(default)]
        not_for: Option<String>,
    },
}

impl From<SpaceWire> for SpaceDef {
    fn from(w: SpaceWire) -> Self {
        match w {
            SpaceWire::Pair(slug, description) => {
                SpaceDef { name: slug.clone(), slug, description, not_for: String::new() }
            }
            SpaceWire::Obj { slug, name, description, not_for } => SpaceDef {
                name: if name.trim().is_empty() { slug.clone() } else { name },
                slug,
                description: description.unwrap_or_default(),
                not_for: not_for.unwrap_or_default(),
            },
        }
    }
}

/// The personal Spaces every device starts with — Jev can file a connected
/// account's mail into these next to the org's Spaces; they stay on the device
/// and are never shown to the team. Stored as the engine setting
/// `personal_spaces` once the user edits them.
pub fn default_personal_spaces() -> Vec<SpaceDef> {
    [
        (
            "reading",
            "Reading",
            "Newsletters, digests, blog posts and product updates to read when there's time",
            "Anything that asks the owner to act",
        ),
        (
            "personal",
            "Personal",
            "The owner's private life: appointments, family and friends, home, car, insurance and personal errands",
            "Work for the company",
        ),
    ]
    .into_iter()
    .map(|(slug, name, description, not_for)| SpaceDef {
        slug: slug.into(),
        name: name.into(),
        description: description.into(),
        not_for: not_for.into(),
    })
    .collect()
}

/// Validate + normalize a personal Space list: slugs `[a-z0-9_-]{1,40}`, unique,
/// not the holding pen (`triage`) or `no_match`; a name on each.
pub fn validate_personal_spaces(mut spaces: Vec<SpaceDef>) -> Result<Vec<SpaceDef>, String> {
    let mut seen = std::collections::HashSet::new();
    for s in &mut spaces {
        s.slug = s.slug.trim().to_string();
        s.name = s.name.trim().to_string();
        s.description = s.description.trim().to_string();
        s.not_for = s.not_for.trim().to_string();
        let ok = (1..=40).contains(&s.slug.len())
            && s.slug.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-');
        if !ok {
            return Err(format!("invalid space slug {:?}: use a-z, 0-9, _ and - (max 40)", s.slug));
        }
        if s.slug == HOLDING_PEN || s.slug == NO_MATCH {
            return Err(format!("{} is reserved", s.slug));
        }
        if !seen.insert(s.slug.clone()) {
            return Err(format!("duplicate space slug {}", s.slug));
        }
        if s.name.is_empty() {
            return Err(format!("space {} needs a name", s.slug));
        }
    }
    Ok(spaces)
}

/// One message of the Jev `state` (oldest first).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JevMessage {
    /// `received` or `sent` (sent = by the owner).
    pub direction: String,
    pub from: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct JevState {
    pub owner: String,
    pub thread: JevThread,
}

#[derive(Debug, Clone, Serialize)]
pub struct JevThread {
    pub subject: String,
    pub messages: Vec<JevMessage>,
    pub last_direction: String,
}

/// The Jev `state` for one thread. `messages` arrive already capped (newest 8,
/// 1500 chars, quotes stripped — see `conversation_triage_input`).
pub fn jev_state(owner: &str, subject: &str, messages: &[JevMessage]) -> JevState {
    let last_direction = messages.last().map_or("received", |m| m.direction.as_str()).to_string();
    JevState {
        owner: owner.to_string(),
        thread: JevThread { subject: subject.to_string(), messages: messages.to_vec(), last_direction },
    }
}

/// A JSON object whose keys keep insertion order (serde_json's `Map` sorts
/// without the `preserve_order` feature, and the contract fixes key order).
#[derive(Debug, Clone)]
pub struct Ordered<T>(pub Vec<(String, T)>);

impl<T: Serialize> Serialize for Ordered<T> {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Criterion {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub what: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub not_for: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Instructions {
    pub question: &'static str,
    pub focus: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChoiceQuestion {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub instructions: Instructions,
    pub criteria: Ordered<Criterion>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScoreQuestion {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub instructions: &'static str,
    pub criteria: [&'static str; 5],
}

#[derive(Debug, Clone, Serialize)]
pub struct JevQuestions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<ChoiceQuestion>,
    pub priority: ScoreQuestion,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub space: Option<ChoiceQuestion>,
}

/// The Jev questions: `label` (unless a rule already decided it), `priority`
/// always, `space` when there is at least one space to file into. Byte-identical
/// to Rails' `JevTriage.questions` (parity fixture `jev_triage`).
pub fn jev_questions(labels: &[TriageLabelDef], spaces: &[SpaceDef], ask_label: bool) -> JevQuestions {
    let label = ask_label.then(|| ChoiceQuestion {
        kind: "choice",
        instructions: Instructions {
            question: "Which label describes what `thread` needs from its owner (`owner`) right now?",
            focus: "Judge the newest message in the context of the thread. Bulk, marketing, newsletter and automated mail never needs a personal reply from the owner: label it by what it is, such as a bill to pay, a booked appointment, a statement to review, something to read, a receipt or a system notification.",
        },
        criteria: Ordered(
            labels
                .iter()
                .filter(|l| l.enabled)
                .map(|l| {
                    (
                        l.slug.clone(),
                        Criterion { name: Some(l.name.clone()), what: l.description.clone(), not_for: l.not_for.trim().to_string() },
                    )
                })
                .collect(),
        ),
    });
    let space = (!spaces.is_empty()).then(|| {
        let mut criteria: Vec<(String, Criterion)> = spaces
            .iter()
            .map(|s| {
                let what = if s.description.trim().is_empty() { s.name.clone() } else { s.description.clone() };
                (s.slug.clone(), Criterion { name: Some(s.name.clone()), what, not_for: s.not_for.trim().to_string() })
            })
            .collect();
        criteria.push((
            NO_MATCH.into(),
            Criterion { name: None, what: "A genuine email that none of the spaces above clearly covers".into(), not_for: String::new() },
        ));
        ChoiceQuestion {
            kind: "choice",
            instructions: Instructions {
                question: "Which team space should `thread` be filed in?",
                focus: "Judge the main purpose of the thread.",
            },
            criteria: Ordered(criteria),
        }
    });
    JevQuestions {
        label,
        priority: ScoreQuestion {
            kind: "score",
            instructions: "How soon does the owner of `thread` need to pay attention to it?",
            criteria: PRIORITY_LEVELS,
        },
        space,
    }
}

/// What a Jev response decided, read per the contract.
#[derive(Debug, Clone, PartialEq)]
pub struct JevVerdict {
    /// `Some` when the label was asked: the chosen slug, or `fyi` for an unknown one.
    pub label: Option<String>,
    pub priority: Option<f64>,
    /// `Some` when the space was asked: the space slug or [`HOLDING_PEN`].
    pub space: Option<String>,
    /// The model that answered (echoed by the response).
    pub model: String,
}

pub fn read_jev_answers(
    resp: &crate::typesafe::JevResponse,
    questions: &JevQuestions,
) -> JevVerdict {
    use crate::typesafe::Answer;
    let choice = |name: &str| match resp.answers.get(name) {
        Some(Answer::Choice { choice, probabilities, .. }) => {
            Some((choice.clone(), probabilities.get(choice).copied().unwrap_or(0.0)))
        }
        _ => None,
    };
    let known = |q: &ChoiceQuestion, slug: &str| q.criteria.0.iter().any(|(k, _)| k == slug);
    let label = questions.label.as_ref().map(|q| match choice("label") {
        Some((slug, _)) if known(q, &slug) => slug,
        _ => TriageLabel::Fyi.as_str().to_string(),
    });
    let priority = match resp.answers.get("priority") {
        Some(Answer::Score { score, .. }) => Some(*score),
        _ => None,
    };
    let space = questions.space.as_ref().map(|q| match choice("space") {
        Some((slug, p)) if slug != NO_MATCH && known(q, &slug) && p >= SPACE_MIN_PROBABILITY => slug,
        _ => HOLDING_PEN.to_string(),
    });
    JevVerdict { label, priority, space, model: resp.model.clone() }
}

/// How far back mail is classified / summarized. Bounds the work so the whole
/// backlog isn't scanned on first sync ("pause after a month"). Stored in
/// `engine_settings.processing_window` as `as_str()`; widening it triggers a
/// backfill of the newly-in-window conversations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessingWindow {
    /// Only mail that arrives after the window was chosen ("0d"): the cutoff is
    /// the stored `processing_window_since` anchor, never history.
    NewOnly,
    LastMonth,
    ThreeMonths,
    SixMonths,
    OneYear,
    Everything,
}

impl ProcessingWindow {
    /// The default: only the last month is processed until the user widens it.
    pub const DEFAULT: ProcessingWindow = ProcessingWindow::LastMonth;

    /// Every window, in widening order (drives the client slider).
    pub const ALL: [ProcessingWindow; 6] = [
        Self::NewOnly,
        Self::LastMonth,
        Self::ThreeMonths,
        Self::SixMonths,
        Self::OneYear,
        Self::Everything,
    ];

    /// Stable wire/DB string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NewOnly => "new_only",
            Self::LastMonth => "1_month",
            Self::ThreeMonths => "3_months",
            Self::SixMonths => "6_months",
            Self::OneYear => "1_year",
            Self::Everything => "everything",
        }
    }

    /// Parse a DB/FFI value, falling back to [`DEFAULT`](Self::DEFAULT) only via
    /// the caller (returns `None` here so callers can distinguish bad input).
    pub fn from_str(s: &str) -> Option<ProcessingWindow> {
        match s.trim() {
            "new_only" => Some(Self::NewOnly),
            "1_month" => Some(Self::LastMonth),
            "3_months" => Some(Self::ThreeMonths),
            "6_months" => Some(Self::SixMonths),
            "1_year" => Some(Self::OneYear),
            "everything" => Some(Self::Everything),
            _ => None,
        }
    }

    /// The earliest message date still inside the window, relative to `now`.
    /// `Everything` has no cutoff (returns `None` — process all history). Months
    /// are approximated as 30-day spans, which is plenty precise for a window.
    /// `NewOnly` has no anchor here, so it cuts off at `now`; use
    /// [`cutoff_since`](Self::cutoff_since) with the stored anchor instead.
    pub fn cutoff(self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        self.cutoff_since(now, None)
    }

    /// Like [`cutoff`](Self::cutoff), but `NewOnly` cuts off at `since` — the
    /// moment the user picked it — so mail arriving afterwards stays in window.
    pub fn cutoff_since(
        self,
        now: DateTime<Utc>,
        since: Option<DateTime<Utc>>,
    ) -> Option<DateTime<Utc>> {
        let days = match self {
            Self::NewOnly => return Some(since.unwrap_or(now)),
            Self::LastMonth => 30,
            Self::ThreeMonths => 90,
            Self::SixMonths => 180,
            Self::OneYear => 360,
            Self::Everything => return None,
        };
        Some(now - Duration::days(days))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triage_label_round_trips() {
        for label in TriageLabel::ALL {
            assert_eq!(TriageLabel::from_str(label.as_str()), Some(label));
        }
        assert_eq!(TriageLabel::from_str("nonsense"), None);
        // Tolerates surrounding whitespace from a chatty model.
        assert_eq!(TriageLabel::from_str("  fyi "), Some(TriageLabel::Fyi));
    }

    /// A list saved before the five 2026-10-20 built-ins existed: they are
    /// appended after the custom label, unedited old texts are refreshed, an
    /// edited one is kept, and the merged list validates.
    #[test]
    fn merge_builtin_labels_upgrades_an_old_stored_list() {
        let mut old: Vec<TriageLabelDef> = TriageLabel::ALL[..8].iter().map(|&l| l.into()).collect();
        for (label, description, not_for) in LEGACY_TEXTS {
            let l = old.iter_mut().find(|l| l.slug == label.as_str()).unwrap();
            l.description = description.into();
            l.not_for = not_for.into();
        }
        old.iter_mut().find(|l| l.slug == "action_required").unwrap().description = "Our own wording".into();
        old.push(TriageLabelDef {
            slug: "legal_review".into(),
            name: "Legal review".into(),
            description: "Contracts legal must read".into(),
            not_for: String::new(),
            color: None,
            builtin: false,
            enabled: true,
        });
        assert!(validate_labels(old.clone()).is_err(), "the old list lacks built-ins");

        let merged = merge_builtin_labels(old);
        let slugs: Vec<&str> = merged.iter().map(|l| l.slug.as_str()).collect();
        assert_eq!(slugs[8], "legal_review");
        assert_eq!(&slugs[9..], ["payment_due", "to_review", "read_later", "receipt", "notification"]);
        let fyi = merged.iter().find(|l| l.slug == "fyi").unwrap();
        assert_eq!(fyi.description, TriageLabel::Fyi.description());
        assert_eq!(fyi.not_for, TriageLabel::Fyi.not_for());
        assert_eq!(merged.iter().find(|l| l.slug == "action_required").unwrap().description, "Our own wording");
        assert!(validate_labels(merged.clone()).is_ok());
        assert_eq!(merge_builtin_labels(merged.clone()), merged, "a complete list is left alone");
    }

    #[test]
    fn processing_window_round_trips() {
        for w in ProcessingWindow::ALL {
            assert_eq!(ProcessingWindow::from_str(w.as_str()), Some(w));
        }
        assert_eq!(ProcessingWindow::from_str("bogus"), None);
    }

    #[test]
    fn processing_window_cutoffs() {
        let now = Utc::now();
        assert!(ProcessingWindow::Everything.cutoff(now).is_none());
        let month = ProcessingWindow::LastMonth.cutoff(now).unwrap();
        assert!(month < now);
        // Wider windows reach further back.
        let year = ProcessingWindow::OneYear.cutoff(now).unwrap();
        assert!(year < month);
        // New-only cuts off at its anchor, not at a fixed span.
        let since = now - Duration::hours(2);
        assert_eq!(ProcessingWindow::NewOnly.cutoff_since(now, Some(since)), Some(since));
        assert_eq!(ProcessingWindow::NewOnly.cutoff(now), Some(now));
    }
}
