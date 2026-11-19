import SwiftUI

/// The meeting-invite (RSVP / Add to calendar) and Meet-link booking-request banners
/// a `MessageCard` shows above the body, plus their resolution + response plumbing.
/// State stays on the card (it must survive collapse/expand); this file only owns
/// the views and the calls behind them.
extension MessageCard {
    /// Populate the invite banner: MX messages carry `message.invite` (preselect its
    /// recorded RSVP); local-channel messages resolve it from a calendar attachment via
    /// the core. A no-op when neither source applies.
    func resolveInvite() async {
        if let mx = message.invite {
            inviteStatus = mx.answeredStatus
            // An MX PUBLISH is an event to file, not an invitation. The API records the
            // import as a calendar event, not on the message, so there is no "already
            // added" state to restore here — the banner resets on reopen.
            await loadNearbyEvents(mx)
            return
        }
        guard !AccountKey.isDomain(accountKey) else { return }
        // Both shapes are kept now: a REQUEST gets the RSVP buttons, anything else
        // (an appointment confirmation, a booking) gets "Add to calendar". No ICS at
        // all → the meeting triage read out of the body, if any.
        let resolved: ClientInvite?
        if let att = calendarAttachment {
            resolved = await engine.inviteFor(accountKey: accountKey, messageKey: message.id, attachmentId: att.attachmentId)
        } else {
            resolved = await engine.detectedInvite(accountKey: accountKey, messageKey: message.id)
        }
        guard let inv = resolved, inv.isRequest || inv.isAddable else { return }
        await loadNearbyEvents(inv)
        localInvite = inv
        inviteStatus = inv.answeredStatus
        // Already on the calendar (synced, or added on an earlier read) — show the
        // confirmation rather than offering to add it a second time. A present-but-
        // empty key still means added; it just has no event to deep-link to yet.
        if inv.isAddable, let key = inv.matchedEventKey { addedEventKey = key }
    }

    /// Load the calendar around the invite (±2h, timed events only), bounded coarsely
    /// by a day either side — `start_at` is stored in mixed offset forms — then
    /// filtered precisely on the parsed dates.
    private func loadNearbyEvents(_ invite: ClientInvite) async {
        guard let start = invite.startDate else { return }
        let end = invite.endDate ?? start
        let lo = start.addingTimeInterval(-2 * 3600), hi = end.addingTimeInterval(2 * 3600)
        let iso = ISO8601DateFormatter()
        let fromISO = iso.string(from: lo.addingTimeInterval(-86400)), toISO = iso.string(from: hi.addingTimeInterval(86400))
        let rows = await engine.store.read { $0.eventsBetween(fromISO: fromISO, toISO: toISO, limit: 60) }
        nearbyEvents = rows.filter { e in
            guard !e.allDay, e.id != invite.matchedEventKey, let s = e.start else { return false }
            return s < hi && (e.end ?? s) > lo
        }
    }

    /// An event starting within 15 min of the detected meeting is taken to BE it —
    /// the meeting was already scheduled some other way. Time only: the detected
    /// title is the model's wording, so it rarely matches the saved one.
    private func sameTimeEvent(_ invite: ClientInvite) -> CalendarEvent? {
        guard invite.isDetected, let start = invite.startDate else { return nil }
        return nearbyEvents.first { e in e.start.map { abs($0.timeIntervalSince(start)) <= 15 * 60 } ?? false }
    }

    /// The `text/calendar` (ICS) attachment on this message, if any — the local-invite
    /// source and the RSVP target.
    private var calendarAttachment: AttachmentInfo? {
        attachments.first { $0.mimeType == "text/calendar" || $0.filename.lowercased().hasSuffix(".ics") }
    }

    /// The invite to show (MX pre-parsed, else the resolved local one): a REQUEST to
    /// answer, or a plain event to add. Matches the web banner.
    var invite: ClientInvite? {
        let inv = message.invite ?? localInvite
        return (inv?.isRequest == true || inv?.isAddable == true) ? inv : nil
    }

