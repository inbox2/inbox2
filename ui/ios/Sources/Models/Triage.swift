import Foundation

/// Live progress of the background triage + summary worker, mirrored from the
/// core's `triage-progress` event (`{inWindow, done, pending, currentDate, jevStatus}`).
/// Drives the Settings and Bridge progress bars.
struct TriageState: Equatable {
    /// Conversations inside the processing window (the denominator).
    let inWindow: Int
    /// In-window conversations already classified (the numerator).
    let done: Int
    /// Jobs still queued.
    let pending: Int
    /// Date of the newest conversation still to be classified — the worker runs
    /// newest-first, so this is "where it's at now", marching back in time. nil when done.
    let currentDate: Date?
    /// The Jev key's state: `missing` | `ok` | `unauthorized` (Jev answered 401).
    var jevStatus: String = "missing"

    static let empty = TriageState(inWindow: 0, done: 0, pending: 0)

    /// 0…1 completion fraction (1 when there's nothing to do).
    var fraction: Double {
        guard inWindow > 0 else { return 1 }
        return min(1, Double(done) / Double(inWindow))
    }

    /// Whether the worker is actively processing (drives whether the bar is
    /// shown). Based on the queue, not done<inWindow — so when the remaining
    /// threads are deferred (e.g. no AI model to judge them), the bar hides
    /// instead of showing "Working…" forever.
    var isActive: Bool { pending > 0 }

    init(inWindow: Int, done: Int, pending: Int, currentDate: Date? = nil) {
        self.inWindow = inWindow
        self.done = done
        self.pending = pending
        self.currentDate = currentDate
    }

    /// Decode from a `triage-progress` event / `triageProgress()` JSON payload.
    init?(payloadJSON: String) {
        guard
            let data = payloadJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        self.inWindow = (obj["inWindow"] as? Int) ?? 0
        self.done = (obj["done"] as? Int) ?? 0
        self.pending = (obj["pending"] as? Int) ?? 0
        self.currentDate = (obj["currentDate"] as? String).flatMap(Self.parseDate)
        self.jevStatus = (obj["jevStatus"] as? String) ?? "missing"
    }

    /// Parse the core's RFC3339 priority, with or without fractional seconds.
    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// How far back mail is classified / summarized. Raw values match the core
/// `ProcessingWindow` (`engine_settings.processing_window`).
enum ProcessingWindow: String, CaseIterable, Identifiable {
    case lastMonth = "1_month"
    case threeMonths = "3_months"
    case sixMonths = "6_months"
    case oneYear = "1_year"
    case everything = "everything"

    static let `default`: ProcessingWindow = .lastMonth

    var id: String { rawValue }

    /// Short label for the slider/segmented control.
    var shortLabel: String {
        switch self {
        case .lastMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .everything: return "All"
        }
    }

    /// Full label for the selected-value row.
    var label: String {
        switch self {
        case .lastMonth: return "Last month"
        case .threeMonths: return "Last 3 months"
        case .sixMonths: return "Last 6 months"
        case .oneYear: return "Last year"
        case .everything: return "Everything"
        }
    }
}

/// The triage classification of a conversation. Raw values match the core
/// `TriageLabel`. Used to render the inbox badge.
enum TriageLabel: String, CaseIterable, Identifiable {
    case needsAnswer = "needs_answer"
    case needsAnswerOther = "needs_answer_other"
    case waitingReply = "waiting_reply"
    case needsApproval = "needs_approval"
    case scheduling = "scheduling"
    case actionRequired = "action_required"
    case fyi = "fyi"
    case resolved = "resolved"
    case paymentDue = "payment_due"
    case toReview = "to_review"
    case readLater = "read_later"
    case receipt = "receipt"
    case notification = "notification"

    var id: String { rawValue }

    /// Short badge text.
    var label: String {
        switch self {
        case .needsAnswer: return "Needs answer"
        case .needsAnswerOther: return "Reply from someone else"
        case .waitingReply: return "Waiting for reply"
        case .needsApproval: return "Needs approval"
        case .scheduling: return "Scheduling"
        case .actionRequired: return "Action required"
        case .fyi: return "FYI"
        case .resolved: return "Resolved"
        case .paymentDue: return "To pay"
        case .toReview: return "To review"
        case .readLater: return "Read later"
        case .receipt: return "Receipt"
        case .notification: return "Notification"
        }
    }

