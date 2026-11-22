import Foundation

// Pure Codable DTOs + error type for the inbox2-domain ("MX") REST API, plus the
// outgoing-attachment value type. Extracted from CloudModels.swift so this file (and
// CloudClient) can compile in the Share Extension target, which must NOT link the Rust
// core / engine. Nothing here references EngineModel, Conversation, Message, or any
// app-only view model — keep it that way. The engine-coupled `Conversation`/`Message`
// bridging extensions stay in CloudModels.swift (app target only). (`CloudError` lives in
// CloudClient.swift, which is also compiled into the extension target.)

/// A file to attach to a domain send (uploaded via the draft flow). Also used by the
/// share extension's queued sends.
struct OutgoingAttachment {
    let filename: String
    let mimeType: String
    let data: Data
}

/// The signed-in inbox2 user (the `account` object).
struct CloudUser: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String?
    let billingEmail: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case billingEmail = "billing_email"
    }

    /// Best display label: display name, else username.
    var label: String { (displayName?.isEmpty == false ? displayName : nil) ?? username }
}

/// A first-class domain within an org's MX pool. An org owns many equal domains;
/// each becomes its own workspace chip in the inbox rail (parity with the web
/// per-domain tabs). `id` is the domain's `dom_…` public key — used as the
/// `?domain=` list filter.
struct CloudDomain: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let slug: String?
    let status: String?
    let iconUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, status
        case iconUrl = "icon_url"
    }
}

/// An organization (an MX domain) the user belongs to.
struct CloudOrg: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let slug: String?
    let domain: String?
    let iconUrl: String?
    /// All first-class domains in the org (empty/absent for legacy single-domain
    /// payloads → the rail falls back to one org-keyed chip).
    let domains: [CloudDomain]?
    /// Every address you may send as in this org (username@ each pool domain,
    /// your mailboxes, admin-granted info@/sales@). nil on older payloads.
    let fromAddresses: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, domain, domains
        case iconUrl = "icon_url"
        case fromAddresses = "from_addresses"
    }
}

/// `POST /auth/login` — either a token + user, or a 2FA challenge.
struct CloudLoginResponse: Codable {
    let user: CloudUser?
    let token: String?
    let requiresTwoFactor: Bool?
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case user, token
        case requiresTwoFactor = "requires_2fa"
        case userId = "user_id"
    }
}

/// `GET /account` — the current user, their orgs, and the active org.
struct CloudAccountResponse: Codable {
    let account: CloudUser
    let organizations: [CloudOrg]
    let currentOrgId: String?

    enum CodingKeys: String, CodingKey {
        case account, organizations
        case currentOrgId = "current_org_id"
    }
}

/// A conversation in an org's unified pool (list item). Phase-2 mail layer reads these.
struct CloudConversation: Codable, Identifiable, Hashable {
    let id: String
    let subject: String?
    let status: String
    let snippet: String?
    let read: Bool
    let fromAddress: String?
    let toAddress: String?
    let createdAt: String?
    let updatedAt: String?
    let messageCount: Int?
    /// Generated one-line preview; null until the classifier has run (or when AI
    /// triage is off for the org), in which case the row shows `snippet`.
    let aiSummaryShort: String?
    /// Jev's action label (built-in or custom org slug) and 0–4 attention score;
    /// null until triaged (docs/Triage.md).
    let triageLabel: String?
    let triagePriority: Double?
    let nextActionDueOn: String?
    /// Per viewer: this member ticked the thread off in Lore (docs/TODO.md 48.11).
    let loreDone: Bool?

    enum CodingKeys: String, CodingKey {
        case id, subject, status, snippet, read
        case loreDone = "lore_done"
        case triageLabel = "triage_label"
        case triagePriority = "triage_priority"
        case nextActionDueOn = "next_action_due_on"
        case fromAddress = "from_address"
        case toAddress = "to_address"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case aiSummaryShort = "ai_summary_short"
    }
}

struct CloudConversationsResponse: Codable {
    let conversations: [CloudConversation]
}

/// Open-pool unread count for the app-icon badge (the domain/MX half).
struct CloudUnreadCountResponse: Codable {
    let unreadCount: Int
    enum CodingKeys: String, CodingKey { case unreadCount = "unread_count" }
}

