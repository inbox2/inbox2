//! Calendar surface of the engine: per-account calendar adapters, the
//! poll-time calendar sync, and the event create/update/delete/RSVP entry
//! points shared by the Tauri commands and the bus RPC.

use super::*;

impl SyncEngine {
    /// Build a calendar adapter for an account, or `None` for IMAP (no calendar).
    fn calendar_adapter(
        &self,
        account_key: &str,
    ) -> Result<Option<Box<dyn crate::sync::calendar::CalendarAdapter>>> {
        use crate::sync::calendar::{GoogleCalendarAdapter, MicrosoftCalendarAdapter};
        use crate::sync::oauth::TokenManager;

        let account = match self.store.get_account(account_key)? {
            Some(a) => a,
            None => return Ok(None),
        };
        let creds = match self.store.get_credentials(account_key)? {
            Some(c) => c,
            None => return Ok(None),
        };
        let token = Arc::new(TokenManager::new(
            account_key.to_string(),
            account.provider_type.clone(),
            self.store.clone(),
            self.api_context.clone(),
            &creds,
        ));
        match account.provider_type {
            ProviderType::Gmail => {
                Ok(Some(Box::new(GoogleCalendarAdapter::new(token, account_key.to_string()))))
            }
            ProviderType::Microsoft => {
                Ok(Some(Box::new(MicrosoftCalendarAdapter::new(token, account_key.to_string()))))
            }
            // IMAP and Meta channels have no calendar.
            ProviderType::Imap | ProviderType::Instagram | ProviderType::Messenger
            | ProviderType::WhatsApp => Ok(None),
        }
    }

    /// Sync all calendars for an account (list → per-calendar full/delta). Errors
    /// are logged, not propagated — calendar failures must not break mail sync.
    pub(super) async fn sync_calendars(&self, account_key: &str) {
        use crate::sync::calendar::CalendarCursor;

        let adapter = match self.calendar_adapter(account_key) {
            Ok(Some(a)) => a,
            Ok(None) => return,
            Err(e) => {
                log::warn!("Calendar adapter build failed for {account_key}: {e}");
                return;
            }
        };

        let calendars = match adapter.list_calendars().await {
            Ok(c) => c,
            Err(e) => {
                log::warn!("Calendar list failed for {account_key}: {e}");
                return;
            }
        };

        let keys: Vec<String> = calendars.iter().map(|c| c.key.clone()).collect();
        for c in &calendars {
            if let Err(e) = self.store.upsert_calendar(account_key, adapter.source(), c) {
                log::warn!("upsert_calendar failed: {e}");
            }
        }
        let _ = self.store.prune_calendars(account_key, adapter.source(), &keys);

        let mut any_changes = false;
        for cal in &calendars {
            let token = self.store.get_calendar_cursor(&cal.key).unwrap_or(None);
            let cursor = CalendarCursor { token };
            let result = match adapter.sync_calendar(cal, &cursor).await {
                Ok(r) => r,
                Err(SyncError::CursorExpired) => {
                    let _ = self.store.update_calendar_cursor(&cal.key, None);
                    match adapter.sync_calendar(cal, &CalendarCursor::default()).await {
                        Ok(r) => r,
                        Err(e) => {
                            log::warn!("Calendar resync failed for {}: {e}", cal.name);
                            continue;
                        }
                    }
                }
                Err(e) => {
                    log::warn!("Calendar sync failed for {}: {e}", cal.name);
                    continue;
                }
            };

            if !result.upserts.is_empty() || !result.deletions.is_empty() {
                any_changes = true;
            }
            let mut stored_everything = true;
            for ev in &result.upserts {
                if let Err(e) = self.store.upsert_event(account_key, &cal.key, ev) {
                    log::warn!("[calendar] storing {} in {} failed: {e}", ev.provider_id, cal.name);
                    stored_everything = false;
                }
            }
            for pid in &result.deletions {
                let _ = self.store.delete_event_by_provider_id(account_key, pid);
            }
            if let Some(seen) = &result.seen_provider_ids {
                let _ = self.store.prune_unseen_events(account_key, &cal.key, seen);
            }
            // The cursor is a promise that everything before it is stored. Moving
            // it past an event that failed to write means the delta never offers
            // that event again — it is simply missing until the token expires.
            if stored_everything {
                let _ = self.store.update_calendar_cursor(&cal.key, result.next_token.as_deref());
            }
        }

        if any_changes {
            self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        }
    }

