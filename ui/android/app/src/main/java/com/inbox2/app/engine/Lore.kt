package com.inbox2.app.engine

import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.RelativeTime
import org.json.JSONObject

/**
 * Lore — the open-workload view (docs/plans/lore.md). The same rules as the web's
 * `ui/web/src/lib/lore.js` and iOS `Models/Lore.swift`: a Lore item IS a thread, open =
 * still in the inbox with a Lore label, done = archived.
 */
enum class LoreBucket(val tag: String) {
    REPLY("Reply"), WORK("Work"), PAY("Pay"), MEET("Meet"), REVIEW("Review"),
    READ("Read"), WAITING("Waiting"), HANDLED("Handled");

    /** Buckets "Do first" is drawn from — the ones that need the person. */
    val isAction get() = this == PAY || this == REPLY || this == WORK || this == MEET

    companion object {
        /** Built-in Jev label → bucket; `resolved`/untriaged → none; a custom label → work. */
        fun forLabel(label: String?): LoreBucket? {
            if (label.isNullOrEmpty()) return null
            return when (TriageLabel.from(label)) {
                TriageLabel.NEEDS_ANSWER -> REPLY
                TriageLabel.NEEDS_APPROVAL, TriageLabel.ACTION_REQUIRED -> WORK
                TriageLabel.PAYMENT_DUE -> PAY
                TriageLabel.SCHEDULING -> MEET
                TriageLabel.TO_REVIEW -> REVIEW
                TriageLabel.READ_LATER -> READ
                TriageLabel.WAITING_REPLY, TriageLabel.NEEDS_ANSWER_OTHER -> WAITING
                TriageLabel.FYI, TriageLabel.RECEIPT, TriageLabel.NOTIFICATION -> HANDLED
                TriageLabel.RESOLVED -> null
                null -> WORK
            }
        }
    }
}

/** Threads about the same request from one counterpart, as one row (web `groupItems`):
 *  an invoice and its reminder. Ticking it archives every one; the lead is the most urgent. */
data class LoreGroup(val items: List<Conversation>) {
    val lead: Conversation get() = items[0]
    val id: String get() = "g:${lead.id}"
}

data class LoreSection(
    val bucket: LoreBucket, val title: String,
    val items: List<Conversation> = emptyList(), val groups: List<LoreGroup> = emptyList(),
)

/** A "Handled for you" group — suggest-only: nothing moves until its button is pressed. */
data class LoreHandledGroup(
    val label: TriageLabel, val title: String, val button: String, val action: ConversationAction,
    val items: List<Conversation> = emptyList(),
) {
    /** Shared-domain mail only hides for you, so the button says so. */
    val buttonLabel: String get() = if (items.isNotEmpty() && items.all { it.isMemberDone }) "Hide" else button
}

/** Lore's personal buckets on a shared domain: a tick hides the thread for this member
 *  only (api `TriageLabel::PERSONAL`, web `isMemberDone`). Work items and channel mail
 *  keep done == archived. */
val Conversation.isMemberDone: Boolean
    get() = isDomain && triageLabel in setOf(
        TriageLabel.READ_LATER.raw, TriageLabel.FYI.raw, TriageLabel.RECEIPT.raw, TriageLabel.NOTIFICATION.raw)

/** Subject cleaning, "same request", age, deadlines and search — web `lore.js` / iOS `LoreText`. */
object LoreText {
    private val REPLY = Regex("^(?:\\s*(?:re|fw|fwd|aw|wg|antw|tr)\\s*(?:\\[\\d+])?\\s*:\\s*)+", RegexOption.IGNORE_CASE)
    private val REMINDER = Regex(
        "^\\s*(?:\\d+(?:e|nd|rd|th)?\\s+)?(?:herinnering|reminder|aanmaning|betalingsherinnering|erinnerung|rappel)\\b\\s*[:\\-–]?\\s*",
        RegexOption.IGNORE_CASE)
    private val NOISE = Regex("^\\s*(?:\\[?action required]?|actie vereist)\\s*[:\\-–]\\s*", RegexOption.IGNORE_CASE)
    private val FILLER = setOf("uw", "your", "the", "de", "het", "een", "van", "voor", "for", "and", "en", "from")
    private val YEAR = Regex("^(19|20)\\d\\d$")

    /** "RE: Herinnering: Privium factuur" → "Privium factuur". */
    fun clean(subject: String): String =
        subject.replace(REPLY, "").replace(REMINDER, "").replace(NOISE, "")
            .trim().replace(Regex("\\s+"), " ").replaceFirstChar { it.uppercaseChar() }

    fun isReminder(subject: String) = REMINDER.containsMatchIn(subject.replace(REPLY, ""))

    /** Reference numbers (4+ digits, not years) in the subject or summary. */
    fun refs(c: Conversation): Set<String> =
        Regex("\\d{4,}").findAll("${c.subject} ${c.preview}").map { it.value }.filterNot { YEAR.matches(it) }.toSet()

