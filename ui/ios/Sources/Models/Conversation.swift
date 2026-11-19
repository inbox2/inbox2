import Foundation

/// Conversation lifecycle status — mirrors the desktop engine's `ConversationStatus`
/// and the frontend `CONV_STATUS` (lib/conversationStatus.js). The stored value on
/// a conversation is one of these raw strings.
enum ConvStatusValue {
    static let open = "open"
    static let archived = "archived"
    static let spam = "spam"
    static let trash = "trash"

    /// Hidden from the inbox + unified list (mirrors `INBOX_HIDDEN_STATUSES`).
    static let inboxHidden = [trash, spam, archived]
    /// "Not real mail" — deleted or junk; archived still counts (mirrors
    /// `DISCARDED_STATUSES`). Used for search, which should surface archived mail.
    static let discarded = [trash, spam]
}

/// Outbox delivery status — mirrors the desktop engine's `OutboxStatus`
/// (sync/model.rs). The stored value on an `outbox_messages` row is one of these.
enum OutboxStatusValue {
    static let pending = "pending"
    static let sending = "sending"
    static let sent = "sent"
    static let failed = "failed"

    /// In the outbox view (the actionable queue) — everything not yet delivered.
    static let queued = [pending, sending, failed]
}

/// The badge shown on a row / header — a small visual classification derived from
/// the conversation's priority flags + AI state, mirroring the desktop quadrant
/// tags. (Distinct from the raw lifecycle `status` string above.)
enum ConvStatus: String {
    case open, pending, urgent, ai, archived
    var label: String {
        switch self {
        case .open: return "Open"
        case .pending: return "Pending"
        case .urgent: return "Urgent"
        case .ai: return "AI"
        case .archived: return "Archived"
        }
    }
}

/// A conversation row as read from local SQLite. Field names map 1:1 to the
/// `conversations` table; display-oriented values are derived lazily so the read
/// layer stays a thin projection of the DB (parity with the desktop's read hooks).
struct Conversation: Identifiable, Hashable {
    let id: String            // conversations.key
    let accountKey: String    // conversations.organization_id (the external account key)
    let fromAddress: String   // raw "Name <email>"
    let toAddress: String
    let subject: String
    let snippet: String
    let status: String        // raw lifecycle status: open/archived/spam/trash
    let unread: Bool          // !read
    let hasAttachment: Bool
    let priorityUrgent: Bool
    let priorityImportant: Bool
    let aiSummary: String?
    /// Async triage classification (raw slug, e.g. "needs_answer" or a custom
    /// label's slug); nil until the thread is triaged. See `triage`.
    var triageLabel: String?
    /// A few-line summary (summary of the full summary); nil until processed.
    let aiSummaryMedium: String?
    /// A one-line summary; nil until processed.
    var aiSummaryShort: String?
    let createdAt: String     // ISO-8601, e.g. "2026-06-01T17:33:58+00:00"
    let updatedAt: String
    let messageCount: Int
    /// The latest outbound (sent-by-user) message's date, for the Sent folder —
    /// the thread's `updatedAt` can be bumped by a later inbound reply or a
    /// message with an unparseable Date header. nil when none / not selected.
    var sentAt: String? = nil
    /// Jev's 0–4 attention score (`triage_priority`); nil until scored. See `TriagePriority`.
    var triagePriority: Double? = nil
    /// True when the stored summaries were generated for the thread's LATEST
    /// message (`ai_meta_msg_key`, the same currency rule the core's email-voice
    /// uses) — false while a newer message awaits the triage worker. Populated by
    /// `InboxStore.conversation(key:)`; list/cloud constructors default to true.
    var summariesCurrent: Bool = true
    /// Due date Jev's next-action pass found in the mail (`next_action_due_on`,
    /// "2026-10-24"); nil when none. Lore ranks near deadlines higher.
    var dueOn: String? = nil
    /// The signed-in member ticked this personal-bucket thread off in Lore (`lore_done`,
    /// MX only). Hidden from their Today; the thread itself stays open for the team.
    var loreDone: Bool = false