    /// Events in `[time_min, time_max)` across every calendar of the account (or
    /// of every account), straight from the provider — nothing is stored. For ranges
    /// the local sync window (`calendar::time_window`) doesn't cover. A calendar
    /// that fails is skipped and named in the second list, so one unreadable
    /// subscription doesn't hide the rest.
    #[allow(clippy::type_complexity)]
    pub async fn fetch_calendar_events(
        &self,
        account_key: Option<&str>,
        time_min: &str,
        time_max: &str,
    ) -> Result<(Vec<(String, String, crate::sync::calendar::UnifiedEvent)>, Vec<String>)> {
        let keys = match account_key {
            Some(k) => vec![k.to_string()],
            None => self.store.list_accounts()?.into_iter().map(|a| a.key).collect(),
        };
        let (mut out, mut failed) = (Vec::new(), Vec::new());
        for key in keys {
            let Some(adapter) = self.calendar_adapter(&key)? else { continue };
            for cal in adapter.list_calendars().await? {
                match adapter.list_events(&cal, time_min, time_max).await {
                    Ok(evs) => out.extend(evs.into_iter().map(|ev| (key.clone(), cal.name.clone(), ev))),
                    Err(e) => failed.push(format!("{key} / {}: {e}", cal.name)),
                }
            }
        }
        Ok((out, failed))
    }

    /// Resolve an account's calendar adapter or error if it has none (IMAP).
    fn require_calendar_adapter(
        &self,
        account_key: &str,
    ) -> Result<Box<dyn crate::sync::calendar::CalendarAdapter>> {
        self.calendar_adapter(account_key)?
            .ok_or_else(|| SyncError::Other("account has no calendar".into()))
    }

