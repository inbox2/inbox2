package com.inbox2.app.model

// Every conversation-level action the inbox + reader can apply. Single source for the
// engine/cloud verb, the inverse (optimistic undo), the toast badge glyph, whether the
// action removes the row, and the "Move to Inbox" restore mapping. Ported verbatim from
// iOS ConversationAction.swift (see docs/iOS-App.md §11 — port-verbatim contract).
sealed class ConversationAction {
    data object Archive : ConversationAction()
    data object Unarchive : ConversationAction()
    data object Trash : ConversationAction()
    data object Untrash : ConversationAction()
    data object MarkRead : ConversationAction()
    data object MarkUnread : ConversationAction()
    data object Flag : ConversationAction()
    data object Unflag : ConversationAction()
    data object Spam : ConversationAction()
    data object Unspam : ConversationAction()
    data class SetQuadrant(val quadrant: Quadrant) : ConversationAction()
    data object ClearQuadrant : ConversationAction()
    /** Lore's per-member tick on a shared domain: the thread stays put for everyone else. */
    data object LoreDone : ConversationAction()
    data object LoreUndone : ConversationAction()

    /** The verb `perform_action` (and the cloud action mapping) expects. */
    val verb: String
        get() = when (this) {
            Archive -> "archive"
            Unarchive -> "unarchive"
            Trash -> "trash"
            Untrash -> "untrash"
            MarkRead -> "mark_read"
            MarkUnread -> "mark_unread"
            Flag -> "flag"
            Unflag -> "unflag"
            Spam -> "spam"
            Unspam -> "unspam"
            is SetQuadrant -> "set_quadrant:${quadrant.raw}"
            ClearQuadrant -> "clear_quadrant"
            LoreDone -> "lore_done"
            LoreUndone -> "lore_undone"
        }

    /** The inverse for the optimistic-undo affordance (null = no undo). */
    val reverse: ConversationAction?
        get() = when (this) {
            Archive -> Unarchive
            Unarchive -> Archive
            Trash -> Untrash
            Untrash -> Trash
            MarkRead -> MarkUnread
            MarkUnread -> MarkRead
            Flag -> Unflag
            Unflag -> Flag
            Spam -> Unspam
            Unspam -> Spam
            is SetQuadrant, ClearQuadrant -> null
            LoreDone -> LoreUndone
            LoreUndone -> LoreDone
        }

    /** Past-tense confirmation for the undo toast. */
    val title: String
        get() = when (this) {
            Archive -> "Archived"
            Unarchive, Untrash, Unspam -> "Moved to Inbox"
            Trash -> "Trashed"
            MarkRead -> "Marked read"
            MarkUnread -> "Marked unread"
            Flag -> "Flagged"
            Unflag -> "Unflagged"
            Spam -> "Marked spam"
            is SetQuadrant -> "Moved to ${quadrant.label}"
            ClearQuadrant -> "Triage cleared"
            LoreDone -> "Marked done"
            LoreUndone -> "Put back"
        }

    /** SF-Symbol glyph for the toast badge / menu item (mapped to Material in the UI). */
    val icon: String
        get() = when (this) {
            Archive -> "archivebox"
            Unarchive, Untrash, Unspam -> "tray.and.arrow.down"
            Trash -> "trash"
            MarkRead -> "envelope.open"
            MarkUnread -> "envelope.badge"
            Flag -> "flag"
            Unflag -> "flag.slash"
            Spam -> "exclamationmark.octagon"
            is SetQuadrant -> quadrant.icon
            LoreDone -> "checkmark.circle"
            LoreUndone -> "arrow.uturn.backward"
            ClearQuadrant -> "xmark.circle"
        }

    /** Whether applying this removes the conversation from the current list. */
    val removesRow: Boolean
        get() = when (this) {
            Archive, Trash, Spam, Unarchive, Untrash, Unspam -> true
            else -> false
        }

    /** Whether applying this should clear the thread's delivered notification — the
     *  launcher badge is notification-driven, so every surface that files or reads a
     *  thread must use this same rule rather than its own. */
    val clearsNotification: Boolean
        get() = removesRow || this == MarkRead

    companion object {
        /** The action that restores a removed thread to the inbox ("Move to Inbox"). */
        fun restore(fromStatus: String): ConversationAction? = when (fromStatus) {
            ConvStatusValue.ARCHIVED -> Unarchive
            ConvStatusValue.TRASH -> Untrash
            ConvStatusValue.SPAM -> Unspam
            else -> null
        }
    }
}