    private fun words(subject: String): Set<String> =
        clean(subject).lowercase().split(Regex("[^\\p{L}\\p{N}]+"))
            .filter { it.length > 2 && it !in FILLER && !YEAR.matches(it) }.toSet()

    /** A shared reference, or a reminder carrying most of the other's subject words.
     *  The same subject alone isn't enough: two "Invoice" mails are usually two invoices. */
    fun related(a: Conversation, b: Conversation): Boolean {
        val ra = refs(a)
        if (refs(b).any { it in ra }) return true
        if (!isReminder(a.subject) && !isReminder(b.subject)) return false
        val wa = words(a.subject)
        val wb = words(b.subject)
        val small = if (wa.size <= wb.size) wa else wb
        val big = if (small === wa) wb else wa
        if (small.isEmpty()) return false
        return small.count { it in big }.toDouble() / small.size >= 0.6
    }

    /** 0 (under 2 days) … 4 (two months+): the row's category bar fades with it. */
    fun ageStep(c: Conversation, now: Long = System.currentTimeMillis()): Int {
        val at = RelativeTime.parse(c.updatedAt)?.time ?: return 4
        val days = (now - at) / 86_400_000.0
        return when { days < 2 -> 0; days < 7 -> 1; days < 28 -> 2; days < 56 -> 3; else -> 4 }
    }

    /** "2026-10-24" → the end of that local day (ms). */
    fun dueAt(c: Conversation): Long? {
        val parts = c.dueOn?.take(10)?.split('-')?.mapNotNull { it.toIntOrNull() } ?: return null
        if (parts.size != 3) return null
        return java.util.Calendar.getInstance().apply { set(parts[0], parts[1] - 1, parts[2], 23, 59, 59) }.timeInMillis
    }

    /** Jev priority plus a deadline bump (web `urgency`): overdue +1.5, within 3 days +1,
     *  within a week +0.5. Untriaged with no deadline sorts last (-1). */
    fun urgency(c: Conversation, now: Long = System.currentTimeMillis()): Double {
        val priority = c.triagePriority ?: -1.0
        val due = dueAt(c) ?: return priority
        val left = (due - now) / 86_400_000.0
        return maxOf(priority, 0.0) + when { left < 0 -> 1.5; left < 3 -> 1.0; left < 7 -> 0.5; else -> 0.0 }
    }

    // ponytail: a short public-suffix list, not the PSL; extend when a country's mail groups wrong.
    private val TWO_PART = setOf("co.uk", "org.uk", "ac.uk", "com.au", "net.au", "co.nz", "co.za",
        "com.br", "co.jp", "co.in", "com.sg", "com.tr", "co.ae", "com.mx")

    /** Mailbox providers, not organizations: a gmail.com sender is a person (web FREEMAIL). */
    private val FREEMAIL = setOf(
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com",
        "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "gmx.net", "gmx.de",
        "mail.com", "zoho.com", "yandex.com", "hey.com", "fastmail.com")

    /** "billing.mail.odido.nl" → "odido.nl": the organization a sender belongs to; null
     *  for freemail (and anything without a domain). */
    fun orgDomain(email: String): String? {
        val host = email.substringAfterLast('@', "").lowercase()
        if (!host.contains('.')) return null
        val parts = host.split('.')
        val two = parts.takeLast(2).joinToString(".")
        val domain = if (two in TWO_PART && parts.size >= 3) parts.takeLast(3).joinToString(".") else two
        return domain.takeUnless { it in FREEMAIL }
    }

    /** "odido.nl" → "Odido". */
    fun domainLabel(domain: String) = domain.substringBefore('.').replaceFirstChar { it.uppercaseChar() }

    /** Does `c` match a free-text Lore search (title, summary, sender)? */
    fun matches(c: Conversation, q: String): Boolean {
        val t = q.trim()
        return t.isEmpty() || listOf(c.subject, c.preview, c.sender, c.email).any { it.contains(t, ignoreCase = true) }
    }
}