/// A conversation tag: the team's, or one of the viewer's own private labels
/// (`isPrivate`; only they see it — docs/plans/mail-import.md D11).
struct CloudTag: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let isPrivate: Bool?

    enum CodingKeys: String, CodingKey { case id, name, color, isPrivate = "private" }
}

struct CloudTagsResponse: Codable { let tags: [CloudTag] }
struct CloudTagResponse: Codable { let tag: CloudTag }

/// A person on a membership (the user behind an assignee/note author).
struct CloudPerson: Codable, Hashable {
    let id: String?
    let username: String?
    let email: String?
    let name: String?
    var label: String {
        [name, username, email].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "?"
    }
}

/// An org membership (assignee). `user` carries the display identity.
struct CloudMember: Codable, Identifiable, Hashable {
    let id: String
    let role: String?
    let user: CloudPerson?
}

struct CloudMembersResponse: Codable { let members: [CloudMember] }
struct CloudAssigneesResponse: Codable { let assignees: [CloudMember] }

/// An internal note on a domain conversation.
struct CloudNote: Codable, Identifiable, Hashable {
    let id: String
    let body: String
    let createdAt: String?
    let author: CloudMember?

    enum CodingKeys: String, CodingKey { case id, body, author; case createdAt = "created_at" }
}

struct CloudNoteResponse: Codable { let note: CloudNote }

/// `GET /conversations/:id` — the conversation plus its full message thread + tags.
struct CloudConversationDetail: Codable {
    let id: String
    let subject: String?
    let status: String
    let snippet: String?
    let read: Bool
    let fromAddress: String?
    let toAddress: String?
    let createdAt: String?
    let updatedAt: String?
    let messages: [CloudMessage]
    let tags: [CloudTag]?
    let assignees: [CloudMember]?
    let notes: [CloudNote]?

    enum CodingKeys: String, CodingKey {
        case id, subject, status, snippet, read, messages, tags, assignees, notes
        case fromAddress = "from_address"
        case toAddress = "to_address"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CloudConversationDetailResponse: Codable {
    let conversation: CloudConversationDetail
}

/// A view (system or personal) over the org pool — drives the domain folder list.
struct CloudView: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let icon: String?

    enum CodingKeys: String, CodingKey { case id, name, kind, icon }
}

struct CloudViewsResponse: Codable {
    let views: [CloudView]
}

struct CloudMessageResponse: Codable {
    let message: CloudMessage
}

/// A parsed meeting invite (ICS `VEVENT`) surfaced on a message so the reader can show
/// an Accept/Tentative/Decline banner (docs/Open-Tracking.md sibling — meeting invites).
/// Two sources, one shape: MX messages carry it pre-parsed from the API (`rsvp_status`);
/// local-channel (Gmail/IMAP) messages resolve it from the Rust core via their
/// text/calendar attachment (`current_status` + `attachment_id`). Pure Codable — lives
/// here so both the app and the Share-Extension target (which links no core) can see it.
struct ClientInvite: Codable, Hashable {
    let method: String?
    let uid: String?
    let summary: String?
    let location: String?
    let start: String?
    let end: String?
    /// The IANA zone `start`/`end` are in. Only set when the ICS said so (`TZID`, or
    /// `UTC` for a `Z` time) — a floating time has none, by RFC 5545.
    let timezone: String?
    let allDay: Bool?
    let organizerEmail: String?
    let organizerName: String?
    /// Local-channel invite: the RSVP recorded in the core ("needs_action"/…).
    let currentStatus: String?
    /// MX invite: the RSVP status from the API.
    let rsvpStatus: String?
    /// Local-channel invite: the calendar attachment to RSVP against (nil for MX).
    let attachmentId: String?
    /// Local-channel invite: the synced calendar event this maps to, if any — lets
    /// the banner open the calendar straight to its detail (nil for MX / unmatched).
    let matchedEventKey: String?
    /// No ICS at all: triage read the meeting out of the body (docs/Meeting-Invites.md
    /// "Detected meetings"). Always a PUBLISH, so it only offers "Add to calendar".
    let detected: Bool?

