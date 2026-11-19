import Foundation

/// Lore — the open-workload view (docs/plans/lore.md). The same rules as the web's
/// `ui/web/src/lib/lore.js` (and Android's `Lore.kt`): a Lore item IS a thread, open
/// = still in the inbox with a Lore label, done = archived. Pure, so it stays in step.
enum LoreBucket: String {
    case reply, work, pay, meet, review, read, waiting, handled

    /// Short tag text (rows, Next-up card).
    var tag: String {
        switch self {
        case .pay: return "Pay"
        case .reply: return "Reply"
        case .work: return "Work"
        case .meet: return "Meet"
        case .review: return "Review"
        case .read: return "Read"
        case .waiting: return "Waiting"
        case .handled: return "Handled"
        }
    }

    /// Built-in Jev label → bucket. `resolved` (and untriaged) has none; a custom
    /// label is work unless mapped here.
    static func forLabel(_ label: String?) -> LoreBucket? {
        guard let label, !label.isEmpty, label != TriageLabel.resolved.rawValue else { return nil }
        switch TriageLabel(rawValue: label) {
        case .needsAnswer: return .reply
        case .needsApproval, .actionRequired: return .work
        case .paymentDue: return .pay
        case .scheduling: return .meet
        case .toReview: return .review
        case .readLater: return .read
        case .waitingReply, .needsAnswerOther: return .waiting
        case .fyi, .receipt, .notification: return .handled
        case .resolved: return nil
        case nil: return .work
        }
    }

    /// Buckets "Do first" is drawn from — the ones that need the person.
    var isAction: Bool { [.pay, .reply, .work, .meet].contains(self) }
}

/// One Today section, in page order, with the copy it carries.
struct LoreSection: Identifiable {
    let bucket: LoreBucket
    let title: String
    let rule: String
    var items: [Conversation] = []
    var groups: [LoreGroup] = []
    var id: String { bucket.rawValue }

    static let order: [LoreSection] = [
        .init(bucket: .pay, title: "To pay", rule: "Invoices and reminders not paid automatically"),
        .init(bucket: .reply, title: "To reply", rule: "A question is waiting on you"),
        .init(bucket: .work, title: "Work & requests", rule: "Something you have to do or approve"),
        .init(bucket: .meet, title: "Meetings", rule: "Someone wants your time"),
        .init(bucket: .review, title: "To review", rule: "Data to look over, not act on"),
        .init(bucket: .read, title: "Read later", rule: "Kept and summarised, not urgent"),
        .init(bucket: .waiting, title: "Waiting on others", rule: "You asked; no answer yet"),
    ]
}

/// A "Handled for you" group — suggest-only (decided 2026-10-20): nothing moves
/// until the person presses its button.
struct LoreHandledGroup: Identifiable {
    let label: TriageLabel
    let title: String
    let button: String
    let action: ConversationAction
    var items: [Conversation] = []
    var id: String { label.rawValue }

    /// Shared-domain mail only hides for you, so the button says so.
    var buttonLabel: String { !items.isEmpty && items.allSatisfy(\.isMemberDone) ? "Hide" : button }

    static let order: [LoreHandledGroup] = [
        .init(label: .fyi, title: "FYI threads", button: "Archive", action: .archive),
        .init(label: .receipt, title: "Receipts and confirmations", button: "Archive", action: .archive),
        .init(label: .notification, title: "Sign-in codes and system alerts", button: "Delete", action: .trash),
    ]
}

/// Threads about the same request from one counterpart, as one row (web `groupItems`):
/// an invoice and its reminder. Ticking it archives every one; the lead is the most urgent.
struct LoreGroup: Identifiable {
    var items: [Conversation]
    var lead: Conversation { items[0] }
    var id: String { "g:\(lead.id)" }
}