    /// The built-in triage label, or nil when unprocessed or a custom slug.
    var triage: TriageLabel? { triageLabel.flatMap(TriageLabel.init(rawValue:)) }

    // ── Derived display values ──
    /// The MX org a row belongs to (its accountKey IS the org for MX rows); nil for
    /// local channel rows and `dom_…` keys, which fall back to the current org.
    var mxOrgId: String? { accountKey.hasPrefix(AccountKey.domainPrefix) ? accountKey : nil }
    var sender: String { MailAddress.parse(fromAddress).name }
    var email: String { MailAddress.parse(fromAddress).email }
    var initials: String { MailAddress.initials(fromAddress) }
    var seed: Int { MailAddress.seed(email.isEmpty ? id : email) }
    var time: String { RelativeTime.short(updatedAt) }

    /// The one line of body text shown under the subject in a list row: the triage
    /// worker's generated one-liner once it exists, else the raw body snippet — so a
    /// row starts with the snippet and upgrades in place when triage lands.
    /// A model-less triage run writes the SUBJECT as `aiSummaryShort` (see
    /// `deterministic_summaries` in the core), which would render as
    /// "Subject / Subject"; those echoes keep the snippet. Mirrors the web
    /// `conversationPreview()` and the Android `preview`.
    var preview: String {
        let summary = (aiSummaryShort ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "", options: [.anchored, .backwards])
        guard !summary.isEmpty,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased().hasPrefix(summary.lowercased())
        else { return snippet }
        return summary
    }

    // Recipient-facing display, for the Sent folder — where the from-address is
    // always the user, so the useful identity is who the mail was sent TO. Shows
    // the first recipient + "+N" for extras. Mirrors the web recipientName().
    var recipient: String {
        let list = MailAddress.parseList(toAddress)
        guard let first = list.first else { return "(no recipient)" }
        let name = first.name.isEmpty ? first.email : first.name
        return list.count > 1 ? "\(name) +\(list.count - 1)" : name
    }
    /// Sent-folder timestamp: when the user actually sent, falling back to the
    /// thread time when no outbound date is recorded.
    var sentTime: String { RelativeTime.short((sentAt?.isEmpty == false ? sentAt : nil) ?? updatedAt) }
    var recipientInitials: String { MailAddress.initials(toAddress) }
    var recipientSeed: Int {
        let email = MailAddress.parseList(toAddress).first?.email ?? ""
        return MailAddress.seed(email.isEmpty ? id : email)
    }

    /// The visual badge, in priority order: urgent → AI-handled → important.
    /// Nil for a plain open thread (so the row stays clean).
    var badge: ConvStatus? {
        if status == ConvStatusValue.archived { return .archived }
        if priorityUrgent { return .urgent }
        if aiSummary?.isEmpty == false { return .ai }
        if priorityImportant { return .pending }
        return nil
    }
}

/// A single message within a conversation — maps to the `messages` table. Bodies
/// may be empty in the row (provider enrichment fills them on desktop); on iOS we
/// render whatever the local store holds.
struct Message: Identifiable, Hashable {
    let id: String            // messages.key
    let fromAddress: String
    let toAddress: String
    let ccAddress: String?
    let subject: String
    let bodyPlain: String?
    let bodyHTML: String?
    let isInbound: Bool
    let isDraft: Bool
    let createdAt: String     // ISO-8601
    let sentimentLabel: String?   // on-device AI; nil for most messages
    let intentLabel: String?
    /// A pre-parsed meeting invite (MX messages carry it from the API); nil for local
    /// channels, whose invite is resolved lazily from the calendar attachment in the
    /// reader. Defaulted so the SQLite + cloud constructors don't have to pass it.
    var invite: ClientInvite? = nil
    /// A meet-link booking request (MX only) — Accept/Decline banner in the reader.
    var meetingRequest: ClientMeetingRequest? = nil

    var sender: String { MailAddress.parse(fromAddress).name }
    var email: String { MailAddress.parse(fromAddress).email }
    var initials: String { MailAddress.initials(fromAddress) }
    var seed: Int { MailAddress.seed(email.isEmpty ? id : email) }
    var time: String { RelativeTime.short(createdAt) }

