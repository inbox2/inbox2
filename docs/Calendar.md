# Calendar (MX)

The server-side calendar: `calendars` / `calendar_events` / `calendar_attendees`
/ `calendar_reminders` in Postgres, the `/api/v1/orgs/:org/{calendars,events}`
surface, and the FullCalendar web UI at `/:orgSlug/calendar`.

**MX only.** Local channels (Gmail/Office365/IMAP) sync calendars entirely
client-side through the Rust core's `CalendarAdapter` — see
[Channels.md](Channels.md). The two never meet on the server; the web calendar
merges them read-only at the client (`useCalendarEvents.js`), and calendar CRUD
is MX-API-only.

Related: [Meeting-Invites.md](Meeting-Invites.md) covers the reading-pane
Accept/Tentative/Decline banner for an emailed invite.

## Data model

| Row shape | Identified by | Meaning |
|---|---|---|
| single | no `recurrence_rule`, no `recurring_event_key` | a one-off event |
| recurring master | `recurrence_rule` set, `recurring_event_key` nil | a series; its own `start_at` is the **first** occurrence |
| occurrence override | `recurring_event_key` = master's key, `original_start_at` = the instance it replaces | one instance moved or edited; `status: cancelled` means that instance was **deleted** (a tombstone) |

This is the Google model, and the columns for it already existed — nothing
before used them.

### Occurrence ids

A recurring series is stored as one row but rendered as many. Each generated
instance is addressed as `<series key>@<occurrence start>`, e.g.
`cev_V1StGXR8Z5jd@20260209T090000Z`. `CalendarEvent.parse_occurrence_id` splits
it back. Nanoid keys never contain `@`, so the split is unambiguous.

Send that id to `PATCH`, `DELETE` or `rsvp` to act on **one instance**; send the
plain `cev_…` key to act on the series. Acting on an instance materializes it as
an override row first (`split_occurrence!`).

Per RFC 5545 an override keeps the **master's `ical_uid`** and is told apart by
`RECURRENCE-ID`. A fresh UID would read as a separate meeting in the recipient's
client and leave the original occurrence sitting there.

### Expansion

`CalendarOccurrences.for_range(scope, from, to)` turns stored rows into the
occurrences a calendar view needs. `GET /events` expands whenever `start`+`end`
are supplied; without a window it stays a plain paginated row listing.

Expansion uses **ice_cube** (already in the Gemfile, previously unused) and runs
in the event's own `timezone`, so a 09:00 standup stays 09:00 across a DST
boundary rather than sliding an hour. A rule ice_cube can't parse logs and
degrades to "master row only" rather than blanking the calendar.

> **Pass an unfiltered scope.** `CalendarOccurrences` must see cancelled rows —
> a cancelled override is the tombstone that suppresses a deleted occurrence.
> Filtering with `not_cancelled` before expansion makes deleted instances
> reappear. The expander applies cancellation itself.

## Internal invitations: one event, many guests

Inviting a colleague does **not** copy the event onto their calendar. There is
one canonical row, and `CalendarEvent.visible_to` widens each member's read
scope to include anything they are an attendee of:

```
visible_to(membership) = events on calendars they own or that are org-shared
                       OR events where any of their Mailbox addresses is an attendee
```

Query-time visibility instead of row-copying is what keeps the model honest:
the organizer sees responses the moment they land, an update cannot drift
between copies, and cancelling really cancels. It is also less code than a
fan-out would have been.

Read and write scopes are deliberately different:

| Scope | Includes | Used by |
|---|---|---|
| `visible_to` | own/shared calendars **+ invitations** | `index`, `show`, `rsvp`, `propose-time` |
| `editable_by` | own/shared calendars only | `update`, `destroy` |

Being invited to a meeting lets you see it and answer it — never retitle,
reschedule or delete it. A guest attempting either gets a 404, same as any
other event they don't own (E3).

Because the guest can already see the original, `CalendarInviteImport` detects
an invitation whose UID is already an event in this org and answers **on that
row** rather than importing a second copy. Without that check, an internal
invite answered from the reading pane would put the same meeting on the
calendar twice and split the RSVP across two rows.

## Invitations

Creating an event with attendees mails a real invitation. Before this existed,
attendees were written to `calendar_attendees` and told nobody — while
`EventEditor.jsx` already promised *"An .ics calendar file is attached"*.

```
create/update event ──> CalendarInviteDispatch ──> IcsRequest (METHOD:REQUEST)
                                │
                                └─> Message(calendar_reply: ics) ──> OutboundDeliveryJob ──> MTA
```

* The ICS rides in `messages.calendar_reply` — the column
  `OutboundMailPublisher` already turns into a `text/calendar` part. The
  `method=` MIME parameter is **read out of the body**, so one column carries
  `REQUEST`, `CANCEL` and `REPLY`.
* Invitations use the normal outbound pipeline, so DKIM signing, suppression and
  delivery tracking apply unchanged.