/// Subject cleaning and "same request" — the web's `cleanSubject` / `related()`.
enum LoreText {
    private static let replyPrefix = try! NSRegularExpression(
        pattern: #"^(?:\s*(?:re|fw|fwd|aw|wg|antw|tr)\s*(?:\[\d+\])?\s*:\s*)+"#, options: .caseInsensitive)
    private static let reminder = try! NSRegularExpression(
        pattern: #"^\s*(?:\d+(?:e|nd|rd|th)?\s+)?(?:herinnering|reminder|aanmaning|betalingsherinnering|erinnerung|rappel)\b\s*[:\-–]?\s*"#,
        options: .caseInsensitive)
    private static let noise = try! NSRegularExpression(
        pattern: #"^\s*(?:\[?action required\]?|actie vereist)\s*[:\-–]\s*"#, options: .caseInsensitive)

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// "RE: Herinnering: Privium factuur" → "Privium factuur".
    static func clean(_ subject: String) -> String {
        var t = strip(replyPrefix, subject)
        t = strip(noise, strip(reminder, t))
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? "" : t.prefix(1).uppercased() + t.dropFirst()
    }

    static func isReminder(_ subject: String) -> Bool { matches(reminder, strip(replyPrefix, subject)) }

    private static let filler: Set<String> = ["uw", "your", "the", "de", "het", "een", "van", "voor", "for", "and", "en", "from"]
    private static func isYear(_ w: String) -> Bool { w.count == 4 && (w.hasPrefix("19") || w.hasPrefix("20")) && Int(w) != nil }

    /// Reference numbers (4+ digits, not years) in the subject or summary.
    static func refs(_ c: Conversation) -> Set<String> {
        let text = "\(c.subject) \(c.preview)"
        var out = Set<String>(), run = ""
        for ch in text + " " {
            if ch.isASCII && ch.isNumber { run.append(ch); continue }
            if run.count >= 4 && !isYear(run) { out.insert(run) }
            run = ""
        }
        return out
    }

    static func words(_ subject: String) -> Set<String> {
        Set(clean(subject).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !filler.contains($0) && !isYear($0) })
    }

    /// A shared reference, or a reminder carrying most of the other's subject words.
    /// The same subject alone isn't enough: two "Invoice" mails are usually two invoices.
    static func related(_ a: Conversation, _ b: Conversation) -> Bool {
        if !refs(a).isDisjoint(with: refs(b)) { return true }
        guard isReminder(a.subject) || isReminder(b.subject) else { return false }
        let wa = words(a.subject), wb = words(b.subject)
        let small = wa.count <= wb.count ? wa : wb, big = small == wa ? wb : wa
        guard !small.isEmpty else { return false }
        return Double(small.intersection(big).count) / Double(small.count) >= 0.6
    }

    /// 0 (under 2 days) … 4 (two months+): the row's category bar fades with it.
    static func ageStep(_ c: Conversation, now: Date = Date()) -> Int {
        guard let at = RelativeTime.parse(c.updatedAt) else { return 4 }
        let days = now.timeIntervalSince(at) / 86400
        return days < 2 ? 0 : days < 7 ? 1 : days < 28 ? 2 : days < 56 ? 3 : 4
    }
}

struct LoreToday {
    static let doFirstCount = 3

    var first: [Conversation] = []
    var sections: [LoreSection] = []
    var handled: [LoreHandledGroup] = []
    /// What needs the person (everything but handled).
    var open = 0

    var firstGroups: [LoreGroup] = []

    /// The top item: the Next-up card.
    var nextUp: Conversation? { first.first ?? sections.lazy.compactMap(\.items.first).first }

    /// Same bucket, same counterpart (sender domain, else address) and related.
    /// `sorted` is most urgent first, so each group's lead is its most urgent thread.
    static func group(_ sorted: [Conversation]) -> [LoreGroup] {
        var out: [LoreGroup] = []
        var byKey: [String: [Int]] = [:]
        for c in sorted {
            let who = LoreText.orgDomain(c.email) ?? c.email   // freemail senders group by address
            let key = "\(LoreBucket.forLabel(c.triageLabel)?.rawValue ?? "")|\(who.isEmpty ? c.id : who.lowercased())"
            if let i = byKey[key, default: []].first(where: { out[$0].items.contains { LoreText.related($0, c) } }) {
                out[i].items.append(c)
            } else {
                byKey[key, default: []].append(out.count)
                out.append(LoreGroup(items: [c]))
            }
        }
        return out
    }

    /// Build Today from inbox rows (open ones only — the inbox query already hides
    /// archived/trash/spam). Highest Jev priority first (untriaged last), then newest.
    static func build(_ rows: [Conversation]) -> LoreToday {
        let items = rows.filter { LoreBucket.forLabel($0.triageLabel) != nil && !$0.loreDone }
            .sorted(by: compare)
        let bucket = { (c: Conversation) in LoreBucket.forLabel(c.triageLabel)! }
        let groups = group(items.filter { bucket($0) != .handled })
        let firstGroups = Array(groups.filter { bucket($0.lead).isAction }.prefix(doFirstCount))
        let firstIds = Set(firstGroups.map(\.id))
        var t = LoreToday(first: firstGroups.map(\.lead))
        t.firstGroups = firstGroups
        t.sections = LoreSection.order.map { s in
            var s = s
            s.groups = groups.filter { bucket($0.lead) == s.bucket && !firstIds.contains($0.id) }
            s.items = s.groups.flatMap(\.items)
            return s
        }
        t.handled = LoreHandledGroup.order.map { g in
            var g = g
            g.items = items.filter { bucket($0) == .handled && $0.triageLabel == g.label.rawValue }
            return g
        }
        t.open = items.filter { bucket($0) != .handled }.count
        return t
    }