    /// Real on-device sentiment, if classified: true/false, else nil (no badge).
    var sentimentPositive: Bool? {
        switch sentimentLabel?.uppercased() {
        case "POSITIVE": return true
        case "NEGATIVE": return false
        default: return nil
        }
    }

    /// Normalized intent kind for `AIBadge.intent`, or nil when unclassified / junk.
    var intentKind: IntentKind? { IntentKind.from(intentLabel) }

    /// Best available body for the WebView reader: prefer HTML, else wrap plain
    /// text so the shared email-body JS + CSP path still applies.
    var bodyForReader: String {
        if let html = bodyHTML, !html.isEmpty { return html }
        let plain = (bodyPlain ?? "").isEmpty ? "(No content)" : bodyPlain!
        let escaped = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<div style=\"white-space:pre-wrap\">\(escaped)</div>"
    }
}

/// A recipient suggestion for compose autocomplete, derived from how often an
/// address appears across the user's mail (mirrors the desktop useContactSuggestions).
struct Contact: Identifiable, Hashable {
    var id: String { email }
    let email: String
    let name: String
    let total: Int

    /// "Dana Lee <dana@x.com>" or just the email when there's no distinct name.
    var formatted: String {
        (name.isEmpty || name.lowercased() == email) ? email : "\(name) <\(email)>"
    }
}

/// Attachment metadata for a message, fetched live from the provider via the FFI
/// (`fetch_message`). Bytes are downloaded on demand (`download_attachment`).
// One recorded open of a tracked sent message (docs/Open-Tracking.md).
struct MessageOpen: Identifiable, Hashable {
    var id: String { "\(openedAt)-\(ip ?? "")" }
    let openedAt: String
    let ip: String?
    let geoCountry: String?
    let geoCity: String?
    let proxied: Bool
    let proxyKind: String?
    let userAgent: String?

    var location: String {
        let parts = [geoCity, geoCountry].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return ip ?? "Unknown location"
    }
}

struct AttachmentInfo: Identifiable, Hashable {
    var id: String { attachmentId }
    let attachmentId: String
    let filename: String
    let mimeType: String
    let size: Int

    var sizeLabel: String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.0f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }
    /// SF Symbol matching the file kind.
    var icon: String {
        let m = mimeType.lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.hasPrefix("video/") { return "video" }
        if m.hasPrefix("audio/") { return "music.note" }
        if m.contains("zip") || m.contains("compressed") { return "doc.zipper" }
        if m.contains("spreadsheet") || m.contains("excel") || filename.hasSuffix(".csv") { return "tablecells" }
        return "doc"
    }
}

/// One entry in the Activity feed — a recent inbound message. Carries the
/// conversation key so a tap can open the thread.
struct ActivityEntry: Identifiable, Hashable {
    let id: String            // messages.key
    let fromAddress: String
    let createdAt: String     // ISO-8601
    let conversationKey: String
    let subject: String
    let unread: Bool

    var sender: String { MailAddress.parse(fromAddress).name }
    var initials: String { MailAddress.initials(fromAddress) }
    var seed: Int { MailAddress.seed(MailAddress.parse(fromAddress).email) }
    var time: String { RelativeTime.short(createdAt) }
    /// "Dana Lee — Re: Q3 pipeline review"
    var text: String { "\(sender) · \(subject)" }
}

