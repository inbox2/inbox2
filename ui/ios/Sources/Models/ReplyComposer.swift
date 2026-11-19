import Foundation

/// Shared construction helpers for reply/forward drafts + snooze timing, so the
/// reader (`MessageView`) and the inbox-list swipe/menu (`InboxListView`) build
/// identical subjects, quoted bodies, and forward headers instead of drifting
/// apart. Pure functions over `Conversation`/`Message`; the views assemble the
/// `ComposeDraft` from these pieces.
enum ReplyComposer {
    /// The forward separator line, shared so both entry points match verbatim.
    static let forwardSeparator = "---------- Forwarded message ----------"

    /// Add `Re:`/`Fwd:` once — never double-prefix an already-prefixed subject.
    static func subjectPrefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    /// Quote each line with a leading `> ` (RFC 3676-style), preserving blank lines.
    static func quoteLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
    }

    /// A reply/forward quote with the `On <time>, <sender> <email> wrote:`
    /// attribution. Falls back to the conversation snippet when the message has no
    /// plain body. Returns "" for a nil message.
    static func attributedQuote(_ m: Message?, fallbackSnippet: String) -> String {
        guard let m else { return "" }
        let body = (m.bodyPlain ?? "").isEmpty ? fallbackSnippet : (m.bodyPlain ?? "")
        return "On \(m.time), \(m.sender) <\(m.email)> wrote:\n\(quoteLines(body))"
    }

    /// The forward body: leading blank lines, the separator, then the quoted original.
    static func forwardBody(quote: String) -> String {
        "\n\n\(forwardSeparator)\n\(quote)"
    }

    /// Reply-all recipients, keeping the original To/Cc structure: To = the sender +
    /// the original To line, Cc = the original Cc line — each minus the replier's own
    /// address, de-duplicated by email (case-insensitive; an address already on To is
    /// dropped from Cc), re-rendered as address lists. Mirrors the web client's
    /// `replyAllRecipients` so all three platforms strip self identically — a raw
    /// header string can't drop self out of a multi-recipient To/Cc line. Both empty
    /// if the replier was the only party.
    static func replyAllRecipients(_ m: Message?, selfEmail: String?) -> (to: String, cc: String) {
        guard let m else { return ("", "") }
        var seen = ownAddresses(m, selfEmail: selfEmail)
        func render(_ addrs: [(name: String, email: String)]) -> String {
            var out: [String] = []
            for a in addrs {
                let key = a.email.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(a.name == a.email ? a.email : MailAddress.format(a.name, a.email))
            }
            return out.joined(separator: ", ")
        }
        let to = render(MailAddress.parseList(m.fromAddress) + MailAddress.parseList(m.toAddress))
        let cc = render(MailAddress.parseList(m.ccAddress ?? ""))
        return (to, cc)
    }

    /// The replier's addresses on `m`: `selfEmail`, plus — when it appears nowhere on
    /// the message and exactly one To/Cc address is on its domain — that address (the
    /// alias the mail arrived through, like info@). Two or more are ambiguous (one may
    /// be a colleague): none dropped. Never the sender. Mirrors web `ownAddresses`.
    /// ponytail: heuristic, no Gmail send-as list; fetch send-as identities if it misfires.
    static func ownAddresses(_ m: Message, selfEmail: String?) -> Set<String> {
        let me = (selfEmail ?? "").lowercased()
        var own: Set<String> = [me]
        let rcpts = (MailAddress.parseList(m.toAddress) + MailAddress.parseList(m.ccAddress ?? ""))
            .map { $0.email.lowercased() }
        let from = MailAddress.parseList(m.fromAddress).map { $0.email.lowercased() }
        guard let at = me.firstIndex(of: "@"), !rcpts.contains(me), !from.contains(me) else { return own }
        let mine = Set(rcpts.filter { $0.hasSuffix(me[at...]) })
        if mine.count == 1, let alias = mine.first { own.insert(alias) }
        return own
    }

    /// The user's own addresses (lowercased) a domain thread can send from:
    /// `username@` each domain of the thread's org (all orgs if it can't be told).
    /// Never a connected Gmail/Microsoft address — the send goes through inbox2,
    /// which can't sign for it.
    @MainActor
    static func domainEmails(for convo: Conversation, cloud: CloudSession) -> Set<String> {
        var out = Set<String>()
        if let u = cloud.user?.username {
            let mine = cloud.orgs.filter { $0.id == convo.accountKey || ($0.domains ?? []).contains { $0.id == convo.accountKey } }
            for org in (mine.isEmpty ? cloud.orgs : mine) {
                // The server's send-as list when present (a rules-only member has
                // no username@ address); older payloads → username@ each domain.
                if let list = org.fromAddresses {
                    for a in list { out.insert(a.lowercased()) }
                    continue
                }
                let names = (org.domains ?? []).map(\.name) + [org.domain].compactMap { $0 }
                for d in names where !d.isEmpty { out.insert("\(u)@\(d)".lowercased()) }
            }
        }
        return out
    }

    /// Which own address a reply to `m` comes from: the one it was sent from when
    /// it's your own mail, else the one it was sent to (To/Cc). Mirrors the web
    /// client's `replyFromAddress`. nil when none of `own` is on the message.
    static func replyFrom(_ m: Message?, own: Set<String>) -> String? {
        guard let m else { return nil }
        let all = MailAddress.parseList(m.fromAddress)
            + MailAddress.parseList(m.toAddress)
            + MailAddress.parseList(m.ccAddress ?? "")
        return all.first { own.contains($0.email.lowercased()) }?.email
    }

    /// The send-from address override for a domain (MX) conversation — the own
    /// address on the latest message, else the address the thread arrived at; nil
    /// for offline channels (which send from the account itself).
    static func fromEmailOverride(for convo: Conversation, latest: Message? = nil, own: Set<String> = []) -> String? {
        guard convo.isDomain else { return nil }
        return replyFrom(latest, own: own) ?? MailAddress.parse(convo.toAddress).email
    }

    /// Plain-reply recipient: the sender — or, replying to your own message, the
    /// people you sent it to (never yourself).
    static func replyTo(_ m: Message?, from: String?, fallback: String) -> String {
        guard let m else { return fallback }
        if let from, m.email.lowercased() == from.lowercased() { return m.toAddress }
        return m.email
    }

    /// Snooze target: `hours` from now. Shared by the reader and the list so both
    /// "snooze N hours" entry points compute the same instant.
    static func snoozeDate(hoursFromNow hours: Int, now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: now) ?? now
    }

    /// A ready "Fwd:" draft of the conversation's latest message — fetches it
    /// (cloud thread for domain, else the engine store) and maps its attachments
    /// to *pending* placeholders (metadata only; ComposeView downloads the bytes
    /// in-screen and blocks Send until done). Shared by the reader's Forward and
    /// the inbox row menu's.
    @MainActor
    static func forwardDraft(for convo: Conversation, engine: EngineModel, cloud: CloudSession) async -> ComposeDraft {
        var atts: [ComposeDraft.Attachment] = []
        let last: Message?
        if convo.isDomain {
            last = await cloud.thread(conversationId: convo.id).messages.last
        } else {
            last = await engine.store.read { $0.messages(conversationKey: convo.id).last }
            if let last {
                let meta = await engine.fetchMessage(accountKey: convo.accountKey, messageKey: last.id).attachments
                atts = meta.map {
                    .pending(filename: $0.filename, mimeType: $0.mimeType,
                             download: .init(accountKey: convo.accountKey, messageKey: last.id, attachmentId: $0.attachmentId))
                }
            }
        }
        return ComposeDraft(
            fromAccountKey: convo.accountKey,
            fromEmailOverride: fromEmailOverride(for: convo, latest: last, own: domainEmails(for: convo, cloud: cloud)),
            subject: subjectPrefixed("Fwd:", convo.subject),
            body: forwardBody(quote: attributedQuote(last, fallbackSnippet: convo.snippet)),
            attachments: atts
        )
    }
}