    /// Outlook-style meeting-invite RSVP banner: event summary/time/location over three
    /// response buttons; the chosen response fills, the others stay neutral. Modeled on
    /// the sibling `showImagesBar`. RSVP routes to the cloud API (MX) or the engine
    /// (local channels).
    @ViewBuilder func meetingInviteBar(_ invite: ClientInvite) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if invite.isDetected {
                // Not an emailed invite: triage found it in the body.
                Label("Found in this email", systemImage: "sparkles")
                    .font(AppFont.xs2).foregroundStyle(p.textSecondary)
            }
            // Tapping the event info opens the calendar straight to this event's
            // detail (only when it maps to a synced calendar event).
            Button {
                if let key = invite.matchedEventKey, !key.isEmpty {
                    chrome.pendingCalendarEventKey = key
                }
            } label: {
                HStack(alignment: .top, spacing: Space.s2) {
                    Image(systemName: "calendar").font(AppFont.base).foregroundStyle(p.accentViolet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.summary?.isEmpty == false ? invite.summary! : "Meeting invitation")
                            .font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(2)
                        if let when = invite.whenLabel {
                            Text(when).font(AppFont.xs).foregroundStyle(p.textSecondary)
                        }
                        if let loc = invite.location, !loc.isEmpty {
                            Text(loc).font(AppFont.xs2).foregroundStyle(p.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if invite.matchedEventKey?.isEmpty == false {
                        Image(systemName: "chevron.right").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(invite.matchedEventKey?.isEmpty != false)
            if invite.isAddable, addedEventKey == nil, let same = sameTimeEvent(invite) {
                HStack(spacing: Space.s2) {
                    Image(systemName: "checkmark.circle.fill").font(AppFont.sm).foregroundStyle(p.accentSuccess)
                    Text("Already on your calendar: \(same.title)").font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(2)
                }
            } else if invite.isAddable {
                addToCalendarRow(invite)
            } else if let s = inviteStatus, !inviteChanging {
                // Answered → compact "You accepted · Change" (mirrors the desktop banner).
                HStack(spacing: Space.s2) {
                    Image(systemName: "checkmark.circle.fill").font(AppFont.sm).foregroundStyle(p.accentSuccess)
                    Text(Self.inviteStatusLabel(s)).font(AppFont.sm).foregroundStyle(p.textPrimary)
                    Spacer(minLength: 0)
                    Button { withAnimation { inviteChanging = true } } label: {
                        Text("Change").font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: Space.s2) {
                    ForEach(Self.inviteResponses, id: \.key) { r in
                        // Only the selected answer is tinted (primary); the rest share one
                        // muted neutral — no per-response semantic colors.
                        let selected = inviteStatus == r.key
                        Button { respond(r.key) } label: {
                            Text(r.label)
                                .font(AppFont.xs(.semibold))
                                .foregroundStyle(selected ? p.bgBase : p.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.s2)
                                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .fill(selected ? p.accentViolet : p.bgRaised))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .stroke(p.borderSubtle, lineWidth: selected ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(inviteBusy)
                    }
                }
            }
            if !nearbyEvents.isEmpty { nearbyEventsList(invite) }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s3)
        .background(p.accentViolet.opacity(0.08))
    }

    /// "Around this time": one line per nearby event; one that overlaps the invite is
    /// warm, like the desktop's `soon` emphasis.
    @ViewBuilder private func nearbyEventsList(_ invite: ClientInvite) -> some View {
        let start = invite.startDate
        let end = invite.endDate ?? start
        VStack(alignment: .leading, spacing: 4) {
            Text("Around this time").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            ForEach(nearbyEvents) { e in
                let clash = start != nil && end != nil && (e.start ?? .distantPast) < end! && (e.end ?? e.start ?? .distantPast) > start!
                HStack(spacing: Space.s2) {
                    Text(e.start.map { Self.nearbyTime.string(from: $0) } ?? "")
                        .font(AppFont.xs).foregroundStyle(clash ? p.accentWarmBright : p.textSecondary)
                        .frame(width: 64, alignment: .leading)
                    Text(e.title).font(AppFont.xs).foregroundStyle(clash ? p.accentWarmBright : p.textPrimary).lineLimit(1)
                }
            }
        }
        .padding(.top, Space.s1)
    }

    private static let nearbyTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// The non-REQUEST half of the banner: one "Add to calendar" button that writes the
    /// event through the account's own calendar API, flipping to a confirmation that
    /// deep-links into the calendar once it lands.
    @ViewBuilder private func addToCalendarRow(_ invite: ClientInvite) -> some View {
        if let key = addedEventKey {
            HStack(spacing: Space.s2) {
                Image(systemName: "checkmark.circle.fill").font(AppFont.sm).foregroundStyle(p.accentSuccess)
                Text("Added to calendar").font(AppFont.sm).foregroundStyle(p.textPrimary)
                Spacer(minLength: 0)
                if !key.isEmpty {
                    Button { chrome.pendingCalendarEventKey = key } label: {
                        Text("View").font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet)
                    }.buttonStyle(.plain)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s1) {
                // Sized to its label, like the RSVP pills beside it — a single action
                // stretched edge to edge reads as a form submit, not one option.
                Button { addToCalendar(invite) } label: {
                    HStack(spacing: Space.s1) {
                        if inviteBusy { ProgressView().controlSize(.small).tint(p.bgBase) }
                        Text("Add to calendar").font(AppFont.xs(.semibold)).foregroundStyle(p.bgBase)
                    }
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .background {
                        if let key = p.primaryKeycap {
                            Color.clear.keycap(key, radius: Radius.full)
                        } else {
                            RoundedRectangle(cornerRadius: Radius.full, style: .continuous).fill(p.accentViolet)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(inviteBusy)
                if let addError {
                    Text("Couldn't add it: \(addError)")
                        .font(AppFont.xs2).foregroundStyle(p.accentDanger)
                }
            }
        }
    }

    private func addToCalendar(_ invite: ClientInvite) {
        inviteBusy = true
        addError = nil
        Task {
            let (ok, value): (Bool, String)
            if invite.isDetected, !AccountKey.isDomain(accountKey) {
                // Local detected meeting — no ICS; the core builds the event from the body.
                (ok, value) = await engine.addDetectedMeetingToCalendar(accountKey: accountKey, messageKey: message.id)
            } else if let attachmentId = invite.attachmentId, !attachmentId.isEmpty {
                // Local channel — write through the account's own calendar API.
                (ok, value) = await engine.addInviteToCalendar(accountKey: accountKey, messageKey: message.id,
                                                               attachmentId: attachmentId)
            } else if let orgId = cloud.currentOrgId {
                // MX — the API places it on the member's org calendar.
                let sent = await cloud.importCalendarEvent(orgId: orgId, messageId: message.id)
                (ok, value) = (sent, sent ? "" : "the server couldn't add it")
            } else {
                (ok, value) = (false, "not signed in")
            }
            await MainActor.run {
                inviteBusy = false
                if ok { withAnimation { addedEventKey = value } } else { addError = value }
            }
        }
    }

    /// Meet-link booking request (docs/Calendar.md) — the web `MeetingRequestBanner`.
    /// Nothing is on the calendar until Accept, which creates the event and mails the
    /// visitor an invite; Decline mails them a no. Final either way: no "Change".
    @ViewBuilder func meetingRequestBar(_ request: ClientMeetingRequest) -> some View {
        let status = requestAnswer ?? (request.status == "pending" ? nil : request.status)
        let start = request.start.flatMap(RelativeTime.parse)
        let end = request.end.flatMap(RelativeTime.parse)
        let minutes = (start != nil && end != nil) ? Int(end!.timeIntervalSince(start!) / 60) : nil
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: "calendar").font(AppFont.base).foregroundStyle(p.accentViolet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.name ?? "Someone") requests \(minutes.map { "a \($0)-minute meeting" } ?? "a meeting")")
                        .font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(2)
                    if let start, let end {
                        Text("\(Self.requestDay.string(from: start)) · \(Self.nearbyTime.string(from: start)) – \(Self.nearbyTime.string(from: end))")
                            .font(AppFont.xs).foregroundStyle(p.textSecondary)
                    }
                    if let tz = request.visitorTimezone, tz != TimeZone.current.identifier,
                       let zone = TimeZone(identifier: tz), let start, let end {
                        Text("Their time: \(Self.time(start, in: zone)) – \(Self.time(end, in: zone))")
                            .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    }
                }
            }
            if let note = request.note, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}").font(AppFont.xs).italic().foregroundStyle(p.textSecondary)
            }
            if let status {
                HStack(spacing: Space.s2) {
                    Image(systemName: status == "accepted" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(AppFont.sm).foregroundStyle(status == "accepted" ? p.accentSuccess : p.textTertiary)
                    Text(Self.requestStatusLabel(status)).font(AppFont.sm).foregroundStyle(p.textPrimary)
                }
            } else {
                HStack(spacing: Space.s2) {
                    requestButton("Accept", primary: true) { answerRequest(request, accept: true) }
                    requestButton("Decline…", primary: false) { declineReason = ""; showDecline = true }
                }
                Text(Self.conferenceHint[request.conferenceMode ?? ""] ?? "Not on your calendar yet.")
                    .font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }
            if let requestError {
                Text(requestError).font(AppFont.xs2).foregroundStyle(p.accentDanger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s3)
        .background(p.accentViolet.opacity(0.08))
        .alert("Decline this request?", isPresented: $showDecline) {
            TextField("Reason (optional)", text: $declineReason)
            Button("Send decline", role: .destructive) { answerRequest(request, accept: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They get an email, with your reason if you give one.")
        }
    }

    private func requestButton(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                if primary && requestBusy { ProgressView().controlSize(.small).tint(p.bgBase) }
                Text(label).font(AppFont.xs(.semibold)).foregroundStyle(primary ? p.bgBase : p.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s2)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(primary ? p.accentViolet : p.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(p.borderSubtle, lineWidth: primary ? 0 : 1))
        }
        .buttonStyle(.plain)
        .disabled(requestBusy)
    }

    private func answerRequest(_ request: ClientMeetingRequest, accept: Bool) {
        guard !requestBusy else { return }
        requestBusy = true
        requestError = nil
        let reason = declineReason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let error = await cloud.answerMeetingRequest(orgId: accountKey, requestId: request.key,
                                                         accept: accept, reason: reason.isEmpty ? nil : reason)
            await MainActor.run {
                requestBusy = false
                if let error { requestError = error } else { withAnimation { requestAnswer = accept ? "accepted" : "declined" } }
            }
        }
    }

    private static let conferenceHint = [
        "meet": "Accepting adds a Google Meet link.",
        "teams": "Accepting adds a Teams link.",
    ]

    private static func requestStatusLabel(_ s: String) -> String {
        switch s {
        case "accepted": return "You accepted. It's on your calendar."
        case "declined": return "You declined."
        case "expired": return "This request expired before you answered."
        default: return s
        }
    }

    private static let requestDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()

    /// One cached formatter; only the zone changes per call (main-thread UI only).
    private static let zonedTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private static func time(_ d: Date, in zone: TimeZone) -> String {
        zonedTime.timeZone = zone
        return zonedTime.string(from: d)
    }

    /// The three RSVP options (raw status → button label). Order matches the web banner.
    private static let inviteResponses: [(key: String, label: String)] =
        [("accepted", "Accept"), ("tentative", "Tentative"), ("declined", "Decline")]

    private static func inviteStatusLabel(_ s: String) -> String {
        switch s {
        case "accepted": return "You accepted"
        case "tentative": return "You're tentative"
        case "declined": return "You declined"
        default: return s
        }
    }

    /// Send the RSVP to the right backend and highlight the chosen response.
    private func respond(_ resp: String) {
        guard !inviteBusy else { return }
        inviteBusy = true
        Task {
            let ok: Bool
            if message.invite != nil {
                ok = await cloud.rsvp(orgId: accountKey, messageId: message.id, status: resp)
            } else if let att = calendarAttachment {
                ok = await engine.respondToInvite(accountKey: accountKey, messageKey: message.id, attachmentId: att.attachmentId, response: resp)
            } else {
                ok = false
            }
            await MainActor.run {
                inviteBusy = false
                if ok {
                    withAnimation { inviteStatus = resp; inviteChanging = false }
                    onInviteAnswered?()
                }
            }
        }
    }
}