/// Parse "Display Name <email@host>" headers and derive avatar initials + a stable
/// color seed. Kept tiny + dependency-free so it ports to Android later.
enum MailAddress {
    static func parse(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "<"),
              let close = trimmed.firstIndex(of: ">"), open < close else {
            // No angle brackets: the whole thing is an address (or empty).
            return (trimmed.isEmpty ? "Unknown" : trimmed, trimmed)
        }
        let email = String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            // One quoted-string: drop the pair, then unescape `\"`/`\\` (see `format`).
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        } else {
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if name.isEmpty { name = email }
        return (name, email)
    }

    /// Parse a recipient header that may be a comma-separated list. Splits on
    /// commas outside angle brackets/quotes so `"Doe, Jane" <j@x>` stays intact.
    static func parseList(_ raw: String) -> [(name: String, email: String)] {
        var parts: [String] = []
        var current = ""
        var inAngle = false, inQuote = false, escaped = false
        for ch in raw {
            if escaped { escaped = false; current.append(ch); continue }
            switch ch {
            case "\\" where inQuote: escaped = true; current.append(ch)
            case "\"": inQuote.toggle(); current.append(ch)
            case "<": inAngle = true; current.append(ch)
            case ">": inAngle = false; current.append(ch)
            case "," where !inAngle && !inQuote:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts.map { parse($0) }.filter { $0.email.contains("@") }
    }

    /// `Name <addr>`, the name RFC 5322-quoted when it holds anything a list would
    /// split on (`"Veger, Nick" <v@x>`). Mirrors web `formatMailbox`.
    static func format(_ name: String, _ email: String) -> String {
        if name.isEmpty { return email }
        let safe = name.range(of: #"^[A-Za-z0-9_ !#$%&'*+\-/=?^`{|}~]+$"#, options: .regularExpression) != nil
        let n = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return safe ? "\(name) <\(email)>" : "\"\(n)\" <\(email)>"
    }

    static func initials(_ raw: String) -> String {
        let name = parse(raw).name
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// Deterministic small int so the same sender always gets the same ring color.
    static func seed(_ key: String) -> Int {
        var h = 5381
        for b in key.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return abs(h)
    }
}

/// Compact relative timestamps for list rows ("9:14 AM", "Mon", "May 3"), from an
/// ISO-8601 string. Mirrors the desktop's terse list time formatting.
enum RelativeTime {
    // ISO8601DateFormatter is thread-safe once configured; reuse one instance.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Reused row formatter — `short(_:)` is on the list-row hot path, so don't
    /// allocate a DateFormatter per call; it swaps `dateFormat` per call instead.
    /// DateFormatter is NOT thread-safe: main-thread-only, the same assumption as
    /// the cached `dateOnly` below (row/reader rendering).
    private static let shortFmt = DateFormatter()

    static func short(_ iso8601: String) -> String {
        guard !iso8601.isEmpty, let date = parse(iso8601) else { return "" }
        let cal = Calendar.current
        let now = Date()
        let f = shortFmt
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mm a"
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            f.dateFormat = "EEE"          // weekday
        } else if cal.isDate(date, equalTo: now, toGranularity: .year) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: date)
    }

    // Cached like `dateOnly`/`shortFmt` — DateFormatter alloc per call is wasteful;
    // same main-thread-only assumption.
    private static let longDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()
    private static let longTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// ("Wed, Jun 10, 2026", "9:33 AM") for the reader's date row, which sets the
    /// date and time in the code font around a normal-font "at".
    static func longParts(_ iso8601: String) -> (date: String, time: String)? {
        guard !iso8601.isEmpty, let date = parse(iso8601) else { return nil }
        return longParts(date)
    }

    static func longParts(_ date: Date) -> (date: String, time: String) {
        (longDateFmt.string(from: date), longTimeFmt.string(from: date))
    }

    // Date-only form ("2026-05-05"), used by all-day calendar events, in the
    // local zone so it groups on the right day.
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // A floating wall clock with no zone ("2026-10-07T16:30:00" — a floating ICS time
    // or a detected meeting), read in the device's zone like RFC 5545 says.
    private static let floating: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Parse an ISO-8601 timestamp, tolerating a fractional-seconds form, a floating
    /// (zone-less) wall clock and the date-only form used by all-day events.
    static func parse(_ iso8601: String) -> Date? {
        if let d = iso.date(from: iso8601) { return d }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: iso8601) { return d }
        if let d = floating.date(from: iso8601) { return d }
        return dateOnly.date(from: iso8601)
    }

    /// An invite time: a local-channel ICS keeps the sender's `TZID`, so `start`/`end`
    /// are a bare wall clock read in `zone` (core ics.rs), not in the device's zone.
    static func parse(_ iso8601: String, zone: String?) -> Date? {
        guard let zone, let tz = TimeZone(identifier: zone),
              iso.date(from: iso8601) == nil else { return parse(iso8601) }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: iso8601) ?? parse(iso8601)
    }
}
