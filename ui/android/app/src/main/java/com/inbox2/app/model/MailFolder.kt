package com.inbox2.app.model

// A mailbox folder the user can switch to from the drawer. Inbox/Archive/Trash map to
// conversation status; Sent/Drafts are provider folders (joined); the triage cases are
// the inbox2 quadrant gmail labels. Single source for title + icon + tint. Ported 1:1
// from iOS MailFolder (InboxStore.swift). Icons are SF-Symbol names; the Android Icon
// layer maps them to Material equivalents.
enum class MailFolder(val title: String, val sfIcon: String) {
    INBOX("Inbox", "tray"),
    SENT("Sent", "paperplane"),
    DRAFTS("Drafts", "doc"),
    OUTBOX("Outbox", "tray.and.arrow.up"),
    ARCHIVE("Archive", "archivebox"),
    SPAM("Spam", "exclamationmark.octagon"),
    TRASH("Trash", "trash"),
    PRIORITY("Priority", "flame.fill"),
    SCHEDULE("Schedule", "calendar.badge.clock"),
    DELEGATE("Delegate", "person.badge.plus"),
    LATER("Later", "clock"),
    IMPORTANT("Important", "star"),
    // Meta channel sub-views (Instagram/Messenger/WhatsApp), keyed on the
    // conversation `kind` (uniform across channels). See docs/Cloud-Push.md (Meta).
    META_ALL("All", "tray"),
    META_MESSAGES("Messages", "message"),
    META_COMMENTS("Comments", "text.bubble"),
    META_MENTIONS("Mentions", "at");

    val isTriage: Boolean get() = this in triage

    val isMeta: Boolean get() = this in metaAll

    /** Reader actions that are redundant in this folder (so hidden), mirroring the
     *  web reading pane: Archive is a no-op in Archive/Trash/Sent (a sent thread
     *  already lives in the archive); Trash is a no-op in Trash. */
    val hidesArchiveAction: Boolean get() = this == ARCHIVE || this == TRASH || this == SENT
    val hidesTrashAction: Boolean get() = this == TRASH

    /** Conversation `kind` values this Meta sub-view matches; null = no narrow (All). */
    val metaKinds: List<String>?
        get() = when (this) {
            META_MESSAGES -> listOf("dm", "postback")
            META_COMMENTS -> listOf("comment")
            META_MENTIONS -> listOf("mention")
            else -> null
        }

    /** Gmail label backing a triage view (e.g. "inbox2/Priority"); null for mailboxes. */
    val triageLabel: String? get() = if (isTriage) "inbox2/$title" else null

    /** Eisenhower quadrant tint (+ Important star); null for standard mailboxes. */
    val tintHex: String?
        get() = when (this) {
            PRIORITY -> "e06060"
            SCHEDULE -> "6ea8d9"
            DELEGATE -> "d4a843"
            LATER -> "6b7280"
            IMPORTANT -> "d0b468"
            else -> null
        }

    companion object {
        val mailboxes = listOf(INBOX, SENT, DRAFTS, OUTBOX, ARCHIVE, SPAM, TRASH)
        val triage = listOf(PRIORITY, SCHEDULE, DELEGATE, LATER, IMPORTANT)
        val metaAll = listOf(META_ALL, META_MESSAGES, META_COMMENTS, META_MENTIONS)

        /** Meta sub-views for an account's provider type (null = not Meta →
         *  standard mailboxes). WhatsApp is DM-only, so it shows just Messages. */
        fun meta(provider: String?): List<MailFolder>? = when (provider?.lowercase()) {
            "whatsapp" -> listOf(META_MESSAGES)
            "messenger" -> listOf(META_ALL, META_MESSAGES, META_COMMENTS)
            "instagram" -> listOf(META_ALL, META_MESSAGES, META_COMMENTS, META_MENTIONS)
            else -> null
        }
    }
}