    enum CodingKeys: String, CodingKey {
        case method, uid, summary, location, start, end, timezone
        case allDay = "all_day"
        case organizerEmail = "organizer_email"
        case organizerName = "organizer_name"
        case currentStatus = "current_status"
        case rsvpStatus = "rsvp_status"
        case attachmentId = "attachment_id"
        case matchedEventKey = "matched_event_key"
        case detected
    }

    /// An invitation you can actually answer. A stated METHOD other than REQUEST
    /// (PUBLISH confirmations, bookings, tickets) is never answerable. Past that, an
    /// MX invite is a REQUEST by construction, while a local-channel one also has to
    /// name an organizer — an RSVP with nobody to send it to isn't worth offering.
    /// Kept in step with the web `isRequest` and Android's.
    var isRequest: Bool {
        if let method, method != "REQUEST" { return false }
        guard attachmentId != nil else { return true }   // MX
        return organizerEmail?.isEmpty == false
    }

    /// The other half of the banner: a `text/calendar` that isn't asking for an answer
    /// — an appointment confirmation, a booking, a ticket — so the useful action is
    /// putting it on your calendar.
    var isAddable: Bool { !isRequest }
    var isAllDay: Bool { allDay == true }
    var isDetected: Bool { detected == true }

    /// The recorded RSVP, or nil when unanswered ("needs_action") — a real status
    /// preselects the matching button.
    var answeredStatus: String? {
        let s = currentStatus ?? rsvpStatus
        return (s == nil || s == "needs_action") ? nil : s
    }
    // `whenLabel` (formats start/end) lives in CloudModels.swift — it uses the
    // app-target `RelativeTime`, which the Share-Extension target doesn't compile.
}

/// A meet-link booking request (docs/Calendar.md) — nothing is on the calendar yet;
/// the invitee accepts (creates the event + mails an ICS invite) or declines. Mirrors
/// the API `MeetingRequest#banner_payload`.
struct ClientMeetingRequest: Codable, Hashable {
    let key: String
    let name: String?
    let note: String?
    let start: String?
    let end: String?
    let visitorTimezone: String?
    let conferenceMode: String?
    let inviteeName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case key, name, note, start, end, status
        case visitorTimezone = "visitor_timezone"
        case conferenceMode = "conference_mode"
        case inviteeName = "invitee_name"
    }
}

/// A single message in a domain conversation thread.
struct CloudMessage: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String?
    let fromAddress: String?
    let toAddress: String?
    let ccAddress: String?
    let subject: String?
    let bodyPlain: String?
    let bodyHtml: String?
    let isInbound: Bool
    let isDraft: Bool
    let createdAt: String?
    let encryptionScheme: String?
    /// Pre-parsed meeting invite (MX only — the API `MessageSerializer` emits it).
    let invite: ClientInvite?
    /// Meet-link booking request (MX only).
    let meetingRequest: ClientMeetingRequest?

    enum CodingKeys: String, CodingKey {
        case id, subject, invite
        case meetingRequest = "meeting_request"
        case conversationId = "conversation_id"
        case fromAddress = "from_address"
        case toAddress = "to_address"
        case ccAddress = "cc_address"
        case bodyPlain = "body_plain"
        case bodyHtml = "body_html"
        case isInbound = "is_inbound"
        case isDraft = "is_draft"
        case createdAt = "created_at"
        case encryptionScheme = "encryption_scheme"
    }

    /// Sealed, and nothing has opened it for this reader yet.
    var isLocked: Bool { (encryptionScheme ?? "none") != "none" && bodyPlain == nil && bodyHtml == nil }
}

struct CloudDraftsResponse: Codable { let drafts: [CloudMessage] }
struct CloudDraftResponse: Codable { let draft: CloudMessage }

/// `POST /attachments` — the uploaded attachment (we only need its key to reference
/// it from the send).
struct CloudAttachment: Codable, Hashable {
    let id: String
    let key: String?
    var ref: String { key ?? id }
}
struct CloudAttachmentResponse: Codable { let attachment: CloudAttachment }

// Cloud-synced per-channel open-tracking config (docs/Open-Tracking.md).
struct CloudChannelTracking: Codable {
    let emailAddress: String
    let openTrackingEnabled: Bool
    let trackDomain: String?
    enum CodingKeys: String, CodingKey {
        case emailAddress = "email_address"
        case openTrackingEnabled = "open_tracking_enabled"
        case trackDomain = "track_domain"
    }
}
struct CloudChannelTrackingList: Codable { let channels: [CloudChannelTracking] }