    /// Create an event, pull the change back into SQLite, notify clients.
    ///
    /// The row is written locally the moment the provider accepts it, before the
    /// resync: a full calendar sync is seconds of HTTP, and until it lands the
    /// event the user just saved is nowhere to be seen. The local row is keyed on
    /// the provider's own id (`cev_<account>_<provider id>`), so the resync
    /// overwrites it in place with the provider's version — conference link,
    /// attendee statuses and all — rather than adding a second copy.
    pub async fn create_calendar_event(
        &self,
        account_key: &str,
        calendar_provider_id: &str,
        draft: crate::sync::calendar::EventDraft,
    ) -> Result<String> {
        let adapter = self.require_calendar_adapter(account_key)?;
        let id = adapter.create_event(calendar_provider_id, &draft).await?;
        if let Ok(Some(calendar_key)) =
            self.store.calendar_key_for_provider_id(account_key, calendar_provider_id)
        {
            let placeholder = self.draft_as_event(account_key, &draft, &id);
            match self.store.upsert_event(account_key, &calendar_key, &placeholder) {
                Ok(()) => self
                    .emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key })),
                Err(e) => log::warn!("[calendar] local placeholder for {id} failed: {e}"),
            }
        }
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(id)
    }

    /// The just-created draft as a local event row: what the clients need to draw
    /// it now, in the same shape the sync writes. Anything only the provider knows
    /// (etag, iCalUID, the generated conference link) is left out — the resync a
    /// moment later fills it in.
    fn draft_as_event(
        &self,
        account_key: &str,
        draft: &crate::sync::calendar::EventDraft,
        provider_id: &str,
    ) -> crate::sync::calendar::UnifiedEvent {
        let me = self.store.get_account(account_key).ok().flatten().map(|a| a.email_address);
        let attendees: Vec<serde_json::Value> = draft
            .attendees
            .iter()
            .map(|e| serde_json::json!({ "email": e, "responseStatus": "needsAction" }))
            .collect();
        crate::sync::calendar::UnifiedEvent {
            provider_id: provider_id.to_string(),
            title: draft.title.clone(),
            description: draft.description.clone(),
            location: draft.location.clone(),
            start_at: draft.start_at.clone(),
            end_at: draft.end_at.clone(),
            all_day: draft.all_day,
            timezone: draft.timezone.clone().unwrap_or_else(|| "UTC".into()),
            status: "confirmed".into(),
            organizer_email: me,
            metadata: Some(serde_json::json!({ "attendees": attendees }).to_string()),
            ..Default::default()
        }
    }

    /// Update an event, resync, notify clients.
    pub async fn update_calendar_event(
        &self,
        account_key: &str,
        calendar_provider_id: &str,
        event_provider_id: &str,
        draft: crate::sync::calendar::EventDraft,
    ) -> Result<()> {
        let adapter = self.require_calendar_adapter(account_key)?;
        adapter.update_event(calendar_provider_id, event_provider_id, &draft).await?;
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(())
    }

    /// Delete an event remotely + locally, notify clients.
    pub async fn delete_calendar_event(
        &self,
        account_key: &str,
        calendar_provider_id: &str,
        event_provider_id: &str,
    ) -> Result<()> {
        let adapter = self.require_calendar_adapter(account_key)?;
        adapter.delete_event(calendar_provider_id, event_provider_id).await?;
        // Reflect immediately even before the next delta sync.
        let _ = self.store.delete_event_by_provider_id(account_key, event_provider_id);
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(())
    }

    /// RSVP to an event, resync, notify clients.
    pub async fn respond_calendar_event(
        &self,
        account_key: &str,
        calendar_provider_id: &str,
        event_provider_id: &str,
        response: &str,
    ) -> Result<()> {
        let adapter = self.require_calendar_adapter(account_key)?;
        adapter.respond_event(calendar_provider_id, event_provider_id, response).await?;
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(())
    }

    /// RSVP to an offline-synced event addressed by its local key (the id the
    /// frontend holds). Resolves the provider ids, then delegates to
    /// [`Self::respond_calendar_event`]. `response` is `accepted` | `declined` |
    /// `tentative`.
    pub async fn respond_calendar_event_by_key(
        &self,
        account_key: &str,
        event_key: &str,
        response: &str,
    ) -> Result<()> {
        let (calendar_provider_id, event_provider_id) = self
            .store
            .event_provider_ids(account_key, event_key)?
            .ok_or_else(|| {
                SyncError::Other(format!("event {event_key} has no provider id to RSVP against"))
            })?;
        self.respond_calendar_event(account_key, &calendar_provider_id, &event_provider_id, response)
            .await
    }

    /// Update an offline-synced event addressed by its local key (the id the
    /// frontend holds). `draft.scope` picks what a series edit applies to:
    /// `this` (default) the one instance, `all` the series master, `following`
    /// this instance onwards — the old series ends just before it and the rest
    /// becomes a new series, as Google and Outlook split it.
    pub async fn update_calendar_event_by_key(
        &self,
        account_key: &str,
        event_key: &str,
        mut draft: crate::sync::calendar::EventDraft,
    ) -> Result<()> {
        let (calendar_provider_id, event_provider_id, instance_start, series_id) = self
            .store
            .event_series_info(account_key, event_key)?
            .ok_or_else(|| {
                SyncError::Other(format!("event {event_key} has no provider id to update"))
            })?;
        let scope = draft.scope.take().unwrap_or_default();
        let in_series = series_id.is_some();
        let Some(series_id) = series_id.filter(|_| scope == "all" || scope == "following") else {
            // One instance: its own row, never a rule (an instance can't carry
            // one). A one-off may gain a rule and become a series.
            if in_series {
                draft.recurrence = None;
            }
            return self
                .update_calendar_event(account_key, &calendar_provider_id, &event_provider_id, draft)
                .await;
        };

        let adapter = self.require_calendar_adapter(account_key)?;
        crate::sync::calendar::apply_series_edit(
            adapter.as_ref(),
            &calendar_provider_id,
            &series_id,
            &event_provider_id,
            &instance_start,
            &scope,
            &draft,
        )
        .await?;
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(())
    }

    /// The repeat rule (RRULE body) of the series a synced instance belongs to,
    /// read off the provider — synced rows are expanded instances and carry
    /// none. None for a one-off.
    pub async fn calendar_series_rule(&self, account_key: &str, event_key: &str) -> Result<Option<String>> {
        let Some((calendar_provider_id, _, _, Some(series_id))) =
            self.store.event_series_info(account_key, event_key)?
        else {
            return Ok(None);
        };
        let adapter = self.require_calendar_adapter(account_key)?;
        Ok(adapter.get_series(&calendar_provider_id, &series_id).await?.rule)
    }

    /// Move an offline-synced event (drag/resize in the calendar), or its whole
    /// series, by its local key — times only, so guests and their RSVPs stay.
    pub async fn reschedule_calendar_event_by_key(
        &self,
        account_key: &str,
        event_key: &str,
        r: crate::sync::calendar::Reschedule,
    ) -> Result<()> {
        let (calendar_provider_id, event_provider_id) = self
            .store
            .event_provider_ids(account_key, event_key)?
            .ok_or_else(|| {
                SyncError::Other(format!("event {event_key} has no provider id to move"))
            })?;
        let adapter = self.require_calendar_adapter(account_key)?;
        adapter.reschedule_event(&calendar_provider_id, &event_provider_id, &r).await?;
        // The provider has it; keep the row there even if the resync below
        // fails, or the event would snap back after a move that worked. A whole
        // series moved has too many rows to patch — the resync redraws those.
        if r.series_id.is_none() {
            if let Err(e) = self.store.set_event_times(account_key, event_key, &r.start_at, &r.end_at) {
                log::warn!("[calendar] local times for {event_key} failed: {e}");
            }
        }
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));
        Ok(())
    }

    /// Delete an offline-synced event addressed by its local key. Resolves the
    /// provider ids, then delegates to [`Self::delete_calendar_event`].
    pub async fn delete_calendar_event_by_key(
        &self,
        account_key: &str,
        event_key: &str,
    ) -> Result<()> {
        let (calendar_provider_id, event_provider_id) = self
            .store
            .event_provider_ids(account_key, event_key)?
            .ok_or_else(|| {
                SyncError::Other(format!("event {event_key} has no provider id to delete"))
            })?;
        self.delete_calendar_event(account_key, &calendar_provider_id, &event_provider_id)
            .await
    }

    /// Detect + parse an emailed meeting invite from one of a message's
    /// `text/calendar` attachments, and resolve whether its UID maps to an
    /// already-synced calendar event (so the banner can preselect the answered
    /// button). Returns `None` if the attachment isn't a usable invite.
    pub async fn invite_from_attachment(
        &self,
        account_key: &str,
        message_key: &str,
        attachment_id: &str,
    ) -> Result<Option<crate::sync::ics::ClientInvite>> {
        let provider = self.interactive_provider(account_key)?;
        let bytes = provider.download_attachment(message_key, attachment_id).await?;
        let text = String::from_utf8_lossy(&bytes);
        let Some(mut info) = crate::sync::ics::parse_ics(&text) else {
            return Ok(None);
        };
        // The invite's own date (from the ICS) picks the right occurrence of a
        // recurring series when matching the synced calendar.
        let near_date = info.start.as_deref().and_then(|s| s.get(0..10)).unwrap_or("").to_string();
        let (mut matched_event_key, current_status) = match self.store.get_account(account_key)? {
            Some(acct) => match self
                .store
                .event_by_ical_uid(account_key, &info.uid, &acct.email_address, &near_date)?
            {
                // Prefer the synced event's tz-correct absolute times over the
                // ICS ones (the ICS may only carry a TZID we can't resolve).
                Some(m) => {
                    info.start = Some(m.start_at);
                    info.end = Some(m.end_at);
                    info.all_day = m.all_day;
                    (Some(m.key), m.response_status)
                }
                None => (None, None),
            },
            None => (None, None),
        };
        // We added this one ourselves. Matching on the provider's iCalUID can't see
        // that on Graph (it assigns its own), so the banner has to be told separately
        // or it offers to add an event that is already there.
        if matched_event_key.is_none() {
            if let Ok(Some(key)) = self.store.get_engine_setting(&added_ics_key(account_key, &info.uid)) {
                matched_event_key = Some(key);
            }
        }
        Ok(Some(crate::sync::ics::ClientInvite {
            info,
            matched_event_key,
            current_status,
            attachment_id: attachment_id.to_string(),
            detected: false,
        }))
    }

    /// Put an emailed `text/calendar` event straight onto the account's calendar —
    /// the "Add to calendar" action for the ICS attachments that aren't invitations
    /// asking for an answer (`METHOD:PUBLISH`, or no METHOD at all: appointment
    /// confirmations, booking reminders, ticket bookings...). A `METHOD:REQUEST`
    /// already has its own path — accepting it adds the event — so this is the
    /// other half of the same banner, not a replacement.
    ///
    /// Returns the local key of the event on the calendar. Idempotent: an ICS whose
    /// UID is already synced returns that event instead of creating a second copy,
    /// so a double tap (or a second mail about the same booking) can't duplicate it.
    ///
    /// `calendar_provider_id` picks the target calendar; `None` uses the account's
    /// primary writable one. `device_timezone` is only consulted for a *floating*
    /// ICS time, which RFC 5545 defines as "whatever zone the reader is in".
    pub async fn add_invite_to_calendar(
        &self,
        account_key: &str,
        message_key: &str,
        attachment_id: &str,
        calendar_provider_id: Option<String>,
        device_timezone: Option<String>,
    ) -> Result<String> {
        let provider = self.interactive_provider(account_key)?;
        let bytes = provider.download_attachment(message_key, attachment_id).await?;
        let text = String::from_utf8_lossy(&bytes);
        let info = crate::sync::ics::parse_ics(&text)
            .ok_or_else(|| SyncError::Other("attachment is not a parseable event".into()))?;
        self.add_info_to_calendar(account_key, info, calendar_provider_id, device_timezone).await
    }

    /// The meeting the summary lane found in a message body with no ICS attached
    /// (`messages.detected_meeting`), shaped like an emailed invite so every banner
    /// renders it with the existing "Add to calendar" branch. `None` when nothing
    /// was detected. `matched_event_key` is set once we added it ourselves.
    pub fn detected_invite(&self, account_key: &str, message_key: &str) -> Result<Option<crate::sync::ics::ClientInvite>> {
        let Some(info) = self.detected_info(message_key)? else { return Ok(None) };
        let matched_event_key = self.store.get_engine_setting(&added_ics_key(account_key, &info.uid)).ok().flatten();
        Ok(Some(crate::sync::ics::ClientInvite {
            info,
            matched_event_key,
            current_status: None,
            attachment_id: String::new(),
            detected: true,
        }))
    }

    /// "Add to calendar" for a detected meeting. The times are the sender's wall
    /// clock with no zone, so they're read in `device_timezone` (like a floating ICS time).
    pub async fn add_detected_meeting_to_calendar(
        &self,
        account_key: &str,
        message_key: &str,
        calendar_provider_id: Option<String>,
        device_timezone: Option<String>,
    ) -> Result<String> {
        let info = self
            .detected_info(message_key)?
            .ok_or_else(|| SyncError::Other("no meeting was detected in this message".into()))?;
        self.add_info_to_calendar(account_key, info, calendar_provider_id, device_timezone).await
    }

    fn detected_info(&self, message_key: &str) -> Result<Option<crate::sync::ics::InviteInfo>> {
        let Some(raw) = self.store.detected_meeting(message_key)? else { return Ok(None) };
        let Ok(m) = serde_json::from_str::<crate::sync::ics::DetectedMeeting>(&raw) else { return Ok(None) };
        Ok(Some(m.into_info(message_key)))
    }

    /// Write a parsed event onto the account's calendar (shared by the ICS and the
    /// detected-meeting paths). Idempotent on the UID, see `add_invite_to_calendar`.
    async fn add_info_to_calendar(
        &self,
        account_key: &str,
        info: crate::sync::ics::InviteInfo,
        calendar_provider_id: Option<String>,
        device_timezone: Option<String>,
    ) -> Result<String> {
        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;

        // Already on the calendar (we synced it, or a previous tap added it) — hand
        // back the existing event rather than making a duplicate.
        let near_date = info.start.as_deref().and_then(|s| s.get(0..10)).unwrap_or("").to_string();
        if let Some(m) =
            self.store.event_by_ical_uid(account_key, &info.uid, &account.email_address, &near_date)?
        {
            return Ok(m.key);
        }

        let start = info
            .start
            .as_deref()
            .ok_or_else(|| SyncError::Other("event has no start time".into()))?;
        let end = info.end.as_deref().unwrap_or(start);

        // Both APIs take a bare wall clock plus a separate IANA zone, so strip any
        // offset back off and send the zone the ICS actually named. A floating time
        // falls back to the reader's zone (RFC 5545), and only then to UTC.
        let start_at = crate::sync::ics::wall_clock(start).to_string();
        let mut end_at = crate::sync::ics::wall_clock(end).to_string();
        if end_at == start_at {
            end_at = default_end(&start_at, info.all_day);
        }
        let timezone = if info.all_day {
            // An all-day event is a pair of dates; a zone on it only invites drift.
            None
        } else {
            info.timezone.clone().or(device_timezone)
        };

        let draft = crate::sync::calendar::EventDraft {
            title: info.summary.clone().unwrap_or_else(|| "Event".into()),
            description: info.description.clone(),
            location: info.location.clone(),
            start_at,
            end_at,
            all_day: info.all_day,
            timezone,
            attendees: Vec::new(), // adding it to your own calendar invites nobody
            conference: false,     // ditto: an emailed event keeps whatever link it came with
            recurrence: None,
            scope: None,
            description_is_html: false,
            attendees_cleared: false,
            extra_recurrence: Vec::new(),
        };

        let calendar_provider_id = match calendar_provider_id {
            Some(id) => id,
            None => match self.default_calendar_provider_id(account_key) {
                Ok(id) => id,
                // Nothing in the store yet. On a phone the calendar list is only
                // populated as a side effect of a mail sync, so a freshly seeded or
                // freshly added account can reach here with an empty `calendars`
                // table and no real problem. Pull the list live, then try once more.
                Err(_) => {
                    log::info!("[calendar] no calendar for {account_key} yet — syncing before adding");
                    self.sync_calendars(account_key).await;
                    self.default_calendar_provider_id(account_key)?
                }
            },
        };
        let adapter = self.require_calendar_adapter(account_key)?;
        adapter.import_event(&calendar_provider_id, &draft, &info.uid).await?;
        self.sync_calendars(account_key).await;
        self.emit(event::CALENDAR_CHANGED, serde_json::json!({ "accountKey": account_key }));

        // The resync has run, so the event is in SQLite; resolve the local key for the
        // banner's deep link. An empty key still means the add succeeded — only the
        // link is unavailable (Graph mints its own iCalUID, so it never matches).
        let key = self
            .store
            .event_by_ical_uid(account_key, &info.uid, &account.email_address, &near_date)?
            .map(|m| m.key)
            .unwrap_or_default();
        // Remember it regardless. On Graph the UID lookup can never match, and even on
        // Google the resync may not have landed the row yet — without this the banner
        // would offer to add an event that is already on the calendar.
        let _ = self.store.set_engine_setting(&added_ics_key(account_key, &info.uid), &key);
        log::info!("[calendar] added emailed event {} to {calendar_provider_id}", info.uid);
        Ok(key)
    }

    /// The calendar a "just add this" action should write to: the account's primary,
    /// else one it owns, else any writable one. Read-only calendars (shared,
    /// subscribed, holiday feeds) are skipped — the provider would 403 — and a
    /// calendar merely shared with write access is a last resort, not somewhere
    /// to silently drop the user's own events.
    ///
    /// The error names what was actually found, because "no writable calendar" on its
    /// own is indistinguishable from "we never synced any calendars".
    fn default_calendar_provider_id(&self, account_key: &str) -> Result<String> {
        let calendars = self.store.get_calendars_for_account(account_key)?;
        calendars
            .iter()
            .find(|c| c.is_primary && c.is_writable)
            .or_else(|| calendars.iter().find(|c| c.is_writable && c.is_owned))
            .or_else(|| calendars.iter().find(|c| c.is_writable))
            .map(|c| c.provider_id.clone())
            .filter(|id| !id.is_empty())
            .ok_or_else(|| {
                SyncError::Other(format!(
                    "no writable calendar for this account ({} synced: {})",
                    calendars.len(),
                    calendars
                        .iter()
                        .map(|c| format!("{}{}", c.name, if c.is_writable { "" } else { " (read-only)" }))
                        .collect::<Vec<_>>()
                        .join(", ")
                ))
            })
    }

    /// RSVP to an emailed invite ("sync back to the source"), two rails:
    /// - if the UID maps to a synced event AND the account has a calendar API
    ///   (Gmail/Microsoft), write the response through that API;
    /// - otherwise (IMAP, or an unsynced calendar) email a `METHOD:REPLY` .ics to
    ///   the organizer via the durable outbox (threaded onto the invite).
    pub async fn respond_invite(
        &self,
        account_key: &str,
        message_key: &str,
        attachment_id: &str,
        response: &str,
    ) -> Result<()> {
        let (partstat, subject_prefix) = crate::sync::ics::response_to_partstat(response)
            .ok_or_else(|| SyncError::Other(format!("invalid RSVP response: {response}")))?;

        // Re-download+parse so the reply is built from the authoritative ICS.
        let provider = self.interactive_provider(account_key)?;
        let bytes = provider.download_attachment(message_key, attachment_id).await?;
        let text = String::from_utf8_lossy(&bytes);
        let info = crate::sync::ics::parse_ics(&text)
            .ok_or_else(|| SyncError::Other("attachment is not a parseable invite".into()))?;

        let account = self
            .store
            .get_account(account_key)?
            .ok_or_else(|| SyncError::Other("account not found".into()))?;

        // Preferred: RSVP through the provider's calendar API when synced.
        if self.calendar_adapter(account_key)?.is_some() {
            let near_date = info.start.as_deref().and_then(|s| s.get(0..10)).unwrap_or("").to_string();
            if let Some(m) =
                self.store.event_by_ical_uid(account_key, &info.uid, &account.email_address, &near_date)?
            {
                self.respond_calendar_event_by_key(account_key, &m.key, response).await?;
                return Ok(());
            }
        }

        // Fallback: email a METHOD:REPLY .ics to the organizer.
        let Some(organizer) = info.organizer_email.clone() else {
            return Err(SyncError::Other("invite has no organizer to reply to".into()));
        };
        let dtstamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
        let reply_ics = crate::sync::ics::build_reply(
            &info,
            &account.email_address,
            Some(&account.display_name),
            partstat,
            &dtstamp,
        );
        let summary = info.summary.clone().unwrap_or_else(|| "invitation".into());
        let msg = crate::sync::interactive::OutgoingMessage {
            from_address: account.email_address.clone(),
            to_address: organizer,
            subject: Some(format!("{subject_prefix}: {summary}")),
            body_plain: Some(format!("{subject_prefix} the invitation \u{201c}{summary}\u{201d}.")),
            reply_to_message_key: Some(message_key.to_string()),
            attachments: vec![crate::sync::interactive::OutgoingAttachment {
                filename: "invite.ics".into(),
                mime_type: Some("text/calendar; method=REPLY".into()),
                data: reply_ics.into_bytes(),
            }],
            ..Default::default()
        };
        self.enqueue_send(account_key, msg).await?;
        Ok(())
    }
}

