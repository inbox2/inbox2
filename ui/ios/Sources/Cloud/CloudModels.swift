import Foundation

// Engine-coupled bridging from the inbox2-domain ("MX") API DTOs → the shared
// row/reader view models (Conversation / Message). The pure Codable DTOs themselves
// live in CloudDTOs.swift (shared with the Share Extension target); these extensions
// reference app-only view models, so they stay in the app target.

// MARK: - Mapping domain (API) models → the shared row/reader models

extension Conversation {
    /// Build a row-model `Conversation` from a domain (API) conversation. The
    /// `accountKey` is the org id — which is how the inbox/reader/compose route a
    /// domain thread's reads + actions to the cloud client instead of the engine
    /// (org ids are `org_…`, distinct from external-account keys).
    init(cloud c: CloudConversation, orgId: String) {
        self.init(
            id: c.id, accountKey: orgId,
            fromAddress: c.fromAddress ?? "", toAddress: c.toAddress ?? "",
            subject: c.subject ?? "", snippet: c.snippet ?? "",
            status: c.status, unread: !c.read,
            hasAttachment: false, priorityUrgent: false, priorityImportant: false,
            aiSummary: nil,
            triageLabel: c.triageLabel, aiSummaryMedium: nil, aiSummaryShort: c.aiSummaryShort,
            createdAt: c.createdAt ?? "", updatedAt: c.updatedAt ?? c.createdAt ?? "",
            messageCount: c.messageCount ?? 1, triagePriority: c.triagePriority,
            dueOn: c.nextActionDueOn, loreDone: c.loreDone ?? false
        )
    }

    /// True for an inbox2-domain thread (routes reads/actions through CloudClient).
    var isDomain: Bool { AccountKey.isDomain(accountKey) }

    /// Backend capabilities, surfaced so menus read intent (`supportsTriage`) instead
    /// of re-deriving `isDomain` inline. Offline (engine) channels do local flag +
    /// triage-quadrant moves; the domain (API) pool does snooze instead.
    var supportsTriage: Bool { !isDomain }   // flag + Eisenhower quadrants
    var supportsSnooze: Bool { isDomain }

    /// In spam/trash/archived → offer "Move to Inbox" (restore to `open`).
    var isRestorable: Bool { ConvStatusValue.inboxHidden.contains(status) }
    /// The action that restores this thread to the inbox, resolved from its status.
    var restoreAction: ConversationAction? { ConversationAction.restore(fromStatus: status) }

    /// Build a row from a draft message (the Drafts folder). The row id is the
    /// draft's conversation so tapping opens the thread; subject/snippet preview it.
    init?(draft m: CloudMessage, orgId: String) {
        guard let convId = m.conversationId else { return nil }
        let preview = (m.bodyPlain ?? m.bodyHtml ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: convId, accountKey: orgId,
            fromAddress: m.fromAddress ?? "", toAddress: m.toAddress ?? "",
            subject: (m.subject?.isEmpty == false ? m.subject! : "(No subject)"),
            snippet: String(preview.prefix(140)),
            status: ConvStatusValue.open, unread: false,
            hasAttachment: false, priorityUrgent: false, priorityImportant: false,
            aiSummary: nil,
            triageLabel: nil, aiSummaryMedium: nil, aiSummaryShort: nil,
            createdAt: m.createdAt ?? "", updatedAt: m.createdAt ?? "",
            messageCount: 1
        )
    }
}

extension Message {
    init(cloud m: CloudMessage) {
        self.init(
            id: m.id, fromAddress: m.fromAddress ?? "", toAddress: m.toAddress ?? "",
            ccAddress: m.ccAddress, subject: m.subject ?? "",
            bodyPlain: m.bodyPlain, bodyHTML: m.bodyHtml,
            isInbound: m.isInbound, isDraft: m.isDraft,
            createdAt: m.createdAt ?? "", sentimentLabel: nil, intentLabel: nil,
            invite: m.invite, meetingRequest: m.meetingRequest
        )
    }
}

extension ClientInvite {
    /// "Wed, Jun 10, 2026 · 9:00 AM – 10:00 AM" (mirrors web `formatWhen`; reuses the
    /// reader's date formatter). nil when there's no parseable start. Lives here (app
    /// target) because it uses `RelativeTime`, which the Share-Extension target omits.
    var whenLabel: String? {
        guard let start = startDate else { return nil }
        let s = RelativeTime.longParts(start)
        if isAllDay { return "\(s.date) · All day" }
        if let end = endDate { return "\(s.date) · \(s.time) – \(RelativeTime.longParts(end).time)" }
        return "\(s.date) · \(s.time)"
    }

    /// `start`/`end` as instants, read in the invite's own zone (web `inviteInstant`).
    /// All-day reads only the date, as your midnight (MX sends it as `…T00:00:00Z`).
    var startDate: Date? { start.flatMap(instant) }
    var endDate: Date? { end.flatMap(instant) }
    private func instant(_ s: String) -> Date? {
        allDay == true ? RelativeTime.parse(String(s.prefix(10))) : RelativeTime.parse(s, zone: timezone)
    }
}