    /// "2026-10-24" → the end of that local day.
    static func dueAt(_ c: Conversation) -> Date? {
        let parts = (c.dueOn ?? "").prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 23, minute: 59, second: 59))
    }

    /// Jev priority plus a deadline bump (web `urgency`): overdue +1.5, within 3
    /// days +1, within a week +0.5. Untriaged with no deadline sorts last (-1).
    static func urgency(_ c: Conversation, now: Date = Date()) -> Double {
        let priority = c.triagePriority ?? -1
        guard let due = dueAt(c) else { return priority }
        let left = due.timeIntervalSince(now) / 86400
        return max(priority, 0) + (left < 0 ? 1.5 : left < 3 ? 1 : left < 7 ? 0.5 : 0)
    }

    static func compare(_ a: Conversation, _ b: Conversation) -> Bool {
        let pa = urgency(a), pb = urgency(b)
        if pa != pb { return pa > pb }
        return (RelativeTime.parse(a.updatedAt) ?? .distantPast) > (RelativeTime.parse(b.updatedAt) ?? .distantPast)
    }
}

/// An email-less Lore todo (`lore_todos`, core `lore_add_todo`/`lore_list_todos_json`/
/// `lore_complete_todo`): added by voice (`add_reminder`) or the "+ Add todo" row.
struct LoreTodo: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let createdAt: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, title, source
        case createdAt = "created_at"
    }
}

// MARK: - Ontology + pages (docs/Ontology.md; the same JSON from Rails `/lore/*` and the core FFI)

// LoreFact / LoreEntityRow / the response wrappers live in CloudDTOs.swift (the share
// extension compiles CloudClient, which decodes them).

/// A page in the person's C:\Lore folder (Disk), read-only on the phone.
struct LorePageRef: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let kind: String?
}

/// Who a Lore entity page is about.
enum LoreEntityRef: Hashable {
    case org(domain: String)
    case person(address: String, name: String)
}

/// A screen Lore pushes on its NavigationStack.
enum LoreRoute: Hashable {
    case entity(LoreEntityRef)
    case page(orgId: String, page: LorePageRef)
}

extension Conversation {
    /// Lore's personal buckets on a shared domain: a tick hides the thread for this
    /// member only (api `TriageLabel::PERSONAL`, web `isMemberDone`). Work items and
    /// channel mail keep done == archived.
    var isMemberDone: Bool {
        guard isDomain, let t = triage else { return false }
        return [.readLater, .fyi, .receipt, .notification].contains(t)
    }
}

extension LoreText {
    // ponytail: a short public-suffix list, not the PSL; extend when a country's mail groups wrong.
    private static let twoPartSuffixes: Set<String> = ["co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.nz", "co.za",
                                                         "com.br", "co.jp", "co.in", "com.sg", "com.tr", "co.ae", "com.mx"]

    /// Personal mail providers: a gmail.com sender is a person, not an organization (web `FREEMAIL`).
    static let freemail: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com",
        "gmx.net", "gmx.de", "mail.com", "zoho.com", "yandex.com", "hey.com", "fastmail.com"]

    /// "billing.mail.odido.nl" → "odido.nl": the organization a sender belongs to
    /// (web `orgDomain`); nil for freemail.
    static func orgDomain(_ email: String) -> String? {
        guard let domain = registrable(email) else { return nil }
        return freemail.contains(domain) ? nil : domain
    }

    private static func registrable(_ email: String) -> String? {
        guard let host = email.split(separator: "@").last?.lowercased(), host.contains(".") else { return nil }
        let parts = host.split(separator: ".")
        let two = parts.suffix(2).joined(separator: ".")
        if twoPartSuffixes.contains(two), parts.count >= 3 { return parts.suffix(3).joined(separator: ".") }
        return two
    }

    /// "odido.nl" → "Odido".
    static func domainLabel(_ domain: String) -> String {
        let first = domain.split(separator: ".").first.map(String.init) ?? domain
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Does `c` match a free-text Lore search (title, summary, sender)?
    static func matches(_ c: Conversation, _ q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [c.subject, c.preview, c.sender, c.email].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}