* `SEQUENCE` bumps on any change in `RESEND_TRIGGERS` (time, title, location,
  all-day, status, recurrence) and on cancellation. Without a higher SEQUENCE,
  recipients' clients discard the update as a stale duplicate.
* Deleting mails `METHOD:CANCEL`. Deleting one instance cancels just that
  instance (split to a row first, so it carries `RECURRENCE-ID`).
* A description-only edit does **not** re-send — it doesn't move anybody's day.
* Updates and cancellations thread onto the event's original conversation via
  `calendar_events.conversation_key`.

### Inbound REPLY / CANCEL

`InboundMailProcessor` routes by `METHOD`:

| METHOD | Handler | Effect |
|---|---|---|
| `REQUEST` | `store_invite` | stored on the message → RSVP banner ([Meeting-Invites.md](Meeting-Invites.md)) |
| `REPLY` | `InboundCalendarResponse.apply_reply` | updates `calendar_attendees.response_status` on the matching event |
| `CANCEL` | `InboundCalendarResponse.apply_cancel` | cancels the event, flags the original invite message `cancelled: true` |
| `PUBLISH` | — | ignored |

Correlation is by `ical_uid`, which is why `CalendarEvent` assigns one after
create. Attendee matching is case-insensitive — otherwise every reply creates a
duplicate attendee row.

### Accepting an emailed invite

Answering the organizer and having the meeting appear in your own week are two
different things. `POST messages/:id/rsvp` now also runs
`CalendarInviteImport`, which upserts the event (idempotent on `ical_uid`) onto
the member's primary calendar; declining removes that copy. Repeating invites
carry their `rrule` through, so they land as a series rather than one orphaned
occurrence.

## Default calendar

Nothing provisioned a calendar, so a brand-new member saw an empty calendar
screen and got a 404 on their first event. `Calendar.primary_for(org, membership)`
find-or-creates one; it is called from `GET /calendars`, from event creation
when no `calendar_id` is given, and from the invite import.

## Free/busy and the scheduling assistant

### Policy: org-wide, busy-only

`GET /events/free-busy` reads across **every** calendar in the org, including
colleagues' private ones, and returns **only** start/end times — merged so
overlapping blocks collapse. That is the deliberate trade Google and Outlook
make, and it is safe precisely because a block carries no title, location,
guest list or event id.

Previously this was scoped to the caller's own visibility, which meant a
teammate with a private calendar read as free all week — making a scheduling
tool built on it actively misleading. The negative assertion in the spec is now
that no *detail* crosses the line, not that the time is hidden.

Two further fixes over the original query: being the **organizer** counts as
busy (an event you created but never added yourself to as an attendee used to
leave you looking free during your own meeting), and recurring series are
expanded. Declined invitations don't make you busy.

A `title` rides along with a block **only** for events on calendars the caller
could already open — `FreeBusy`'s `detail_calendar_ids`.

### `GET /events/availability`

The scheduling assistant behind the "Find a time" popup. One request returns
everything the grid needs; drawing it should not cost five round trips.

```jsonc
{
  "attendees": [{
    "email": "…", "name": "…", "internal": true,
    "timezone": "Europe/Amsterdam",
    "availability_known": true,          // false for outside guests
    "working_hours": { "start_hour": 9, "end_hour": 17, "days": [1,2,3,4,5] },
    "busy": [{ "start": "…", "end": "…", "title": "…" }]
  }],
  "suggestions": [{ "start": "…", "end": "…", "outside_working_hours": ["…"] }]
}
```

* The requesting member is always on the grid — Outlook and Google both put
  you on the first row without having to invite yourself.
* **`availability_known: false` means "we have no calendar for this person",
  not "free".** An outside guest must never be drawn as available; the client
  renders their row as *No availability*.
* Suggestions are ranked so slots inside everyone's working day come first — a
  technically-free 03:00 is not a real suggestion. Slots are scanned on a
  30-minute lattice and the scan is hard-capped.
* Working hours are evaluated in **each attendee's own timezone**, so 09:00
  means their morning.

`GET /events/directory` lists the org's own addresses for the colleague picker.

### Working hours and out of office

Both live on the **user's profile**, alongside `default_timezone` — the
attribute they are meaningless without — and are edited in **Settings ›
Scheduling › Availability** (`AvailabilitySettings.jsx`, next to the meet links
they drive; they used to sit on Account & Profile). A user who never picked a
zone is `UTC`, which shifts every meet-link slot — the page offers "Use
<device zone>". A member of two
orgs keeps one working day across both.

| Column | Shape |
|---|---|
| `users.working_hours` | jsonb `{"start_minute": 540, "end_minute": 1020, "days": [1,2,3,4,5]}` |
| `users.out_of_office_start` / `_end` / `_message` | one period + an optional note |

* **Minutes from local midnight**, not hours, so 09:30 works and comparison is
  integer arithmetic. Evaluated in the person's own timezone.