/// `engine_settings` key recording that this account already added this ICS UID to
/// its calendar. The value is the local event key, or empty when the resync hadn't
/// produced the row yet.
fn added_ics_key(account_key: &str, uid: &str) -> String {
    format!("ics_added:{account_key}:{uid}")
}

/// An end time for an ICS that gave none. RFC 5545 lets DTEND be omitted (and lets
/// DURATION stand in, which this parser doesn't read), but neither calendar API
/// accepts an event without one.
///
/// ponytail: fixed +1h / +1 day rather than reading DURATION — booking confirmations
/// in the wild all carry DTEND. Parse DURATION here if one ever shows up without it.
fn default_end(start_at: &str, all_day: bool) -> String {
    use chrono::{Duration, NaiveDate, NaiveDateTime};
    if all_day {
        // DTEND is exclusive for all-day events, so "one day" is start + 1.
        return NaiveDate::parse_from_str(start_at, "%Y-%m-%d")
            .map(|d| (d + Duration::days(1)).format("%Y-%m-%d").to_string())
            .unwrap_or_else(|_| start_at.to_string());
    }
    NaiveDateTime::parse_from_str(start_at, "%Y-%m-%dT%H:%M:%S")
        .map(|dt| (dt + Duration::hours(1)).format("%Y-%m-%dT%H:%M:%S").to_string())
        .unwrap_or_else(|_| start_at.to_string())
}

#[cfg(test)]
mod add_to_calendar_tests {
    use super::default_end;

    #[test]
    fn fills_in_a_missing_end() {
        assert_eq!(default_end("2025-09-16T10:00:00", false), "2025-09-16T11:00:00");
        // Crossing midnight must roll the date, not just the clock.
        assert_eq!(default_end("2025-09-16T23:30:00", false), "2025-09-17T00:30:00");
        // All-day DTEND is exclusive: a one-day event ends the next morning.
        assert_eq!(default_end("2025-09-16", true), "2025-09-17");
        // Unparseable in, unchanged out — never fabricate a time.
        assert_eq!(default_end("not-a-date", false), "not-a-date");
    }
}
