import SwiftUI

/// Account-key routing convention: inbox2 "MX" team-pool keys are prefixed `org_`
/// (the whole-org chip) or `dom_` (a per-domain workspace chip); everything else is
/// an offline channel. One place owns the prefixes so the routing decision isn't
/// re-derived across the view layer.
enum AccountKey {
    static let domainPrefix = "org_"
    static let domainWorkspacePrefix = "dom_"
    static func isDomain(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.hasPrefix(domainPrefix) || key.hasPrefix(domainWorkspacePrefix)
    }

    /// The `dom_…` list filter when a specific domain workspace is selected; nil for
    /// the whole-org (legacy) chip, which shows the unfiltered pool.
    static func domainFilter(_ key: String?) -> String? {
        key?.hasPrefix(domainWorkspacePrefix) == true ? key : nil
    }
}

/// Eisenhower triage quadrant — matches the desktop `lib/priority.js` keys. Carries
/// its own menu label + glyph so the "Move to" submenus are data-driven.
enum Quadrant: String, CaseIterable, Identifiable {
    case doFirst = "DO_FIRST"
    case schedule = "SCHEDULE"
    case delegate = "DELEGATE"
    case later = "LATER"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .doFirst: return "Priority"
        case .schedule: return "Schedule"
        case .delegate: return "Delegate"
        case .later: return "Later"
        }
    }
    /// Glyphs match the desktop Eisenhower quadrants (web lib/priority.js) and
    /// MailFolder's triage views, so the same quadrant never wears two icons.
    var systemImage: String {
        switch self {
        case .doFirst: return "flame.fill"
        case .schedule: return "calendar.badge.clock"
        case .delegate: return "person.badge.plus"
        case .later: return "clock"
        }
    }
}

/// Every conversation-level action the inbox + reader can apply. Single source for
/// the engine/cloud verb string, the inverse (for optimistic undo), and whether the
/// action removes the row from the current list — so views stop hardcoding verb
/// strings like `"set_quadrant:DO_FIRST"` and re-deriving these facts inline.
enum ConversationAction: Equatable {
    case archive, unarchive
    case trash, untrash
    case markRead, markUnread
    case flag, unflag
    case spam, unspam
    case setQuadrant(Quadrant)
    case clearQuadrant
    /// Lore's per-member tick on a shared domain: the thread stays put for everyone else.
    case loreDone, loreUndone

    /// The verb the engine FFI (`perform_action`) and the cloud action mapping expect.
    var verb: String {
        switch self {
        case .archive: return "archive"
        case .unarchive: return "unarchive"
        case .trash: return "trash"
        case .untrash: return "untrash"
        case .markRead: return "mark_read"
        case .markUnread: return "mark_unread"
        case .flag: return "flag"
        case .unflag: return "unflag"
        case .spam: return "spam"
        case .unspam: return "unspam"
        case .setQuadrant(let q): return "set_quadrant:\(q.rawValue)"
        case .clearQuadrant: return "clear_quadrant"
        case .loreDone: return "lore_done"
        case .loreUndone: return "lore_undone"
        }
    }

    /// The inverse action for the inbox's optimistic-undo affordance (nil = no undo).
    var reverse: ConversationAction? {
        switch self {
        case .archive: return .unarchive
        case .unarchive: return .archive
        case .trash: return .untrash
        case .untrash: return .trash
        case .markRead: return .markUnread
        case .markUnread: return .markRead
        case .flag: return .unflag
        case .unflag: return .flag
        case .spam: return .unspam
        case .unspam: return .spam
        case .setQuadrant, .clearQuadrant: return nil
        case .loreDone: return .loreUndone
        case .loreUndone: return .loreDone
        }
    }

    /// Past-tense confirmation for the undo toast ("Archived", "Marked read"). The
    /// restore verbs (unarchive/untrash/unspam) are surfaced as "Move to Inbox", so
    /// their toast reads "Moved to Inbox".
    var title: String {
        switch self {
        case .archive: return "Archived"
        case .unarchive, .untrash, .unspam: return "Moved to Inbox"
        case .trash: return "Trashed"
        case .markRead: return "Marked read"
        case .markUnread: return "Marked unread"
        case .flag: return "Flagged"
        case .unflag: return "Unflagged"
        case .spam: return "Marked spam"
        case .setQuadrant(let q): return "Moved to \(q.label)"
        case .clearQuadrant: return "Triage cleared"
        case .loreDone: return "Marked done"
        case .loreUndone: return "Put back"
        }
    }