// Calendar zones (docs/iOS-App.md "Zones"): the user's own soft focus blocks. User-
// scoped, never marks anyone busy. `color` is always a palette key (blue/amber/violet/
// green/rose/teal) the client maps per theme — never a hex.
struct CloudZoneCategory: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String
    let position: Int?
}
struct CloudZoneCategoryResponse: Codable {
    let zoneCategory: CloudZoneCategory
    enum CodingKeys: String, CodingKey { case zoneCategory = "zone_category" }
}
struct CloudZoneCategoriesResponse: Codable {
    let zoneCategories: [CloudZoneCategory]
    enum CodingKeys: String, CodingKey { case zoneCategories = "zone_categories" }
}

/// The list returns OCCURRENCES: a repeating zone appears once per day it runs,
/// with `id` = "zon_x@20260925T140000Z". `id` is the identity everywhere (cache,
/// dismissals, notification ids — each day alerts on its own); `seriesId` groups
/// the occurrences of one zone. PATCH/DELETE accept either.
struct CloudZone: Decodable, Identifiable, Hashable {
    static let repeatNone = "none", repeatDaily = "daily", repeatWeekdays = "weekdays", repeatWeekly = "weekly"

    let id: String
    let seriesId: String
    let name: String
    let note: String?
    /// `var` so deleting a category can uncategorise cached zones locally.
    var categoryId: String?
    let start: Date
    let end: Date
    let notify: Bool
    let repeatRule: String
    /// "YYYY-MM-DD" (the zone's own time zone), nil = forever.
    let repeatUntil: String?
    let timeZone: String?
    /// A prep zone follows this calendar event: it ends at the event's start and
    /// begins `anchorMinutes` before (`ZoneStore.reconcileAnchors`).
    let anchorEventId: String?
    let anchorMinutes: Int?
    /// This occurrence's card was clicked away on some device (server-side
    /// `zone_dismissals`); `ZoneStore.load` merges it into the local dismissed map.
    let dismissed: Bool

    var isRepeating: Bool { repeatRule != Self.repeatNone }

    enum CodingKeys: String, CodingKey {
        case id, name, note, notify, dismissed
        case seriesId = "series_id"
        case categoryId = "category_id"
        case startAt = "start_at"
        case endAt = "end_at"
        case repeatRule = "repeat"
        case repeatUntil = "repeat_until"
        case timeZone = "time_zone"
        case anchorEventId = "anchor_event_id"
        case anchorMinutes = "anchor_minutes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        categoryId = try c.decodeIfPresent(String.self, forKey: .categoryId)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
            ?? String(id.split(separator: "@").first ?? Substring(id))
        repeatRule = try c.decodeIfPresent(String.self, forKey: .repeatRule) ?? Self.repeatNone
        repeatUntil = try c.decodeIfPresent(String.self, forKey: .repeatUntil)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        anchorEventId = try c.decodeIfPresent(String.self, forKey: .anchorEventId)
        anchorMinutes = try c.decodeIfPresent(Int.self, forKey: .anchorMinutes)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        func date(_ key: CodingKeys) throws -> Date {
            let raw = try c.decode(String.self, forKey: key)
            guard let d = Self.isoFrac.date(from: raw) ?? Self.iso.date(from: raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "bad date \(raw)")
            }
            return d
        }
        start = try date(.startAt)
        end = try date(.endAt)
    }

    /// Rails emits milliseconds ("…T16:00:00.000Z"); accept the plain form too.
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    func isActive(at now: Date) -> Bool { start <= now && now < end }
}
struct CloudZonesResponse: Decodable { let zones: [CloudZone] }
struct CloudZoneResponse: Decodable { let zone: CloudZone }

/// A "not available" window (`blk_`, `/orgs/:id/blocked-times`) — busy in every
/// free/busy read but not a calendar event; only its owner sees it.
struct CloudBlockedTime: Decodable, Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date

    enum CodingKeys: String, CodingKey { case id, startAt = "start_at", endAt = "end_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        func date(_ key: CodingKeys) throws -> Date {
            let raw = try c.decode(String.self, forKey: key)
            guard let d = Self.isoFrac.date(from: raw) ?? Self.iso.date(from: raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "bad date \(raw)")
            }
            return d
        }
        start = try date(.startAt)
        end = try date(.endAt)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
}

