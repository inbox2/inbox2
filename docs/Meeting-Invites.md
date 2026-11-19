# Meeting Invites (ICS) — parse, RSVP, add to calendar

Reading `text/calendar` events in email and acting on them from an Outlook-style
banner just below the email header. An ICS is one of two things, and the banner
branches on which:

- **`METHOD:REQUEST` with an organizer** — an invitation. Accept / Tentative /
  Decline, answered back to the organizer.
- **anything else** (`METHOD:PUBLISH`, or a bare VEVENT naming no METHOD at all —
  appointment confirmations, bookings, tickets) — nothing to answer, so the
  action is **Add to calendar**. See [Add to calendar](#add-to-calendar).

The rest of this section is the RSVP half. Two worlds, two mechanisms — the same split as everything else in
inbox2 (see the "two sync modes" invariant in the root `CLAUDE.md`):

- **MX channels (inbox2-hosted domains)** — we implement RSVP ourselves: parse
  the invite server-side, store it, and email a `METHOD:REPLY` back to the
  organizer.
- **Local channels (Gmail / Microsoft / IMAP)** — RSVP writes **back to the
  source**: through the provider's calendar API when the invite maps to a synced
  event, otherwise by emailing a `METHOD:REPLY`.

On the **MX path this is no longer only an answer to the organizer**: accepting
also places the event on the member's own calendar via `CalendarInviteImport`,
and declining removes that copy. See [Calendar.md](Calendar.md). Inbound
`METHOD:REPLY` and `METHOD:CANCEL` are handled there too, rather than ignored.

For **local channels** it remains true that putting the event on a calendar is
the `CalendarAdapter`'s job.

---

## MX path (Rails)

**Which invites are stored.** `REQUEST` and `PUBLISH` (and a METHOD-less VEVENT,
treated as PUBLISH — RFC 5545 says METHOD is what makes an iCalendar object a
scheduling message). `REPLY`/`CANCEL`/`COUNTER` are how invitations *we* sent come
back and update the stored event instead (docs/Calendar.md). Only a REQUEST gets an
`rsvp_status`; a confirmation has nothing to answer, and a status on it would render
as an unanswered invite. `Message::CALENDAR_METHOD_REQUEST` / `_PUBLISH` are the
constants.

**Inbound parse.** `InboundMailProcessor#parse_and_store_invite` runs after the
message + attachments are stored (skipped for sealed/E2EE rows — no server-side
plaintext). It reads the raw MIME with the `mail` gem and pulls the first
`text/calendar` part — this is deliberate: a bare `text/calendar` part with no
`Content-Disposition` never becomes an attachment row (the MTA parser files it
into `body_plain`), so the raw message is the only reliable source.
`IcsParser` (extended to read the VCALENDAR-level `METHOD`) parses the first
VEVENT. Only `METHOD:REQUEST` is stored. The result lands on the message:

- `messages.calendar_invite` (jsonb) — `{method, uid, summary, description,
  location, start, end, all_day, organizer_email, organizer_name, sequence}`.
- `messages.rsvp_status` (string) — starts `needs_action`; vocabulary shared
  with `CalendarAttendee::RESPONSE_STATUSES` (no duplicated enum). `Message::
  RSVP_STATUSES` / `RSVP_RESPONSES` are the constants.

**Serialize.** `MessageSerializer` exposes `invite` (the jsonb merged with the
current `rsvp_status`), null on non-invites.

**RSVP.** `POST /api/v1/orgs/:org/messages/:id/rsvp` `{status: accepted|declined|
tentative}` → `MessagesController#rsvp`. Scoped through `visible_conversations`
(E3 — a domain-scoped member can't answer another domain's invite). It:
1. sets `rsvp_status`,
2. builds a `METHOD:REPLY` via `IcsReply.build` (echoes the request's UID +
   SEQUENCE) and creates an **outbound `Message`** from the invited address to
   the organizer, threaded onto the invite (`in_reply_to`/`references_header`),
   carrying the reply on `messages.calendar_reply` (text),
3. hands that message to the normal outbound pipeline
   (`OutboundDeliveryJob` → `OutboundMailPublisher` → NATS → Go SMTP sender),
4. broadcasts `message_rsvp` on `organization_<key>` for realtime.

**Send.** `OutboundMailPublisher#compose_rfc5322` grew one branch: when
`message.calendar_reply` is present it forces the `multipart/mixed` wrapper and
appends a `text/calendar; method=REPLY` part (base64). `method=REPLY` in the
Content-Type is what Outlook/Google read to record the response — an attached
`.ics` without it is often ignored.

---

## Local path (Rust core)

The core lives in `ui/desktop/core/`. Nothing is stored — the parser runs on the
attachment bytes on demand.

- **`sync/ics.rs`** — a tiny hand parser (`parse_ics`) for the VEVENT fields a
  banner needs + `build_reply` (`METHOD:REPLY` writer) + `response_to_partstat`.
  Not a general calendar engine — the real calendar sync is `calendar.rs`
  hitting the Google/Graph APIs. Self-tested (`cargo test -p inbox2-core ics`).
- **`SyncEngine::invite_from_attachment`** (`sync/engine/calendar.rs`) —
  downloads the `text/calendar` attachment, parses it, and matches its `UID`
  against `calendar_events.ical_uid` for the account
  (`SyncStore::event_by_ical_uid`) so the banner can preselect the answered
  button. Returns a `ClientInvite` (parsed fields + `matched_event_key` +
  `current_status`).
- **`SyncEngine::respond_invite`** — two rails:
  - the invite maps to a synced event **and** the account has a calendar API
    (Gmail/Microsoft) → `respond_calendar_event_by_key` (the existing RSVP path,
    Google PATCH attendee / Graph accept·decline·tentativelyAccept);
  - otherwise (IMAP, or an unsynced calendar) → build a `METHOD:REPLY` and
    `enqueue_send` it to the organizer via the durable **outbox** (threaded onto
    the invite). No new queue.

**FFI** (`ffi.rs`, next to `respond_to_event`): `invite_for_attachment(account,
message, attachment) -> Option<String>` (JSON `ClientInvite`) and
`respond_to_invite(account, message, attachment, response)`. Regenerate the
Swift/Kotlin bindings on the next `--xcframework` / Android core rebuild.

**Desktop (Tauri)** wraps both as commands `invite_for_attachment` /
`respond_to_invite` (`src-tauri/.../commands/interactive.rs`, registered in
`lib.rs`).

---

## Clients

All three read `AttachmentInfo.mimeType` (already plumbed) to detect a
`text/calendar` / `.ics` attachment, and branch by message source:

- **Web / desktop** — `components/MeetingInvite/MeetingInvite.jsx`, rendered in
  `MessageCard` just below the header when expanded. MX messages use
  `message.invite` from the serializer + `POST …/messages/:id/rsvp`; local
  (desktop, Tauri) messages resolve via the `invite_for_attachment` command and
  RSVP via `respond_to_invite`. The provider shim adds `inviteForAttachment` /
  `respondToInvite` (`lib/providers/index.js`).
- **iOS** — banner in `Sources/Views/MessageCard.swift`; engine wrappers in
  `EngineModel.swift`.
- **Android** — banner in `ui/screens/ReaderScreen.kt`; wrappers in
  `engine/EngineModel.kt`.

The banner shows Accept / Tentative / Decline, highlights the answered choice,
and reflects the current status when the invite is already answered.

**Answering from the notification card.** A new-mail alert whose message carries
an answerable invite shows Accept / Decline above its normal action row, styled
like a meeting reminder — see "Meeting invitations on the mail card" in
[Notifications.md](Notifications.md). Desktop/local channels only, and the shared
predicate + formatting live in `ui/web/src/lib/invites.js` (which is where
`isRequest` moved to, so the banner and the card can't drift).

**Which branch a banner takes** is one predicate, kept identical in four places
(`ClientInvite.isRequest` on iOS and Android, `isRequest()` in `MeetingInvite.jsx`,
and the METHOD arm in `parse_and_store_invite`):

1. a stated METHOD other than REQUEST → not answerable, offer **Add to calendar**;
2. otherwise an MX invite (no `attachment_id`) is a REQUEST by construction;
3. otherwise a local-channel invite must also name an organizer — an RSVP with
   nobody to send it to isn't worth offering.

---

## Add to calendar

For the ICS that asks for no answer. Two rails again, matching the two sync modes.

**Local channels** — `SyncEngine::add_invite_to_calendar` (`sync/engine/calendar.rs`)
downloads + parses the attachment and writes it through the account's own calendar
API onto its **primary writable** calendar (`default_calendar_provider_id`; read-only
shared/subscribed/holiday calendars are skipped, the provider would 403). If the
store holds no calendar yet it runs `sync_calendars` once and retries — on a phone
the calendar list is only populated as a side effect of a mail sync, so a freshly
seeded account reaches here with an empty table and no real problem.

Idempotent twice over: an ICS whose UID already maps to a synced event returns that
event instead of creating a second, and **Google uses `events.import`**, not
`insert`. That matters more than it sounds — `insert` mints a *fresh* `iCalUID`, so
the created event could never match the ICS's UID again: the banner would offer to
add it forever and every tap would duplicate it. `import` is documented as "add a
private copy of an existing event to a calendar", takes `iCalUID`, keeps it, and is
idempotent on it. It's `CalendarAdapter::import_event`, whose default implementation
is a plain create — Graph can't set `iCalUId` (read-only), so it inherits that.

Because Graph therefore *can't* be matched by UID, and because even on Google the
resync may not have landed the row yet, each add also records
`engine_settings["ics_added:<account>:<uid>"] = <event key>`, which
`invite_from_attachment` consults when the UID lookup misses. A present-but-empty
value still means added — it just has no event to deep-link to.

FFI `add_invite_to_calendar(account, message, attachment, calendar_provider_id,
device_timezone)`; Tauri command of the same name; `addInviteToCalendar` in the web
provider shim and in both mobile `EngineModel`s.

**MX** — `POST /api/v1/orgs/:org/messages/:id/calendar-import` →
`MessagesController#calendar_import`, scoped through `visible_conversations` (E3).
It hands the stored `calendar_invite` to the existing `CalendarInviteImport` with
`accepted`, which upserts on the UID (so importing twice updates the one event), and
emails nobody — nobody asked for an answer.

### Time zones

The thing to get right, and the thing that was wrong. `parse_dt` used to read
`DTSTART;TZID=Europe/Amsterdam:20250916T100000` and keep only the wall clock,
**discarding the zone** — fine while the reader happened to sit in that zone,
silently an hour or more out otherwise, and actively wrong once we started writing
events to a calendar API.

`InviteInfo.timezone` now carries it: the `TZID`, `UTC` for a `Z`-suffixed value, or
`None` for an all-day date and for a floating time (RFC 5545: "whatever zone the
reader is in" — the clients pass their own zone as `device_timezone` for that case
only).

Two rules on the write path:

- **Hand the provider a bare wall clock plus a separate `timeZone`** and let it do
  the arithmetic — no tz database in the core. `ics::wall_clock` strips any offset
  first, because Graph rejects a `dateTime` carrying one and Google lets the offset
  silently override `timeZone`.
- **Normalise the TZID to IANA first** (`ics::normalize_tzid`). Google 400s
  ("Invalid time zone definition for start time") on anything else, and
  Outlook-lineage senders routinely write Windows names — the appointment
  confirmation that prompted this feature carried
  `TZID:W. Europe Standard Time`. Three sources, best first: the file's own
  `X-LIC-LOCATION` for that TZID (the sender stating the IANA equivalent), the id
  itself when it already looks IANA (after stripping a `/mozilla.org/…/` style
  prefix), then the CLDR Windows→IANA table in `windows_to_iana`. An unrecognised
  name yields `None` and falls back to the reader's zone rather than a hard failure.

Rails' `IcsParser` already resolved TZID correctly (`Time.find_zone`), so only the
Rust side needed this.

---

## Detected meetings (no ICS)

Plenty of mail books a meeting in prose and attaches nothing: *"Hierbij bevestig ik
onze afspraak voor vrijdag 7 oktober 2026 om 16:30 uur aan de Prins Alexanderlaan
151 in Rotterdam."* Triage reads these out of the body and the banner shows them as a
**detected** event: a dashed border, "Found in this email", and
only **Add to calendar** (never RSVP — there is nobody to answer).

**Extraction.** Jev can't write values, so this rides the text lanes that already
write summaries:

- **Local channels** — the `[summary]` prompt (`bridge/prompts.toml`) returns a third
  field, `meeting` (`null` or `{title, start, end, location}`). The user prompt now
  carries the newest message's date so "next Friday" resolves. `ics::DetectedMeeting::
  from_model` validates it (a real date AND clock time, an end after the start) and
  the worker stores it as JSON on **`messages.detected_meeting`** of the thread's
  newest message — or clears it when a model pass finds none. The snippet fallback
  (no model) leaves it alone. No extra model call.
- **MX** — `MeetingDetector` (OpenAI, `Llm::Client`) runs from `SpaceClassifier#classify`
  on **every** plaintext inbound message without a `calendar_invite` (a confirmation
  is usually a reply, not a new thread), behind a cheap clock-time regex gate so most
  mail never reaches OpenAI. Paid plans only, like the rest of triage. Stored on
  `messages.detected_meeting` (jsonb, migration `20260922000001`). Sealed mail: never.

Times are the **sender's wall clock, no zone** (a floating time). They're read in
the viewer's zone at display and at import.

**Serving.** One shape everywhere — the invite shape with `method: PUBLISH`,
`detected: true` and UID `detected-<message key>@inbox2`:

- MX: `MessageSerializer#invite` emits it when there is no `calendar_invite`
  (`MeetingDetector.as_invite`). `POST …/messages/:id/calendar-import` accepts
  `time_zone` (IANA) and resolves the floating times in it (else the org's zone).
- Local: `SyncEngine::detected_invite(account, message)` (SQLite only, no provider
  fetch) → `ClientInvite` with `detected: true`, `matched_event_key` from the
  `ics_added:` marker once added. `add_detected_meeting_to_calendar(account, message,
  calendar_provider_id, device_timezone)` shares `add_info_to_calendar` with the ICS
  path. Tauri commands and UniFFI methods of the same names; `detectedInvite` /
  `addDetectedMeetingToCalendar` in the web provider shim and both mobile `EngineModel`s.

**Already scheduled.** The banner loads the calendar ±2h around the meeting ("Around
this time" — web `InviteSchedule`, now also on iOS/Android). For a detected meeting,
an event starting within **15 minutes** of it is taken to be it: the banner says
"Already on your calendar: <title>" instead of offering to add a duplicate. Time only,
not title — the detected title is the model's wording.

Known limits: a time written in words ("half vijf") misses the MX regex gate; all-day
appointments (a date, no time) are never detected; the MX web banner has no
"Around this time" (local SQLite only, as before).

## Gotchas

- **Bare `text/calendar` lands in `body_plain`.** The MTA only makes an
  attachment row when the part has `Content-Disposition: attachment`. MX parses
  from the raw message, not the attachment list, for exactly this reason.
- **Sealed (E2EE) MX rows can't be parsed server-side** — no plaintext. The
  invite banner there would have to be client-side (not built; noted).
- **RSVP vocabulary is shared** with `CalendarAttendee::RESPONSE_STATUSES` and
  `ics::response_to_partstat` — don't hardcode `"accepted"` etc.
- **Reply threading matters** — the `METHOD:REPLY` carries the request's UID +
  SEQUENCE and threads onto the invite, or the organizer's client won't
  correlate it.
- **`DURATION` isn't parsed.** An ICS with no `DTEND` gets `default_end`'s +1h
  (+1 day for all-day, since all-day DTEND is exclusive). Confirmations in the wild
  all carry DTEND; parse DURATION if one ever shows up without it.
- **The target calendar isn't selectable** — always the account's primary writable
  one. `add_invite_to_calendar` takes a `calendar_provider_id` for when it should be.
- **Events added before `events.import` landed** carry Google-assigned UIDs and will
  keep offering "Add to calendar"; delete and re-add to fix one.
