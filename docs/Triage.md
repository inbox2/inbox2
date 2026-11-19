# Triage (Jev)

Triage decides, for every thread, **which Space it belongs in**, **which action label it
carries** and **how urgent it is**. Since 2026-09-19 those three judgments come from
**Jev**, TypeSafe's System One model (`api.typesafe.ai`), on both sync modes. The
OpenAI / on-device prompt-and-parse classifier is gone from triage.

Summaries are **not** triage. Jev can't write text, so summaries stay on the
existing text lanes: OpenAI on MX (`Llm::Client`), and the local-channel model lanes
(on-device Qwen/Gemma/Apple FM, or the user's OpenAI key) in the Rust core.

| | MX (Rails / Postgres) | Local channels (Rust core / SQLite) |
|---|---|---|
| Jev key | server-side `TYPESAFE_API_KEY` (k8s secret) | the user's own key, added as the "Jev" AI integration in settings |
| No key | threads go to the holding pen, no label, no priority | deterministic rules only; ambiguous threads stay unlabelled |
| Plan gate | `Plan#ai_triage` (paid/max) + `TriageBreaker` limits | none (user's key, user's bill) |
| Summary | OpenAI summary-only call, new threads | existing model lanes, summary-only prompt |
| Labels | org `triage_labels` table (built-ins + custom) | engine setting `triage_labels` (built-ins + custom) |
| Spaces | org `spaces` (name, description, `not_for`) | pushed `space_taxonomy` from the org, plus the device's personal Spaces |

## The Jev call

One request per thread: `POST https://api.typesafe.ai/v1/systemone`,
`Authorization: Bearer <key>`, model pinned to **`jev-1.13.0`** (Rails: `TYPESAFE_MODEL`
env override; Rust: constant). Pinning matters: the thresholds below were set on this
model and `jev-latest` moves on release.

### State

```json
{
  "owner": "ops@acme.com",
  "thread": {
    "subject": "Quote for 200 units",
    "messages": [
      {"direction": "received", "from": "jan@example.nl", "text": "Hi, could you send a quote…"}
    ],
    "last_direction": "received"
  }
}
```

- `messages`: oldest first, the newest **8**, each cut to **1500** chars, quoted text
  stripped. `direction` is `received` or `sent` (sent = by the owner).
- MX triages a single inbound message: one entry. Sealed (e2ee) mail uses the MX
  excerpt as that one entry's `text`.
- `owner`: the mailbox address the mail arrived at (MX), or the channel address (local).
  May be `""` when unknown.

### Questions

Built by `JevTriage.questions` (Ruby) and `triage::jev_questions` (Rust). **Both must
produce byte-identical JSON** for the parity fixture (`fixtures/parity/fixtures.json` →
`jev_triage`).

```json
{
  "label": {
    "type": "choice",
    "instructions": {
      "question": "Which label describes what `thread` needs from its owner (`owner`) right now?",
      "focus": "Judge the newest message in the context of the thread. Bulk, marketing, newsletter and automated mail never needs a personal reply from the owner: label it by what it is, such as a bill to pay, a booked appointment, a statement to review, something to read, a receipt or a system notification."
    },
    "criteria": { "<slug>": {"name": "…", "what": "…", "not_for": "…"} }
  },
  "priority": {
    "type": "score",
    "instructions": "How soon does the owner of `thread` need to pay attention to it?",
    "criteria": ["<5 levels, below>"]
  },
  "space": {
    "type": "choice",
    "instructions": {
      "question": "Which team space should `thread` be filed in?",
      "focus": "Judge the main purpose of the thread."
    },
    "criteria": {
      "<slug>": {"name": "…", "what": "…", "not_for": "…"},
      "no_match": {"what": "A genuine email that none of the spaces above clearly covers"}
    }
  }
}
```

- `label.criteria`: every **enabled** label, in position order. `not_for` is omitted
  when blank. `what` is the label's description.
- `space` is only asked when there is at least one classifiable Space and (local)
  Space sorting is on. `space.criteria` lists classifiable spaces in position order;
  `what` is the description (falls back to the name), `not_for` omitted when blank.
- Omit `label` when a deterministic rule already decided it (local channels), omit
  `space` when the thread already has one (MX: `space_id` set).
- Spam is never asked. Rspamd owns the Spam folder.

### Reading the answers

| Question | Rule |
|---|---|
| `label` | take `choice`. Unknown slug (a label deleted mid-flight) → `fyi`. |
| `priority` | store `score` as-is (float, 0.0–4.0). |
| `space` | `choice != "no_match"` **and** `probabilities[choice] >= 0.5` → that Space; otherwise the holding pen (`triage`). |

Provenance (`triage_source`): `jev:<model echoed by the response>`, e.g.
`jev:jev-1.13.0`. Local channels prefix rule decisions as before:
`rule:payment`, `rule:payment+jev:jev-1.13.0` (rule label, Jev priority/space). MX
writes the same shape for its one rule: `rule:otp`, `rule:otp+jev:jev-1.13.0`.

### Deterministic rules (before Jev)

A rule that fires decides the label; Jev is then asked priority + space only
(`ask_label: false`). Local channels (`detect_label`, `core/src/sync/store/ai_triage.rs`),
first match wins:

| # | rule | label | source |
|---|---|---|---|
| 1 | bill / invoice / statement / payment / renewal terms (EN + NL) — **soft**: with a Jev key Jev decides the label (paid receipts and statements use the same words); the rule labels only without Jev or when Jev gives no label | `payment_due` | `rule:payment` |
| 2 | sign-in **code** in the newest inbound message (`otp::detect`) | `notification` | `rule:otp` |
| 3 | e-signature request, password reset, account verification | `action_required` | `rule:action` |
| 5 | calendar invite, meeting join, appointment reminder (body, then subject) | `scheduling` | `rule:scheduling`, `rule:scheduling_subject` |
| 6 | bulk / marketing signals (one strong or two medium) | `fyi` | `rule:marketing_strong`, `rule:marketing_medium` |

MX (`SpaceClassifier`): a sign-in **code** in the inbound message (a link alone goes to Jev; newsletters looked like one, 2026-10-20)
(`OtpDetector`, the Ruby twin of `otp.rs`) → `notification`, `rule:otp` — the label
is written even with no Jev provider configured. Sending sets `waiting_reply`
(`rule:sent`).

Rule 1's terms are coarse ("invoice", "autopay", "your statement" also match a paid
receipt or a statement to review) and a rule label is never re-asked, so it can
pre-empt Jev's `receipt` / `to_review`.