struct CloudBlockedTimesResponse: Decodable {
    let blockedTimes: [CloudBlockedTime]
    enum CodingKeys: String, CodingKey { case blockedTimes = "blocked_times" }
}

struct CloudBlockedTimeResponse: Decodable {
    let blockedTime: CloudBlockedTime
    enum CodingKeys: String, CodingKey { case blockedTime = "blocked_time" }
}

// MARK: - Lore ontology (docs/Ontology.md): Rails `/lore/entities` and the core FFI share this JSON

/// What the miner learned about an organization or person, with the quote it came from.
struct LoreFact: Decodable, Hashable {
    struct Related: Decodable, Hashable { let name: String }
    let kind: String
    let name: String
    let value: String?
    let quote: String?
    let confidence: Double?
    let related: Related?

    /// "role: Head of Operations" / "works on Platform migration".
    var line: String {
        let label = name.replacingOccurrences(of: "_", with: " ")
        if let related { return "\(label) \(related.name)" }
        return "\(label): \(value ?? "")"
    }
}

struct LoreEntityRow: Decodable {
    let id: String
    let kind: String
    let emailDomain: String?
    let address: String?
    enum CodingKeys: String, CodingKey { case id, kind, address; case emailDomain = "email_domain" }
}
struct LoreEntitiesResponse: Decodable { let entities: [LoreEntityRow] }
struct LoreEntityResponse: Decodable {
    struct Detail: Decodable { let facts: [LoreFact]? }
    let entity: Detail
}

/// `GET /brands/:domain` (docs/plans/lore.md §4b): a site's name, icon and colour.
/// `icon_url` is an image-proxy path carrying the original URL in `?url=`.
struct CloudBrand: Decodable {
    let name: String?
    let iconURL: String?
    let themeColor: String?
    enum CodingKeys: String, CodingKey { case name; case iconURL = "icon_url"; case themeColor = "theme_color" }
}
struct CloudBrandResponse: Decodable { let brand: CloudBrand? }

/// Address folders (API `GET orgs/:org/folders?domain=`): an MX domain's mail split
/// by the address it came in to. Inbox is mail for you; under it your own address
/// and its +tags, the shared addresses (info@, support@) and Other. Mirrors
/// `ui/web/src/lib/addressFolders.js` + `hooks/useAddressFolders.js`.
struct AddressFolder: Decodable, Identifiable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable { case inbox, own, tag, shared, other }

    let id: String
    /// "inbox", "vince", "vince+receipts", "info" or "other" — also the mirror row's `folder`.
    let key: String
    let kind: Kind
    let address: String?
    let parent: String?
    var unread: Int
    let canReply: Bool
    var inInbox: Bool
    var notify: Bool

    enum CodingKeys: String, CodingKey {
        case id, key, kind, address, parent, unread, notify
        case canReply = "can_reply", inInbox = "in_inbox"
    }

    static let inboxKey = "inbox"

    /// Header name: "info@", "vince+receipts@", "Other", "Inbox".
    var label: String {
        switch kind {
        case .inbox: return "Inbox"
        case .other: return "Other"
        default: return "\(key)@"
        }
    }

    /// Tree name, the address implied: "info", a tag as "+receipts" under its owner.
    var treeLabel: String {
        if kind == .tag, let parent, key.hasPrefix(parent) { return String(key.dropFirst(parent.count)) }
        return kind == .own || kind == .shared ? key : label
    }

    var icon: String { kind == .other ? "tray.2.fill" : kind == .inbox ? "tray.fill" : "at" }
    /// Other has no address to keep a pref under: no bell, no menu.
    var hasPrefs: Bool { kind != .other }
    /// Show in Inbox is a choice for shared and tag folders only.
    var hasInboxToggle: Bool { kind == .shared || kind == .tag }
    /// The pref key the API takes: the full address, or "inbox".
    var prefKey: String { kind == .inbox ? Self.inboxKey : (address ?? key) }
}

struct AddressFoldersResponse: Decodable { let folders: [AddressFolder] }
