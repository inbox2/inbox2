package com.inbox2.app.ui.screens

import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.MailAddress
import com.inbox2.app.model.Message

// Reply/forward draft construction (iOS ReplyComposer parity). Pure builders pulled out
// of ReaderScreen so the quoting/subject/forward-header logic is unit-testable and can't
// silently drift if a second entry point (e.g. an inbox swipe-forward) is added later.

/** The user's own addresses (lowercased) a domain thread can send from: `username@`
 *  each domain of the thread's org (all orgs if it can't be told). Never a connected
 *  Gmail/Microsoft address — the send goes through inbox2, which can't sign for it. */
internal fun domainEmails(convo: Conversation, cloud: CloudSession): Set<String> = buildSet {
    val u = cloud.user.value?.username ?: return@buildSet
    val orgs = cloud.orgs.value
    val mine = orgs.filter { o -> o.id == convo.accountKey || o.domains.any { it.id == convo.accountKey } }
    mine.ifEmpty { orgs }.forEach { o ->
        // The server's send-as list when present (a rules-only member has no username@
        // address); older payloads → username@ each domain.
        o.fromAddresses?.let { list -> list.forEach { add(it.lowercase()) }; return@forEach }
        (o.domains.map { it.name } + listOfNotNull(o.domain)).filter { it.isNotBlank() }
            .forEach { add("$u@$it".lowercase()) }
    }
}

/** Which own address a reply to [m] comes from: the one it was sent from when it's your
 *  own mail, else the one it was sent to (To/Cc). Web `replyFromAddress` / iOS
 *  `ReplyComposer.replyFrom` parity. null when none of [own] is on the message. */
internal fun replyFrom(m: Message?, own: Set<String>): String? {
    if (m == null) return null
    return (MailAddress.parseList(m.fromAddress) + MailAddress.parseList(m.toAddress) +
        MailAddress.parseList(m.ccAddress.orEmpty()))
        .firstOrNull { own.contains(it.email.lowercase()) }?.email
}

/** Domain (MX) send-from: the own address on the latest message, else the address the
 *  thread arrived at; null for offline channels (they send from the account itself). */
internal fun domainFrom(convo: Conversation, last: Message?, own: Set<String>): String? =
    if (!convo.isDomain) null
    else replyFrom(last, own) ?: MailAddress.parse(convo.toAddress).email.ifEmpty { null }

/** A reply draft: To/Cc from the latest message, a de-duplicated `Re:` subject, and the
 *  original quoted below the cursor ("On <date>, <sender> wrote:"). */
internal fun replyPrefill(convo: Conversation, last: Message?, all: Boolean, own: Set<String> = emptySet(), accountEmail: String? = null): ComposePrefill {
    val from = domainFrom(convo, last, own)
    val selfEmail = from ?: accountEmail
    // Replying to your own message goes to the people you sent it to, never yourself.
    val sender = when {
        last == null -> convo.fromAddress
        selfEmail != null && last.email.equals(selfEmail, ignoreCase = true) -> last.toAddress
        else -> last.fromAddress
    }
    val merged = if (all) replyAllRecipients(last, selfEmail) else "" to ""
    val to = merged.first.ifEmpty { sender }
    val subj = if (convo.subject.startsWith("Re:", true)) convo.subject else "Re: ${convo.subject}"
    val orig = (last?.bodyPlain ?: "").trim()
    val quoted = if (orig.isEmpty()) "" else
        "\n\nOn ${last?.createdAt}, ${last?.sender} wrote:\n" + orig.lines().joinToString("\n") { "> $it" }
    return ComposePrefill(
        accountKey = convo.accountKey, to = to, cc = merged.second, subject = subj, body = quoted,
        conversationId = if (convo.isDomain) convo.id else null,
        replyToMessageKey = last?.id,
        conversationKey = convo.id,
        fromEmailOverride = from,
    )
}

/** The replier's addresses on `m`: `selfEmail`, plus — when it appears nowhere on the
 *  message and exactly one To/Cc address is on its domain — that address (the alias the
 *  mail arrived through, like info@). Two or more are ambiguous (one may be a colleague):
 *  none dropped. Never the sender. Mirrors web/iOS `ownAddresses`.
 *  ponytail: heuristic, no Gmail send-as list; fetch send-as identities if it misfires. */
internal fun ownAddresses(m: Message, selfEmail: String?): MutableSet<String> {
    val me = selfEmail?.lowercase().orEmpty()
    val own = mutableSetOf(me)
    val rcpts = (MailAddress.parseList(m.toAddress) + MailAddress.parseList(m.ccAddress.orEmpty()))
        .map { it.email.lowercase() }
    val from = MailAddress.parseList(m.fromAddress).map { it.email.lowercase() }
    val at = me.indexOf('@')
    if (at < 0 || me in rcpts || me in from) return own
    val mine = rcpts.filter { it.endsWith(me.substring(at)) }.toSet()
    if (mine.size == 1) own.add(mine.first())
    return own
}

/** Reply-all recipients, keeping the original To/Cc structure: To = the sender + the
 *  original To line, Cc = the original Cc line — each minus the replier's own address,
 *  de-duplicated by email (case-insensitive; an address already on To is dropped from
 *  Cc). Mirrors web/iOS so all three platforms strip self identically — a raw header
 *  string can't drop self out of a multi-recipient To/Cc line. Both empty if the
 *  replier was the only party. */
internal fun replyAllRecipients(m: Message?, selfEmail: String?): Pair<String, String> {
    if (m == null) return "" to ""
    val seen = ownAddresses(m, selfEmail)
    fun render(addrs: List<MailAddress.Parsed>): String = addrs.mapNotNull { a ->
        val key = a.email.lowercase()
        if (key.isEmpty() || !seen.add(key)) null
        else if (a.name == a.email) a.email else MailAddress.format(a.name, a.email)
    }.joinToString(", ")
    val to = render(MailAddress.parseList(m.fromAddress) + MailAddress.parseList(m.toAddress))
    val cc = render(MailAddress.parseList(m.ccAddress.orEmpty()))
    return to to cc
}

/** A forward draft: de-duplicated `Fwd:` subject, the forwarded-message separator + body,
 *  and the original attachments carried as pending placeholders (offline channels only —
 *  domain threads have no per-message provider download path). */
internal suspend fun forwardPrefill(engine: EngineModel, convo: Conversation, last: Message?, own: Set<String> = emptySet()): ComposePrefill {
    val subj = if (convo.subject.startsWith("Fwd:", true)) convo.subject else "Fwd: ${convo.subject}"
    val quoted = "\n\n---------- Forwarded message ----------\n${last?.bodyPlain.orEmpty()}"
    val atts = if (last != null && !convo.isDomain) {
        engine.fetchMessage(convo.accountKey, last.id).attachments.map {
            PrefillAttachment(it.filename, it.mimeType, bytes = null,
                download = AttachmentRef(convo.accountKey, last.id, it.attachmentId))
        }
    } else emptyList()
    return ComposePrefill(accountKey = convo.accountKey, subject = subj, body = quoted, initialAttachments = atts,
        fromEmailOverride = domainFrom(convo, last, own))
}