* `working_hours` is **nullable**, and NULL means "never set" →
  `User#effective_working_hours` falls back to `User::DEFAULT_WORKING_HOURS`. An
  empty working day would make every suggestion read as out-of-hours.
* Params arrive as strings from a form, and jsonb stores exactly what it is
  given — `User#normalize_working_hours` coerces on the model so every writer is
  covered, not just the account endpoint.
* **Out of office is busy.** The period is folded into the person's busy blocks
  (via `FreeBusy.merge_periods`, so it doesn't double up with real meetings) and
  suggestions never land inside it. It is also reported as its own
  `out_of_office` field so the grid can label the row *OOO* rather than showing
  an unexplained wall of shading, and the verdict line says "X is out of office"
  rather than "clashes with X".
* Migration `20260819000001_add_scheduling_preferences_to_users.rb`. Verified
  equivalent by loading `schema.rb` into one scratch DB, migrating from zero into
  another, and diffing `pg_dump --schema-only` — identical.

## Out-of-office auto-reply

Mail arriving for someone whose absence covers now gets an automatic reply
(`OutOfOfficeResponder`, hooked into `InboundMailProcessor#process`).

**Almost all of that class is about NOT sending.** An auto-responder that
answers the wrong thing is not a cosmetic bug — reply to another auto-reply and
two servers mail each other until somebody notices. RFC 3834 is the rulebook.

Never answered:

| Signal | Why |
|---|---|
| `Auto-Submitted:` anything but `no` | RFC 3834 — it's already automatic |
| `Precedence: bulk\|list\|junk\|auto_reply` | distribution mechanism, not a person |
| `List-Id` / `List-Unsubscribe` / `List-Post` / … | a mailing list; the whole list would get it |
| `X-Auto-Response-Suppress` matching `All`/`OOF`/… | the sender explicitly opted out |
| empty envelope `MAIL FROM` (or `Return-Path: <>`) | a bounce; the bounce would bounce |
| `mailer-daemon@` / `no-reply@` / `postmaster@` / … | robot addresses |
| the away person's own address | pointless, and can ping-pong |
| anything filed as spam | never engage |
| sealed (E2EE) mail | no plaintext sender server-side to answer |

> The MX publishes only **nine fixed headers** (`queue.Headers`), so
> `Auto-Submitted`, `Precedence` and the `List-*` family are **not** in
> `@headers`. They are parsed from `raw_message_b64` instead — assuming them
> absent would defeat every guard above. No MTA change was needed.

**Once per sender per absence.** `out_of_office_replies` holds one row per
(user, sender, `period_start`) with a **UNIQUE index**, and the row is claimed
*before* the reply is sent. The index — not a `SELECT`-then-send check — is what
arbitrates: the inbound consumer is at-least-once and more than one subscriber
can run, so two deliveries of the same mail can both pass a check. A duplicate
row is harmless; a duplicate reply is a loop. Editing the absence dates starts a
new `period_start`, so everyone becomes answerable again.

The outgoing reply carries `Auto-Submitted: auto-replied`,
`X-Auto-Response-Suppress: All` and `Precedence: auto_reply`
(`messages.auto_submitted` → `OutboundMailPublisher`). It is persisted on the
row because delivery is asynchronous and retried.

Failures are swallowed and logged: the inbound mail is already stored, and an
auto-reply must never fail the pipeline into a redelivery.

## Counter-proposals

`propose-time` used to write `proposed_start`/`proposed_end` onto the attendee
row and stop: nothing mailed the organizer, nothing surfaced it, and no endpoint
could act on it. A proposal nobody sees is a dropped message.

The loop is RFC 5546's, in `CalendarProposal`:

```
attendee proposes ──> METHOD:COUNTER to the organizer
organizer accepts ──> event moves, SEQUENCE bumped, fresh METHOD:REQUEST to all
organizer declines ─> METHOD:DECLINECOUNTER, proposal cleared
```

* `POST events/:id/propose-time` records it and mails the COUNTER. It requires a
  `proposed_start` (422 without one).
* `POST events/:id/accept-proposal` moves the event onto the proposed time,
  bumps `SEQUENCE`, clears **every** attendee's now-stale proposal, and
  re-invites. Organizer-only — it reschedules, so it runs against
  `member_editable_events`; an invited guest gets a 404.
* `POST events/:id/decline-proposal` mails DECLINECOUNTER and clears it. The
  meeting does not move.
* Both take `attendee_email`, since an event can carry several suggestions.
* Inbound `METHOD:COUNTER` is handled by `CalendarProposal.apply_counter` —
  **only from an address already on the guest list**, so a stranger cannot
  inject a proposal.
* A proposal with no end time defaults to the event's own duration.
* The web `EventDetailPopup` shows pending proposals with *Move to this time* /
  *Keep current*; the buttons appear only for the organizer.

## Web: the scheduling assistant

`components/Calendar/SchedulingAssistant.jsx`, opened from the "Find a time"
toggle in `EventEditor`. People down the left, the day across the top, busy time
shaded, and a draggable selection band showing where the meeting would land —
red when it clashes, green when it doesn't. Clicking the grid centres the
meeting on the click; arrow keys nudge it a slot at a time (F4).

The selection is **derived** from the editor's time fields via an `anchorKey`
rather than synced into state, so a stale local drag is discarded automatically
when the fields change. Both the band and the busy blocks are positioned with
CSS custom properties set through refs — `style={{}}` is banned (F1).

## Meet links (public scheduler)

Per-member shareable scheduling links — the Cal.com "requires confirmation"
model: a visitor sees busy/free only and sends a meeting *request*; nothing
touches any calendar until the invitee accepts.

**Model.** `meet_links` (`mtl_`; creator `membership_id` ≠ `invitee_membership_id`
allowed — a link can book a colleague; `token` is a separate unguessable
nanoid-24 so a public id never doubles as a capability; fixed
`duration_minutes` from `MeetLink::DURATIONS`; `min_notice_minutes` /
`max_ahead_days` window; `conference_mode` none|meet|teams; soft
`revoked_at`). `blocked_times` (`blk_`) are "not available" windows — busy in
every free/busy read (FreeBusy folds them in via `organization:`), deliberately
NOT calendar events, visible only to their owner (hatched, in the web
calendar's drag-select "Block time" flow). `meeting_requests` (`mrq_`) tie the
visitor's ask to the inbox message and, after accept, the created event.

**Public API** (`/api/v1/meet/:token`, no auth, rack_attack-throttled,
generic 404 for unknown/revoked/inactive-invitee): link meta (+ signed
`AvatarToken` avatar URL), availability (`MeetAvailability` — merged busy
periods as bare start/end pairs, never titles or attendee data, clipped to
the invitee's working hours so nothing outside them is visible, plus the
working-hours envelope), and Turnstile-gated request creation
(`MeetingRequestIntake`: 15-min alignment, window + working-hours + free
checks, then a real inbound `Message` in the invitee's inbox with the banner
payload on `messages.meeting_request` — the `calendar_invite` pattern — plus a
"request received" mail to the visitor via `MeetMailerService`).

**Decision** (`meeting-requests/:id/accept|decline`, invitee-only — even the
link's creator cannot answer): accept re-checks the slot (conflict *reported*,
never enforced — it's the invitee's calendar), creates the event with the
invitee as ORGANIZER and the visitor as a pre-accepted attendee, rides
`CalendarInviteDispatch` for a real METHOD:REQUEST invite, and optionally
generates a conference link; decline mails the visitor with the optional
reason. The web banner is `MeetingRequestBanner` (request variant of the
invite banner); iOS (`MessageCard.meetingRequestBar`) and Android
(`ReaderScreen` `MeetingRequestBanner`) read the same `meeting_request` payload
off the message, from the MX mirror. Mobile shows Accept/Decline to every
viewer and relies on the 403 for non-invitees. Decisions are final (422 on a
second answer).

**Conferencing.** `conferencing_connections` (`cfc_`, per member, encrypted
refresh token, narrow scopes from `ConferencingConnection::SCOPES`) are minted
in Settings › Scheduling through `ConferencingController` (signed-state OAuth
on the `OauthProvider` registry; fixed callback
`/api/v1/conferencing/:provider/callback` — must be registered on the Google
and Azure apps before this works in prod; click-by-click console setup lives
in [Conferencing-Setup.md](Conferencing-Setup.md)). At accept time `ConferenceLink`
creates a **standalone** meeting — Google Meet REST `spaces.create` (no shadow
event on their Google calendar; the Calendar-API conferenceData route would
force one) or Graph `POST /me/onlineMeetings` — and stores the join URL in the
event's `location`, where `detectMeeting` picks it up everywhere. Generation
never blocks an accept; failure is reported as `conference_error`. Microsoft
rotates refresh tokens; `ConferenceLink` persists the newest.

### Link previews

A shared `/meet/:token` link unfurls (WhatsApp, Slack, iMessage, Mail) as
"Meet with <name> · N-minute meeting · <org>" with the person's avatar. Crawlers
never run the SPA, so a Cloudflare Pages Function (`ui/web/functions/meet/[token].js`)
fetches `GET /meet/:token?preview=1` (preview fetches don't bump
`visits_count`) and injects Open Graph/Twitter tags built by
`src/lib/meetPreview.js` into the shell's `<head>`, plus `robots: noindex` —
a capability URL never belongs in a search index. Any failure serves the
plain shell. Not visible in `yarn dev` (Vite doesn't run Pages Functions).

## External busy (local calendars → free/busy)

Gmail/Office365 calendars are synced **on the device only** (the offline-channel
rule), so on its own the server believes a member whose meetings live there is
free all week — meet links included. Devices therefore upload **busy-only**
blocks:

* **Core** (`mx_push_busy` in `ui/desktop/core/src/sync/mx_sync.rs`, run by
  `mx_tick` for every mirrored org — desktop, iOS and Android alike):
  `SyncStore::busy_periods` reads the local `calendar_events` for the next 8
  weeks — own calendars plus Google `@import` ICS subscriptions; not holidays,
  birthdays or colleagues' shared calendars (all `is_owned = 0`); not hidden,
  cancelled or declined — and `busy_blocks` turns them into merged UTC periods
  (all-day = whole days in the device zone; zero-length reminders are not busy).
  Only start/end leave the device. Unchanged sets are skipped (sha256 of the
  blocks in `engine_settings`) but re-sent every 6h.
* **API** `PUT /orgs/:org_id/external-busy` `{source, blocks:[{start,end}]}` —
  `source` is a per-device id (`dev_…`, `engine_settings.mx_busy_source`); each
  device replaces only its own set, so a phone with fewer accounts never wipes
  the desktop's. Blocks are clipped to −1d…+120d, capped at 3000, and a source
  silent for 30 days is dropped. Stored in `external_busy_blocks`, write-only.
* **FreeBusy** folds them in exactly like blocked time (`organization:`), so meet
  links, `events/free-busy` and the scheduling assistant all see them.

Freshness is "as of the last device sync": with every device off, new meetings
don't block until one comes back.

## New Event: which calendar, and a video call

The web editor (`EventEditor.jsx`) opens with two pickers the calendar page
fills in from `calendarStore` (writable calendars only, labelled with the
account that owns them, active account first):

- **Calendar** — where the event is created, and so which account sends it.
  Create-only: moving an existing event between accounts would mean deleting
  and re-inviting. Picking a local (Google/Microsoft) calendar routes the save
  through the Rust engine (`calendar_create_event` → `EventDraft`), never the
  Rails API; an inbox2 calendar is an ordinary `POST events` with `calendar_id`.
- **Video call** — a switch (`Add Google Meet` / `Add Microsoft Teams`) when the
  calendar offers one provider, which is every local calendar and the usual
  inbox2 one; a member with both Google and Microsoft conferencing connected
  has a real choice and gets a picker instead.

  Which providers a calendar offers is per calendar. For a local calendar it is
  the provider's own answer, synced into `calendars.conference_providers` (a
  comma-separated `meet`/`teams`) from Google's
  `conferenceProperties.allowedConferenceSolutionTypes` and Graph's
  `allowedOnlineMeetingProviders` — so a mailbox without Teams, or a calendar
  with conferencing off, is never offered one (asking for it 400s the whole
  create). An empty list means "none"; NULL means a row that predates the
  column, and the client falls back to assuming the provider's obvious one
  until the next calendar-list sync. On an inbox2 calendar the list is
  whichever `conferencing_connections` the member has.

  The provider mints the link: locally `EventDraft.conference` sets Google
  `conferenceData.createRequest` (with `conferenceDataVersion=1`) or Graph `isOnlineMeeting`, and the link
  comes back on the next sync in `metadata.conference`; on MX the controller
  calls `ConferenceLink` before the save so the link is in `location` — and so
  in the emailed invitation.

  A requested link that can't be made **fails the create** (422, editor stays
  open): the caller asked for a video call, and on the MX path nothing has been
  written yet, so there is no event to duplicate on the retry. (The meet-link
  *accept* path deliberately does the opposite — a visitor's booking must
  survive a flaky Meet API, so it reports `conference_error` and keeps the
  booking.) Not covered either way: Google can accept an event and then fail the
  conference request asynchronously (`conferenceData.createRequest.status`),
  which reads here as an event that simply has no link — `pending` is also the
  normal state for the first second, and the link lands on a later sync.

**Web.** Public page `ui/web/src/pages/meet/MeetPage.jsx` (`/meet/:token`, no
auth wrapper, management light theme): week grid 07:00–21:00 in the visitor's
auto-detected zone, up to three time zones side by side on the axis
(city-searchable datalist), slot click → Turnstile-gated request form echoing
every pinned zone. Link management + conferencing live in the mail app's
**Settings › Scheduling** (`SchedulingSettings.jsx`, per member — deliberately
not a console page), including links that book you (created by colleagues —
you can revoke those too).

**Not built yet:** iOS/Android render meeting-request messages as plain mail
(the banner needs a native variant); no reschedule flow (declined visitors
pick a new slot manually); no per-link custom availability windows beyond
working hours.

## Drag to reschedule

Dragging or resizing an event in the web/desktop calendar (`CalendarPage.jsx` → `useCalendarEvents.rescheduleEvent`) moves it at its source. A repeating event, or one with guests, first opens `MoveEventDialog`: **This event / All events**, then **Send / Don't send** to the guests. The dialog stays open while the move saves, and a refused move comes back to it with the reason (a move that needed no question opens it only on failure). Only events you may change are draggable: MX events on your own calendars that you organize, and synced events on a writable calendar that aren't someone else's meeting. Timed ↔ all-day drops are refused.

- **MX**: `PATCH events/:id` with `scope=all` moves the series master by the instance's shift and gives it the instance's new length. Exceptions move along (`original_start_at` always, their times only if they weren't moved). `notify=false` skips the re-invite; SEQUENCE still bumps.
- **Google / Microsoft** (Rust engine, `calendar_reschedule_event` → `reschedule_calendar_event_by_key`): times only, never a full `EventDraft`, because PATCHing the attendee list resets everyone's RSVP. Google sends `sendUpdates=all|none`. Graph always mails attendees, so the dialog offers no "Don't send" there. **All events** PATCHes the series master (`metadata.seriesId` = Google `recurringEventId` / Graph `seriesMasterId`; older Google rows fall back to the `<series>_<start>` instance-id form) shifted by FullCalendar's wall-clock delta. Graph's master is read in its own `originalStartTimeZone` via `Prefer: outlook.timezone`, so the series isn't re-homed in UTC. A single-instance move writes the accepted times to SQLite at once, so a failed resync can't snap it back.

Not handled yet: **All events** onto another day (the BYDAY rule would need rewriting, so the dialog then offers only this event), "this and following" on a drag (the editor's Save has it), RRULE `UNTIL`/`BYHOUR` reconciliation, re-sending exception rows after an MX series move, Microsoft rows synced before `seriesId` existed (they read as one-offs until they resync), Google `guestsCanModify` / delegated calendars (another organizer's event isn't draggable), and editing Google/Microsoft events in the full editor.

## Zones (soft focus blocks)

A zone marks part of the day for one thing ("Deep work · Project Atlas, 16:00–18:00", "Prep: Q3 board review" the hour before a meeting) **without blocking it** by default: meet links, the scheduling assistant and colleagues still see the time as free and can book into it. A zone with **Block this time** on (`blocks`, 2026-10-21) is read by FreeBusy (`blocking_zones`) exactly like blocked time. It is a bare busy period, the name never leaks. Because zones belong to the user, a blocking zone blocks them in every org. When a zone with `notify` starts, every client raises a "You're in the zone" card with a countdown that **stays until it is clicked away**.

**Model.** `zones` (`zon_`: name, note, start/end, `notify`, `blocks`, optional `zone_category_id`) and `zone_categories` (`zcat_`: name, `color`, position). Both belong to the **user**, not a membership. One person's zones follow them across orgs and appear in every calendar view, local channels included. `color` is a palette key (`ZoneCategory::COLORS`: blue/amber/violet/green/rose/teal), never a hex. Each client maps the key to a per-theme shade (web `--zone-*` in `tokens.css`, iOS/Android theme palettes), so a zone keeps its contrast in every theme. The first `GET` of categories seeds Deep work / Prep / Admin / Personal. Deleting a category leaves its zones uncategorised (`on_delete: :nullify`).

**API** (user-scoped, E3 by construction: `current_user.zones`):
`GET/POST /account/zones`, `PATCH/DELETE /account/zones/:id` (`?start=&end=` range on the list), and the same four for `/account/zone-categories`. `category_id` takes the public key; a category that is unknown or belongs to someone else 404s.

**Web/desktop.**
- **Grid:** zones are FullCalendar `display: 'background'` events, striped bands behind the meetings, in week and day views only. The label opens `ZoneEditor`, while the rest of the band stays a drag target. A timed drag offers New event / **New zone** / Block time (MX).
- **Sidebar:** `ZoneSection` shows the running zone with its countdown, the next few zones, and a show/hide toggle per category. The unified inbox's calendar rail (`CalendarRail`) carries the same block under "Coming up", with its own `ZoneEditor`.
- **Prep zone:** the meeting popup's "Prep zone" (30 min / 1 h / 2 h) builds one with `prepZoneParams`.
- **Alert:** `useZoneAlerts`, mounted at the root next to `useMeetingReminders`, fires the card through the same surfaces as meeting reminders (`deliverMeetingAlert`). It uses `eventType: 'zone_start'` with `urgent` priority, so the card never auto-dismisses; on desktop that is the always-on-top notification window. It plays its own chime (`/sounds/zone-chime.mp3`, `playZoneChime`), not the new-mail sound; the master Sounds toggle still mutes it.
- **Dismissal:** Done, ✕, Escape and swipe all record the dismissal. Clicking the card body (or "Open calendar") opens the app but leaves the card up (`lib/zones` `markDismissed`, localStorage). The desktop window relays it to the main window as a `zone-dismiss` event.
- **Menu bar:** a running zone counts down in the tray title unless a meeting is about to start.

**iOS/Android:** see [iOS-App.md](iOS-App.md) and [Android-App.md](Android-App.md). Each platform has a local notification or alarm at the start, an in-app card with a countdown and Done, and a zone block in the agenda that wraps the meetings inside it. iOS also shows a Live Activity while the app is open; Android shows an ongoing count-down notification with a Done action.

**Repeats.** `repeat` is none/daily/weekdays/weekly with an optional `repeat_until`. The series is one row, expanded on read by `Zone#occurrences` in the zone's own `time_zone`, so it stays DST-safe. Each occurrence gets an id in the calendar scheme (`zon_x@20260925T140000Z`) plus a `series_id`. Clients key dismissals and alerts on the occurrence id, so each day alerts separately. PATCH on an occurrence retimes the whole series in wall-clock terms (whole days plus the new local time). If the same PATCH turns the repeat off, the edited occurrence is kept as it is. DELETE removes the series; `DELETE …/zon_x@<stamp>?scope=occurrence` drops only that day by adding the zone-local date to `skip_dates`, which the expansion skips (web: right-click › Delete this zone; mobile still deletes only the series).

**Overnight.** A zone may cross midnight and run for up to 24h (`Zone::MAX_LENGTH`).

**Prep anchors.** A prep zone stores `anchor_event_id` + `anchor_minutes`. Whenever a client has the anchored meeting loaded and it has moved, the client retimes the zone to end at the new start (web `anchorFix`). Moving a prep zone by hand clears the anchor. Repeating zones never follow a meeting.

**Cross-device sync.** A card clicked away on any device is posted to `POST /account/zone-dismissals` (`zone_dismissals`, one row per occurrence id, idempotent, swept 7 days after the zone ends). The zone list flags each occurrence `dismissed`, so every client also catches up on its next fetch. Any zone, category or dismissal write calls `ZoneSync.notify`, which does two things. First, it broadcasts `{type: "zones_changed", dismissed?}` on the per-user `ZoneChannel` (`zones_<user key>`); open web/desktop windows drop that card at once (the desktop notification window gets a `zone-card-remove` event) and refetch. Second, it sends the same signal as a silent `zones_changed` mobile push (`MobilePushSender.zones_changed`, collapsed per dismissal); iOS/Android clear that occurrence's notification and Live Activity and refetch. A dismissal that arrives from elsewhere is recorded locally with `remote: true`, so it is never echoed back to the server.

**Card lifetime.** The start card stays until it is clicked away, including after the zone ends, when it shows "Zone ended". On web it is never evicted by a stack of mail cards (`keepVisible`). A dismissal in one browser tab clears the others. Signing out resets the zone store.


## Realtime

`CalendarChannel` streams `calendar_<org key>`. The controller broadcasts
`event_created` / `event_updated` / `event_deleted` / `rsvp_updated`; inbound
replies broadcast too. The broadcasts predated the channel class, so until now
they were published to a stream no client could subscribe to.

## Not built

* **Reminders are delivered by the client, not the server.** `calendar_reminders`
  rows are stored and served, and the desktop/web client reads their
  `minutes_before` as lead times (see
  [Notifications.md § Meeting reminders](Notifications.md#meeting-reminders)) —
  but nothing server-side *sends* anything, and there is still no UI to create a
  reminder. `method: "email"` is ignored; an emailed reminder would need a
  `sent_at` marker (a migration) plus a recurring job to stay idempotent, and a
  push-to-a-sleeping-phone reminder needs the same. The client tick is the only
  path that covers Gmail/Office365 events, which never reach Rails at all.
* **Repeat (2026-10-25).** Every event editor has a Repeat row: web/desktop
  `EventEditor` (MX events, new and edited), and the iOS `NewEventSheet` /
  Android `EventSheet` (Google/Microsoft calendars). Daily/weekly (day chips)/
  monthly/yearly, every N, ends never / on a date / after N times. One RRULE
  body everywhere (`lib/recurrence.js`, `RepeatRule.swift`, `RepeatRule.kt`); a
  rule the editors can't draw (2nd Tuesday, BYSETPOS) opens as "Custom (as set
  elsewhere)" and is saved untouched.
  * **MX** stores it as `recurrence_rule` with the browser's `timezone`, so it
    expands in that zone. An exception row has no rule of its own; the
    serializer's `series_rule` carries the master's for the editor's prefill.
  * **Google** gets `recurrence: ["RRULE:…"]` (a series edit keeps its EXDATE
    lines). **Graph** gets `ms_recurrence`'s pattern + range
    (`core/src/sync/calendar.rs`), and `graph_rrule` reads it back.
  * **Saving an edited series asks This event / This and following / All
    events** (`MoveEventDialog` with `editing`; a confirmation dialog on
    mobile). A changed rule drops "This event": an instance can't carry one.
    - MX `PATCH events/:id` takes `scope=following`: `split_series!` ends the
      old series with UNTIL just before the instance (`truncate_series_before!`
      now drops COUNT, since RFC 5545 forbids both) and saves the rest as a new
      series with a fresh UID and the edits. An unchanged COUNT carries only
      what's left. Later exceptions move over when rule and slot are
      unchanged, else they're dropped, and both halves are re-mailed.
      `scope=all` with a new rule keeps exceptions whose slot it still has
      (`occurs_at?`) and drops the rest; with no rule it becomes a one-off at
      the chosen instance's time, not the series' first date.
    - Mobile: if the rule can't be read, the sheet says so (with Try again)
      and saves edits to that one event only, rather than taking a series
      for a one-off.
    - Local channels: `update_calendar_event_by_key` reads `draft.scope` and
      hands series edits to `apply_series_edit`. `all` PATCHes the master
      (`update_series`, start moved by the instance's shift). `following`
      creates the new half first, then PATCHes the old one to end before the
      instance (`ended_recurrence` + `patch_series`), deleting the new half
      again if that fails. An unchanged COUNT carries only what's left
      (`SeriesEnd.done`, counted by ORIGINAL slot: Google's instance list incl.
      cancelled ones, fetched a year past the cutoff so moved occurrences are
      seen; Graph's off the pattern itself, `graph_count_before`, since its
      instance list hides deleted occurrences that still used up the COUNT).
      The split falls on the instance's ORIGINAL slot (Google
      `originalStartTime`, Graph `originalStart`), so a moved occurrence isn't
      left in both halves. When the new half keeps the old rule and time, the
      old one's later exceptions move over first (`carry_exceptions`, which on
      Google looks a year back by current time and sorts by original slot): moved
      or retitled occurrences are re-applied, Google cancellations re-deleted
      (Graph's v1.0 instance list hides deleted occurrences, so those come
      back). With a new rule or time there is no slot to land on and they go.
      Guests: the sheets send the list only when it changed. An empty
      `attendees` on any update means "unchanged"; `attendees_cleared` is the
      explicit "remove everyone". A changed list is merged with the event's
      own entries (single edits too), so kept guests keep their RSVPs.
      A series PATCH reuses the master's attendee entries, so guests keep
      their RSVPs (`merged_attendees`); an unchanged list is left out. A Graph
      split copies the full `body` in its own content type, not `bodyPreview`. "All → does not repeat" creates the one-off, then
      deletes the series. A new half takes the master's guests and notes when
      the draft has none (the mobile sheets send no notes; iOS no guests).
      The mobile sheets read the rule through the `calendar_series_rule` FFI
      (synced rows are expanded instances and carry none).
    - MX copies the master's attendees and reminders onto the split-off half.
  * **Rules the editors redraw** must say exactly what they rebuild:
    `BYMONTHDAY`/`BYMONTH` only when they are the start's own day/month, else
    the rule is Custom. An "on date" end is never empty or before the start.
    Graph's `endDate` for a timed UNTIL is its day in the client's offset
    (read an hour early so a DST change can't tip 23:59 into the next day).
  * **Graph times** (fixed 2026-10-25): `ms_event_body` used to send the web's
    UTC instant labelled with the local zone (`13:00Z` + `Europe/Amsterdam`).
    Graph reads `dateTime` as a wall clock in `timeZone`, so that could land an
    hour or two off. `ms_when` now sends a bare wall clock in the event's
    zone. The contract (on `EventDraft`): a timed draft is written in its own
    zone's offset (web, iOS and Android all do) or as a bare wall clock, so the
    offset is dropped and the wall clock kept — `Z` included, which is
    London's winter offset, not a cue to re-home the series in UTC.
  * Not built: Google/Microsoft events still
    can't be opened in the web editor at all (drag, delete and RSVP only).
* **No ICS export / subscription feed**, no CalDAV.
* **Sealed (E2EE) domains skip invite parsing** — no server-side plaintext, so
  the client would have to do it.
* **No server-side calendar sync.** `Calendar::SOURCES` is `inbox2` only.
* **One out-of-office period per person, not a list** — setting a new one
  replaces the old. A second overlapping absence would need an
  `out_of_office_periods` table.
* **The auto-reply is plain text only** — no HTML body, no per-domain or
  internal-vs-external variants (Exchange offers a separate message for outside
  senders).
* **Once per absence, never re-sent** — Gmail re-sends every four days to the
  same correspondent; we don't.
* **The reply's envelope sender is the mailbox, not `<>`** — a true null
  return-path would need the Go sender to special-case it, so a bounced
  auto-reply lands in the away person's own thread.
* **Local-channel (Gmail/Office365/IMAP) mail gets no auto-reply** — this is the
  MX inbound path only; those never touch the API.
* **Out of office does not decline incoming invitations** automatically, and
  does not appear on the calendar grid itself (only in the assistant).
* **Working hours are per user, not per org** — someone in two orgs with
  different schedules gets one.
* **No room or resource booking** (Exchange room mailboxes have no equivalent).
* **No cross-org / federated free-busy** — an outside guest's availability is
  unknown, never fetched.
* **A counter-proposal has no expiry** and is not shown in the reading pane —
  only on the calendar's event popup.
* Invitation sending **bypasses `SendQuota`** (transactional, low volume).
* Calendar is absent from `Feature-Spec.md` and `TODO.md`; the `A21 / spec 21`
  comment in `routes.rb` points at a spec section that does not exist.