    /// Compact label for the inbox row chip, or nil for low-signal categories
    /// (FYI / resolved / receipt / notification) so the list stays clean.
    var rowBadge: String? {
        switch self {
        case .needsAnswer: return "Reply"
        case .needsAnswerOther: return "Others"
        case .waitingReply: return "Waiting"
        case .needsApproval: return "Approve"
        case .scheduling: return "Schedule"
        case .actionRequired: return "Action"
        case .paymentDue: return "Pay"
        case .toReview: return "Review"
        case .readLater: return "Read"
        case .fyi, .resolved, .receipt, .notification: return nil
        }
    }

    /// SF Symbol for the badge.
    var symbol: String {
        switch self {
        case .needsAnswer: return "arrowshape.turn.up.left.fill"
        case .needsAnswerOther: return "person.2.fill"
        case .waitingReply: return "hourglass"
        case .needsApproval: return "checkmark.seal.fill"
        case .scheduling: return "calendar"
        case .actionRequired: return "exclamationmark.circle.fill"
        case .fyi: return "info.circle"
        case .resolved: return "checkmark.circle.fill"
        case .paymentDue: return "creditcard.fill"
        case .toReview: return "doc.text.magnifyingglass"
        case .readLater: return "book.fill"
        case .receipt: return "receipt"
        case .notification: return "bell.fill"
        }
    }
}

/// One triage label (built-in or custom), in the core's wire shape — the engine's
/// `triage_labels` setting (`get_triage_labels`/`set_triage_labels`) and the MX
/// `GET /orgs/:id/triage-labels` rows (whose extra `id`/`position` are ignored).
struct TriageLabelDef: Codable, Identifiable, Hashable {
    var slug: String
    var name: String
    var description: String
    var notFor: String
    var color: String?
    var builtin: Bool
    var enabled: Bool

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, name, description, color, builtin, enabled
        case notFor = "not_for"
    }

    init(slug: String, name: String, description: String, notFor: String = "",
         color: String? = nil, builtin: Bool = false, enabled: Bool = true) {
        self.slug = slug; self.name = name; self.description = description
        self.notFor = notFor; self.color = color; self.builtin = builtin; self.enabled = enabled
    }

    /// Lenient: the API sends nulls where the core sends "".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        notFor = try c.decodeIfPresent(String.self, forKey: .notFor) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Custom slug rule (docs/Triage.md): `[a-z0-9_]{1,40}`, not a built-in, not `no_match`.
    static func isValidCustomSlug(_ s: String) -> Bool {
        (1...40).contains(s.count)
            && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
            && TriageLabel(rawValue: s) == nil && s != "no_match"
    }
}

/// Display names for label slugs that aren't built-ins: the local list (channel
/// rows, filled by `EngineModel`) and each org's list (MX rows, filled by
/// `CloudSession`). Unknown → the slug, title-cased.
@MainActor
enum TriageLabelNames {
    static var local: [String: String] = [:]
    static var byOrg: [String: [String: String]] = [:]

    static func name(for slug: String, orgId: String?) -> String {
        let known = orgId.flatMap { byOrg[$0]?[slug] } ?? (orgId == nil ? local[slug] : nil)
        return known ?? slug.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}

/// Jev's 0–4 attention score → the row chip (docs/Triage.md "Priority levels"):
/// ≥ 3.5 Urgent, ≥ 2.5 High, below that nothing.
enum TriagePriority {
    static func chip(_ score: Double?) -> String? {
        guard let score else { return nil }
        if score >= 3.5 { return "Urgent" }
        if score >= 2.5 { return "High" }
        return nil
    }
}

/// On-device intent classification kinds (the rules engine's intent vocabulary),
/// normalized from the stored label. Single source for the badge label + glyph,
/// so the model layer and the badge UI can't drift apart.
enum IntentKind: String {
    case question, request, complaint, scheduling, fyi

    /// Normalize a stored intent label; nil = unclassified / junk ("<intent>", "other").
    static func from(_ raw: String?) -> IntentKind? {
        guard let raw = raw?.lowercased(), !raw.isEmpty, raw != "<intent>", raw != "other" else { return nil }
        return IntentKind(rawValue: raw) ?? .fyi
    }

    var label: String {
        switch self {
        case .question: return "Question"
        case .request: return "Request"
        case .complaint: return "Complaint"
        case .scheduling: return "Scheduling"
        case .fyi: return "FYI"
        }
    }

    var systemImage: String {
        switch self {
        case .question: return "questionmark.circle"
        case .request: return "tray.and.arrow.down"
        case .complaint: return "exclamationmark.bubble"
        case .scheduling: return "calendar"
        case .fyi: return "info.circle"
        }
    }
}