data class LoreToday(
    val first: List<Conversation>,
    val firstGroups: List<LoreGroup>,
    val sections: List<LoreSection>,
    val handled: List<LoreHandledGroup>,
    /** What needs the person (everything but handled). */
    val open: Int,
) {
    /** The Next-up card's group: the top "Do first" entry, else the first section's. */
    val nextGroup: LoreGroup? get() = firstGroups.firstOrNull() ?: sections.firstNotNullOfOrNull { it.groups.firstOrNull() }

    companion object {
        const val DO_FIRST_COUNT = 3

        val SECTIONS = listOf(
            LoreSection(LoreBucket.PAY, "To pay"),
            LoreSection(LoreBucket.REPLY, "To reply"),
            LoreSection(LoreBucket.WORK, "Work & requests"),
            LoreSection(LoreBucket.MEET, "Meetings"),
            LoreSection(LoreBucket.REVIEW, "To review"),
            LoreSection(LoreBucket.READ, "Read later"),
            LoreSection(LoreBucket.WAITING, "Waiting on others"),
        )
        val HANDLED = listOf(
            LoreHandledGroup(TriageLabel.FYI, "FYI threads", "Archive", ConversationAction.Archive),
            LoreHandledGroup(TriageLabel.RECEIPT, "Receipts and confirmations", "Archive", ConversationAction.Archive),
            LoreHandledGroup(TriageLabel.NOTIFICATION, "Sign-in codes and system alerts", "Delete", ConversationAction.Trash),
        )

        /** Most urgent first (priority + deadline), untriaged last, then newest. */
        private val order = compareByDescending<Conversation> { LoreText.urgency(it) }
            .thenByDescending { RelativeTime.parse(it.updatedAt)?.time ?: 0L }

        /** Same bucket, same counterpart (sender domain, else address) and related.
         *  `sorted` is most urgent first, so each group's lead is its most urgent thread. */
        fun group(sorted: List<Conversation>): List<LoreGroup> {
            val out = mutableListOf<MutableList<Conversation>>()
            val byKey = HashMap<String, MutableList<Int>>()
            for (c in sorted) {
                // The organization, else (freemail, no domain) the sender's own address.
                val who = LoreText.orgDomain(c.email) ?: c.email.lowercase().ifEmpty { c.id }
                val key = "${LoreBucket.forLabel(c.triageLabel)}|$who"
                val idx = byKey[key]?.firstOrNull { i -> out[i].any { LoreText.related(it, c) } }
                if (idx != null) out[idx].add(c)
                else { byKey.getOrPut(key) { mutableListOf() }.add(out.size); out.add(mutableListOf(c)) }
            }
            return out.map { LoreGroup(it) }
        }

        /** Today from inbox rows (the inbox read already hides archived/trash/spam). */
        fun build(rows: List<Conversation>): LoreToday {
            val items = rows.filter { LoreBucket.forLabel(it.triageLabel) != null && !it.loreDone }.sortedWith(order)
            fun bucket(c: Conversation) = LoreBucket.forLabel(c.triageLabel)!!
            val groups = group(items.filter { bucket(it) != LoreBucket.HANDLED })
            val firstGroups = groups.filter { bucket(it.lead).isAction }.take(DO_FIRST_COUNT)
            val firstIds = firstGroups.mapTo(HashSet()) { it.id }
            return LoreToday(
                first = firstGroups.map { it.lead },
                firstGroups = firstGroups,
                sections = SECTIONS.map { s ->
                    val mine = groups.filter { bucket(it.lead) == s.bucket && it.id !in firstIds }
                    s.copy(groups = mine, items = mine.flatMap { it.items })
                },
                handled = HANDLED.map { g -> g.copy(items = items.filter { bucket(it) == LoreBucket.HANDLED && it.triageLabel == g.label.raw }) },
                open = items.count { bucket(it) != LoreBucket.HANDLED },
            )
        }
    }
}

/** An email-less Lore todo (`lore_todos`): added by voice (`add_reminder`) or "+ Add todo". */
data class LoreTodo(val id: String, val title: String, val source: String)

// ── Ontology + pages (docs/Ontology.md; the same JSON from Rails `/lore/*` and the core FFI) ──

/** What the miner learned about an organization or person, with the quote it came from. */
data class LoreFact(
    val kind: String, val name: String, val value: String?, val quote: String?,
    val confidence: Double, val related: String?,
) {
    /** "role: Head of Operations" / "works on Platform migration". */
    val line: String get() = name.replace('_', ' ').let { if (related != null) "$it $related" else "$it: ${value.orEmpty()}" }

    companion object {
        private fun JSONObject.str(k: String) = if (isNull(k)) null else optString(k).ifEmpty { null }

        /** `{ entities: [...] }` → the id of the exact match (by domain or address), or null. */
        fun matchId(entitiesJson: String, kind: String, domain: String?, address: String?): String? {
            val arr = JSONObject(entitiesJson).optJSONArray("entities") ?: return null
            return (0 until arr.length()).map { arr.getJSONObject(it) }.firstOrNull {
                if (kind == "organization") it.str("email_domain") == domain else it.str("address") == address
            }?.optString("id")
        }

        /** `{ entity: { facts: [...] } }` → facts. */
        fun facts(entityJson: String): List<LoreFact> {
            val arr = JSONObject(entityJson).optJSONObject("entity")?.optJSONArray("facts") ?: return emptyList()
            return (0 until arr.length()).map { arr.getJSONObject(it) }.map { o ->
                LoreFact(o.optString("kind"), o.optString("name"), o.str("value"), o.str("quote"),
                    o.optDouble("confidence", 0.0), o.optJSONObject("related")?.str("name"))
            }
        }
    }
}

/** A page in the person's C:\Lore folder (Disk), read-only on the phone. */
data class LorePageRef(val id: String, val name: String)

/** Who a Lore entity page is about. */
sealed interface LoreEntityRef {
    data class Org(val domain: String) : LoreEntityRef
    data class Person(val address: String, val name: String) : LoreEntityRef
}