    /// SF Symbol shown in the undo toast's icon badge — the same glyph each action's
    /// menu item uses, so the toast reads as "what just happened".
    var icon: String {
        switch self {
        case .archive: return "archivebox"
        case .unarchive, .untrash, .unspam: return "tray.and.arrow.down"
        case .trash: return "trash"
        case .markRead: return "envelope.open"
        case .markUnread: return "envelope.badge"
        case .flag: return "flag"
        case .unflag: return "flag.slash"
        case .spam: return "exclamationmark.octagon"
        case .setQuadrant(let q): return q.systemImage
        case .clearQuadrant: return "xmark.circle"
        case .loreDone: return "checkmark.circle"
        case .loreUndone: return "arrow.uturn.backward"
        }
    }

    /// Whether applying this removes the conversation from the current list — the
    /// destructive "moves" (archive/trash/spam) and, in a spam/trash/archived folder,
    /// the restore verbs (which leave that folder). Toggles (read/flag/quadrant) stay.
    var removesRow: Bool {
        switch self {
        case .archive, .trash, .spam, .unarchive, .untrash, .unspam: return true
        default: return false
        }
    }

    /// How this action changes the inbox-visible *unread* count for ONE conversation
    /// whose current unread state is `wasUnread`. Drives the optimistic app-badge
    /// nudge so the badge tracks the action immediately — even if the app is
    /// backgrounded before the async write-back + recompute runs (trash, then home).
    /// The next full refresh reconciles to the true count.
    func badgeDelta(wasUnread: Bool) -> Int {
        switch self {
        case .markUnread: return wasUnread ? 0 : 1     // read -> unread: +1
        case .markRead: return wasUnread ? -1 : 0      // unread -> read: -1
        case .archive, .trash, .spam:                  // leaves the inbox
            return wasUnread ? -1 : 0
        case .unarchive, .untrash, .unspam:            // returns to the inbox
            return wasUnread ? 1 : 0
        default: return 0                              // flag/quadrant: no effect
        }
    }

    /// The action that restores a conversation from a removed status back to the
    /// inbox ("Move to Inbox"), or nil if it's already an inbox thread.
    static func restore(fromStatus status: String) -> ConversationAction? {
        switch status {
        case ConvStatusValue.archived: return .unarchive
        case ConvStatusValue.trash: return .untrash
        case ConvStatusValue.spam: return .unspam
        default: return nil
        }
    }
}

/// Shared bodies for the triage ("Move to") and snooze menus, so the inbox bulk
/// bar, the row long-press menu, and the reader's overflow menu render the same
/// items instead of hand-copied lists. Each site keeps its own glyph variants
/// (params) and action plumbing (closures).
enum ConversationMenus {
    /// The quadrant list + "Clear triage". Spam is NOT in here — it's a filing verb
    /// every channel has (domain and offline alike), so it sits at menu root next to
    /// Archive/Trash instead of being buried in a triage submenu on engine threads.
    @ViewBuilder
    static func triageItems(clearIcon: String = "xmark.circle",
                            act: @escaping (ConversationAction) -> Void) -> some View {
        ForEach(Quadrant.allCases) { q in
            Button { act(.setQuadrant(q)) } label: { Label(q.label, systemImage: q.systemImage) }
        }
        Divider()
        Button { act(.clearQuadrant) } label: { Label("Clear triage", systemImage: clearIcon) }
    }

    /// Later today (3h) / Tomorrow / Next week.
    @ViewBuilder
    static func snoozeItems(snooze: @escaping (Date) -> Void) -> some View {
        Button { snooze(ReplyComposer.snoozeDate(hoursFromNow: 3)) } label: { Label("Later today", systemImage: "clock") }
        Button { snooze(SnoozeDate.tomorrowMorning) } label: { Label("Tomorrow", systemImage: "sunrise") }
        Button { snooze(SnoozeDate.nextWeekMorning) } label: { Label("Next week", systemImage: "calendar") }
    }
}