### Errors

401 → key invalid (surface in settings; local: stop calling until the key changes).
402 / 403 → the account is blocked (credits ran out, billing; not in TypeSafe's
documented table, so any 402/403 counts). Local: the claimed job goes back to
`pending` uncharged, the queue pauses and one job probes every minute; an answered
call resumes it. Skipping would mark every thread done with no label or Space.
429 / 529 / 5xx / timeout → transient, retry with backoff (MX: job retry; local: the
worker's defer path). 422 → a bug in our request: log the body, don't retry.
Timeouts: 5 s connect, 20 s total.

## Built-in labels

Wire-stable slugs (stored in both databases, rendered by every client). Every org /
engine starts with these thirteen; their description and `not_for` are editable, their
slug is not, and none can be deleted. All but `fyi` can be disabled (`fyi` is the
fallback).

The last five (`payment_due` … `notification`, 2026-10-20, docs/plans/lore.md §1) are
appended: an org that already has labels gets them after its last label
(`TriageLabel.ensure_defaults`), and a stored local list gets them appended on load
(`triage::merge_builtin_labels`). Both also refresh a built-in still carrying its
pre-2026-10-20 text (`action_required`, `fyi`, `scheduling`) to the current one; an
edited text is kept. Threads labelled before the upgrade are re-judged once — see
"Upgrade re-triage" below.

| slug | name | what | not_for |
|---|---|---|---|
| `needs_answer` | Needs answer | A real person directly asked the owner a question or made a request and is waiting for the owner's personal reply | Bulk, marketing, newsletter or automated mail; questions aimed at someone else |
| `needs_answer_other` | Reply from someone else | A reply is expected, but from someone other than the owner, for example the owner is only copied or the question is aimed at a colleague | |
| `waiting_reply` | Waiting for reply | The owner sent the last message and is waiting for the other side to respond | A closing thanks that ends the conversation |
| `needs_approval` | Needs approval | The owner is asked to approve or authorize someone else's request or work: a pull request, a purchase, time off, an expense, or a document prepared for their sign-off | Bills, invoices or payments the owner has to pay |
| `scheduling` | Scheduling | Arranging or changing a meeting or a time, or a reminder or confirmation of an already-booked appointment with a concrete date and time, automated booking mail included | Order, shipping or delivery updates |
| `action_required` | Action required | The owner must personally complete a concrete task with a consequence: sign a contract, cancel a subscription, verify an account, upload a requested file or fill in a requested form | Marketing calls to action such as get started, learn more or upgrade; bills, invoices or statements to pay or look over |
| `fyi` | FYI | Informational, nothing is needed from the owner: announcements, promotions, product and service updates, threads the owner is only copied on, and anything else that asks nothing | Newsletters and articles worth reading, receipts and order updates, automated system notifications |
| `resolved` | Resolved | The matter is concluded and nothing is left to do, such as a closing thanks or a confirmation that it is done | |
| `payment_due` | To pay | The owner has to pay something: an invoice, bill, payment reminder, failed direct debit or renewal fee that is not already paid or collected automatically | Receipts and invoices that say they are already paid or will be collected automatically |
| `to_review` | To review | Data or a document for the owner to look over, with nothing to answer or do: bank or card statements, reports, dashboards, analytics, shared spreadsheets | Documents the owner must sign or approve |
| `read_later` | Read later | Something worth reading but not urgent: newsletters, articles, essays and product launch letters the owner subscribed to | Promotions, sales and discount offers |
| `receipt` | Receipt | A record of something already done or paid: a receipt, an invoice marked paid or collected automatically, an order, shipping or delivery confirmation | |
| `notification` | Notification | An automated system message: sign-in codes and links, security alerts, password resets, build, deploy, crash and monitoring alerts, app store processing notices | Messages written by a real person |

Client chips (web `lib/triage.js`, iOS `TriageLabel.rowBadge`, Android `TriageLabel`):
`payment_due` → **Pay** (urgent tone), `to_review` → **Review**, `read_later` → **Read**
(open tone); `receipt` and `notification` show no chip, like `fyi` / `resolved`.

## Custom labels

Orgs (MX) and users (local) can add their own labels — slug `[a-z0-9_]{1,40}`, a
name, a description, an optional `not_for`, an optional color. A custom slug may not
collide with a built-in slug or `no_match`. Clients render a known built-in with its
existing badge; any other slug renders as a neutral chip with the label's name
(falling back to the slug, title-cased, when the list isn't loaded).

## Priority levels

The `priority` Score criteria, index = value:

| # | level |
|---|---|
| 0 | No attention needed: can be ignored, archived, or read whenever |
| 1 | Low: worth reading eventually, no action or deadline |
| 2 | Normal: needs a response or action within the next few days |
| 3 | High: needs a response or action today, or blocks someone's work |
| 4 | Urgent: needs immediate attention, such as an outage, a security incident, or a deadline within hours |

UI: score ≥ 3.5 → **Urgent** chip, ≥ 2.5 → **High** chip, below that nothing.

## MX (Rails)

- Env: `TYPESAFE_API_KEY`, `TYPESAFE_MODEL` (default `jev-1.13.0`),
  `INBOX2_CLASSIFICATION_PROVIDER` = `typesafe` (default) | `stub`.
  `OPENAI_API_KEY` stays, for summaries only.
- Schema: `conversations.triage_label` (string), `conversations.triage_priority`
  (float), `conversations.triage_source` (string); `spaces.not_for` (text); table
  `triage_labels` (`tlb_` public ids; `organization_id`, `slug`, `name`, `description`,
  `not_for`, `color`, `builtin`, `enabled`, `position`; unique `(organization_id, slug)`).
- API: `GET/POST/PATCH/DELETE /api/v1/orgs/:org_id/triage-labels[/:id]` (writes are
  admin-only; built-ins can't be deleted, `fyi` can't be disabled, built-in slugs are
  immutable). `ConversationSerializer` adds `triage_label`, `triage_priority`.
  Spaces accept and return `not_for`.
- Flow: a new inbound message on a plaintext thread → `ClassifySpaceJob` → Jev
  (label + priority always; space only while `space_id` is nil) → OpenAI summary on a
  new thread only. Every later inbound message re-runs label + priority. The owner
  sending a reply sets `triage_label = waiting_reply` without a Jev call. A sign-in
  code sets `notification` (`rule:otp`) and Jev answers priority + space only.
  Sealed mail: `TriageSubscriber` feeds the MX excerpt through the same service —
  label, priority and space only, **never a summary** (a stored summary of sealed mail
  is plaintext content; docs/E2EE.md "Output rule").
- Retries: `ClassifySpaceJob` retries a transient Jev error 4× (polynomial backoff);
  when they run out, an unrouted thread goes to the holding pen and a new thread's
  deferred mobile push is still sent.
- `waiting_reply` is set by `MessagesController#create` (a person sending); agent
  (MCP) sends and automated mail (OOO, RSVP, invites) leave the label alone.
- `INBOX2_CLASSIFICATION_PROVIDER=stub` files into `INBOX2_CLASSIFICATION_STUB_SLUG`
  with label `INBOX2_CLASSIFICATION_STUB_LABEL` (default `fyi`), source `stub`.

## Local channels (Rust core)

- Key: secret `typesafe_api_key` (desktop `app_secrets`, iOS Keychain, Android
  `SecureStore`), pushed to the engine with `set_jev_key(Option<String>)`; checked with
  `validate_jev_key(key)`. Tauri commands and UniFFI methods share those names.
- Labels: engine setting `triage_labels` (JSON array of
  `{slug,name,description,not_for,color,builtin,enabled}`), defaulting to the built-ins;
  `get_triage_labels` / `set_triage_labels` over Tauri and FFI.
- Spaces: `set_space_taxonomy` accepts the old `[["slug","description"],…]` pairs or
  `[{slug,name,description,not_for},…]` objects. Desktop, iOS and Android all push
  the org's classifiable spaces when the user belongs to an org.
- Personal Spaces: each device also has its own Spaces, engine setting
  `personal_spaces` (same `SpaceDef` JSON shape), never shown to the team. The
  defaults (single source: `triage::default_personal_spaces`):

  | slug | name | what | not_for |
  |---|---|---|---|
  | `reading` | Reading | Newsletters, digests, blog posts and product updates to read when there's time | Anything that asks the owner to act |
  | `personal` | Personal | The owner's private life: appointments, family and friends, home, car, insurance and personal errands | Work for the company |

  The list Jev sees (`effective_spaces`) is the org's Spaces as pushed, then the
  personal ones, skipping a personal slug that an org Space already uses. With no
  org taxonomy, the personal Spaces alone are enough to ask the `space` question;
  Space sorting (`space_classify_enabled`) still gates all of it. Tauri
  `get_personal_spaces() -> SpaceDef[]` / `set_personal_spaces({ spaces }) -> SpaceDef[]`;
  UniFFI `get_personal_spaces() -> String` / `set_personal_spaces(json) -> String`
  (JSON, like the label methods). Validation: slug `[a-z0-9_-]{1,40}`, unique, not
  `triage` or `no_match`; a name on each (the wire form fills a blank name with the
  slug). An empty list is allowed.
- Re-filing: the engine records the effective list the stored `space_slug`s were
  filed against (`space_taxonomy_filed`). When an org push or a personal-Spaces edit
  changes the effective list (a Space added, renamed or re-described), or no list was
  recorded yet, every thread's Space is cleared and the eligible threads are queued
  for Jev again. Pushing the same list is a no-op.
- Processing window vs the inbox: the window (`new_only`, `1_month` default, …,
  `everything`, by `conversations.updated_at`) bounds **history only**. A thread is
  eligible when it is **open** (`conversations.status = open`, i.e. in the inbox)
  **or** inside the window. Every gate uses that rule: enqueue on a new message
  (checked after the status mirror), `backfill_triage_queue`, `requeue_for_jev`,
  `backfill_space_queue`, `claim_next_triage_job`, and `triage_progress` /
  `triage_diagnostics` (`inWindow`, `done` and `pending` all count that set). An
  old thread that is archived or trashed with a queued job stops being claimable.
  An old open thread that never gets a new message is picked up by
  `backfill_triage_queue`, which runs on the worker's first pass after launch, on
  `set_jev_key` and on `set_processing_window`.
- Detected meetings: the `[summary]` response also carries `meeting`, stored on the
  newest message (`messages.detected_meeting`) — docs/Meeting-Invites.md "Detected
  meetings". MX runs `MeetingDetector` per inbound message instead.
- Worker: deterministic rules first. With a Jev key, one Jev call fills whatever is
  still open (label when no rule fired, priority always, space when sorting is on).
  Without a key: the rule label or nothing. Summaries run separately through the
  existing lanes with the `[summary]` prompt; no model → subject/snippet fallback.
- Schema: `conversations.triage_priority REAL`. The `triage-updated` event payload
  gains `priority` (`{conversationKey, label, priority, summaryShort}`; `label` and
  `priority` may be null).
- Key status: `triage-progress` (and the `triage_progress` snapshot) carries
  `jevStatus` = `missing` | `ok` | `unauthorized`. A 401 flips it to `unauthorized`
  and stops calls; pushing a key (even the same one) clears it and retries.
- Degraded state: `triage-progress` also carries `jevError` (rejected key or a
  blocked account's message) and `summaryError` (the summary lane's last failure,
  e.g. OpenAI quota; cleared by the next summary that works), both `null` when
  fine. The desktop activity panel shows them.
- A key arriving later re-enqueues processed in-window threads missing a label,
  priority or (sorting on) space; they get one Jev call and keep their summaries.
  `triage-progress.done` counts processed threads, not labelled ones, so a keyless
  inbox still reaches 100%.
- Provenance appends the summary engine: `rule:payment+jev:jev-1.13.0+model:openai:gpt-4o-mini`
  (the `model:` part is who wrote the summaries; absent = subject/snippet fallback).
- Eval: `triage-eval --jev-key` (or `$TYPESAFE_API_KEY`); the desktop Triage Lab and
  the mobile `run_triage_eval(fixtures_json)` use the engine's key and labels.

## Manual triage

The Triage menu (toolbar, reader ⋯ menu, and every list/search/Spaces-board
context menu; `triageSubmenu` in `ui/web/src/lib/conversationActions.js`, data
from `hooks/useManualTriage.js`) has **Move to Space ›**, **Label ›** (current
ones checked) and **Re-run Jev**, above the Eisenhower quadrants. Bulk selections
and the composer keep the quadrants only. Local vs MX: a row with a
`providerType` says so; otherwise local rows carry `key`, MX rows only `id`.

| | MX (Rails) | Local (Rust core) |
|---|---|---|
| Move to Space | `PUT /orgs/:org_id/conversations/:id/space` `{space_id: spc_…}` (any org Space, holding pen included) | Tauri `set_conversation_space({conversationKey, slug})` / UniFFI `set_conversation_space(key, slug)`; slug ∈ `get_effective_spaces()` or `triage`; emits `space-updated` |
| Set label | `PUT /orgs/:org_id/conversations/:id/triage-label` `{label}` → 200 `{conversation}`; 422 unknown/disabled label; `triage_source = manual` | Tauri `set_conversation_label({conversationKey, label})` / UniFFI `set_conversation_label(key, label)`; enabled slugs only; `triage_source = manual`; emits `triage-updated` |
| Re-run Jev | `POST /orgs/:org_id/conversations/:id/retriage` → 202 `{conversation}`; enqueues `ClassifySpaceJob(id, new_thread: false)` (no summary, no push). 422: no AI triage on the plan / no provider, archived/spam/trash, no inbound or sealed newest message. 429: org breaker cap | Tauri `retriage_conversation({conversationKey})` (`rerun_jev`): rules + Jev for label, priority and Space; works without a summary model (summaries kept). Error `Add a Jev key in Settings to re-run triage` when there's no key and no rule fires |

Stickiness:

- **Space.** MX only auto-files while `space_id` is nil, so a manual Space holds.
  Local sets `conversations.space_manual = 1`: the worker never asks Jev for a
  Space on it, and re-filing skips it. If its Space leaves the effective list,
  the Space and the flag are cleared and Jev files the thread again.
- **Label.** Holds until a **new message** arrives in the thread; then Jev judges
  label and priority again (both modes). Local records the thread's newest
  message key at the time (`conversations.label_manual_msg_key`); until it
  changes, the manual label beats rules and Jev, and a priority-only fill is
  sourced `manual+jev:<model>`.
- **Re-run Jev** asks again from scratch: it overwrites a manual label, and
  locally it also clears `space_manual` so the Space is re-filed. On MX a
  manual Space stays (the job only files threads without one).
- MX detail (`GET …/conversations/:id`) returns `triage_label`,
  `triage_priority` and `space` so the reader can check the current ones. MX
  writes broadcast a `conversation-patched` DOM event (`{id, patch}`) that the
  inbox list and open detail apply in place.

## Next-action fields

Lore shows a due date and an amount on an item. They are **extracted by rules, not a
model**, every time the label is written (Jev, a rule, a manual label), from the
subject + the newest inbound message's text (quotes stripped) + that message's UTC day.
Only for `payment_due`, `action_required`, `needs_approval`, `scheduling`,
`needs_answer`; any other label clears them.

- Amount: `€ EUR $ USD £ GBP AED PKR HK$` before or after a number in EU
  (`1.234,56`, `386,00`, `2.400,-`) or US (`1,234.56`) form. The first amount with a
  cue word (`total`, `totaal`, `amount due`, `te betalen`, `bedrag`, `balance`, `due`)
  in the 40 chars before it wins, else the largest. Stored in minor units.
- Due date: a cue (`due`, `before`, `by`, `deadline`, `uiterlijk`, `vóór`, `voor`,
  `vervaldatum`), optional filler (`date`, `on`, a weekday, …), then `2026-10-24`,
  `24-10-2026` / `24/10/2026` / `24.10.2026` (day first), `24 Oct 2026`,
  `24 oktober`, `October 24`. No year → this year, or next year if passed. Dates
  before the message day are ignored. Else `within N days` / `binnen N dagen` →
  message day + N.
- Twins: `api/app/services/next_action_extractor.rb` ↔ `core/src/next_action.rs`,
  held to `fixtures/parity/fixtures.json` → `next_action`.
- MX: `conversations.next_action_due_on` (date), `next_action_amount_cents` (bigint),
  `next_action_currency` (string); written in `SpaceClassifier#triage` and
  `PUT …/triage-label`. Sealed mail: never (no server plaintext). Every conversation
  row (index, detail, sync — so the MX mirror's `payload` too) carries
  `next_action_due_on` (`"YYYY-MM-DD"`), `next_action_amount_cents`,
  `next_action_currency`, all `null` when not found.
- Local: same three columns on SQLite `conversations` (`TEXT`, `INTEGER`, `TEXT`),
  written by `write_triage_result` / `write_jev_fill` / `set_manual_label`
  (`sync/store/lore_triage.rs::refresh_next_action`).
- **Title** (`next_action_title`, ≤ 80 chars, added 2026-10-20): the to-do Lore lists
  instead of the subject ("Pay Schiphol Privium membership invoice"). Unlike the
  fields above it is **model-written**, by the summary call that already runs (no extra
  call): an English imperative of 3–8 words naming the counterpart and the thing. `null`
  when no model ran (rules-only, snippet fallback) or the model gave none; clients fall
  back to the subject.
  - MX: `conversations.next_action_title` (string, limit 80, migration
    `20261020100003`). `SpaceClassifier#summarize` asks OpenAI for
    `{"summary","title"}` (`response_format: json_object`, `SpaceClassifier.parse_summary`;
    a non-JSON reply is taken as the summary line, no title). New threads only, same as
    the summary; sealed mail never. On every conversation row (index, detail, sync payload).
    Backfill: `bin/rails "lore:titles[org_xxx,200]"` — open threads with a Lore to-do
    label (anything but `TriageLabel::NOT_LORE_TODO`) and no title, newest first,
    plaintext only, under the same `TriageBreaker` caps; one summary-sized OpenAI call
    per thread, an existing summary is kept. The re-triage (`LoreRetriageJob`) still
    writes no summary and so no title.
  - Local: SQLite `conversations.next_action_title TEXT`. The `[summary]` prompt
    (`prompts.toml`) returns `"title"` next to `"medium"`/`"short"`
    (`ai_worker::parse_summary_title`: the top-level field only, never the meeting's;
    one line, 80 chars). Written after the summaries whenever a model answered
    (`write_next_action_title`); a failed lane keeps the earlier title. A user's
    `[summary]` override written before the field existed (overrides replace the whole
    section; templates are not versioned) just never yields one: the title stays `null`.

## Auto mode

"Handled for you" buckets suggest by default; a person can switch `fyi`, `receipt`
and `notification` to **auto** (decided 2026-10-20). When one of those labels lands:
`fyi` / `receipt` → archive, `notification` → trash. Never on a manual label, never on
a thread the person sent a message in, never on a thread already out of the inbox.
Provenance: `triage_source` gets `+auto` (e.g. `jev:jev-1.13.0+auto`).

- Local: engine setting `lore_auto` (`{fyi, receipt, notification}`); Tauri
  `get_lore_auto() -> {fyi, receipt, notification}`, `set_lore_auto({ settings })`
  returns what was stored. The triage worker files the thread through
  `perform_conversation_action` (the normal write-back, so it reaches Gmail /
  Microsoft) and emits `triage-updated` with `autoAction: "archive" | "trash"`. Only
  for mail whose newest message is under 72 h old, so a backlog relabelled later (a
  key arriving, the re-triage) is never swept away.
- MX: `users.lore_auto` jsonb. `GET /api/v1/account/lore-auto` →
  `{"lore_auto": {"fyi": false, "receipt": false, "notification": false}}`; `PUT` the
  same shape (unknown keys dropped, non-booleans 422). `LoreAuto.apply` runs after a
  label is written, only when the thread's domain has **exactly one** active human who
  sees it (owners/admins and all-domains members count), using that person's
  setting; never on a shared team inbox. It sets the status like the bulk endpoint
  (`Conversation.update_all_in_order`), so the deferred new-thread push is skipped.

## Upgrade re-triage

The five 2026-10-20 labels only reach newly triaged mail, so a bill triaged before
sits as `action_required` and a newsletter as `fyi`. Once per org / device, open
threads from the last 90 days labelled by Jev or a rule (never by hand) with `fyi`,
`action_required`, `scheduling` or `needs_approval` are judged again, newest 500.
It writes label / priority / Space / next-action fields only: no summary, push,
meeting detection or auto mode.

- MX: `LoreRetriageJob` (recurring, hourly) runs each org with
  `organizations.lore_retriaged_at` NULL on a plan with AI triage, queues
  `ClassifySpaceJob(id, false, true)` 0.5 s apart (so `TriageBreaker` caps apply per
  thread), then sets the marker. Threads whose newest inbound message is sealed are
  skipped. Manual run: `bin/rails "lore:retriage[org_xxx]"` (ignores the marker).
- Local: `SyncStore::lore_retriage`, from the worker's first pass after launch
  (never in `SyncStore::new`), gated by engine setting `lore_labels_retriaged_v1`.
  Rule-labelled threads get the rules again on the spot; Jev-labelled ones lose the
  label and are queued, so the fast path asks Jev for it (summaries kept). Without a
  Jev key those wait and the marker stays unset until a launch with a key.

## Things to know

- **Prompt injection.** Mail is adversarial and TypeSafe says injected instructions in
  the state "can move the answer". The label drives badges and sorting, and — only
  where a person opted a "Handled for you" bucket into auto mode — an archive or
  trash, both undoable. Nothing else auto-acts on it. Keep it that way.
- **Language.** Jev is best in English. Test Dutch mail before trusting it.
- **Privacy.** Mail content (≤ 12 KB per thread) goes to TypeSafe. They don't train on
  requests; zero data retention is enterprise-only.
- **Cost.** $0.042 per million input tokens: roughly $0.0001 per thread.
