package com.inbox2.app.engine

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject

/**
 * Live progress of the background triage + summary worker, mirrored from the
 * core's `triage-progress` event (`{inWindow, done, pending}`). 1:1 with the iOS
 * TriageState.
 */
data class TriageState(
    val inWindow: Int,
    val done: Int,
    val pending: Int,
    /** The head job's date (the worker runs newest-first) — what it's currently at,
     *  or null when idle. Lets a reader tell "being processed now" from "queued". */
    val currentDate: String? = null,
    /** Jev (TypeSafe) key state: `missing` | `ok` | `unauthorized` (a 401 stopped calls). */
    val jevStatus: String = "missing",
) {
    /** 0…1 completion fraction (1 when there's nothing to do). */
    val fraction: Float get() = if (inWindow > 0) (done.toFloat() / inWindow).coerceIn(0f, 1f) else 1f

    /** Whether the worker is actively processing (drives whether the bar is shown).
     *  Based on the queue, not done<inWindow — so deferred threads (no model to
     *  judge them) hide the bar instead of showing "Working…" forever. */
    val isActive: Boolean get() = pending > 0

    companion object {
        val EMPTY = TriageState(0, 0, 0)

        fun fromJson(payload: String): TriageState? = runCatching {
            val o = JSONObject(payload)
            TriageState(o.optInt("inWindow", 0), o.optInt("done", 0), o.optInt("pending", 0),
                o.optString("currentDate").takeIf { it.isNotEmpty() },
                o.optString("jevStatus", "missing"))
        }.getOrNull()
    }
}

/** How far back mail is classified/summarized. Raw values match the core. */
enum class ProcessingWindow(val raw: String, val label: String) {
    LAST_MONTH("1_month", "Last month"),
    THREE_MONTHS("3_months", "Last 3 months"),
    SIX_MONTHS("6_months", "Last 6 months"),
    ONE_YEAR("1_year", "Last year"),
    EVERYTHING("everything", "Everything");

    companion object {
        val DEFAULT = LAST_MONTH
        fun from(raw: String?): ProcessingWindow = entries.firstOrNull { it.raw == raw } ?: DEFAULT
    }
}

/**
 * Built-in triage labels (docs/Triage.md). Raw values match the core's wire-stable slugs.
 * `rowBadge` is null for low-signal categories so the list stays clean (mirrors iOS).
 * Any other slug is a custom label — see [TriageLabelNames].
 */
enum class TriageLabel(val raw: String, val rowBadge: String?) {
    NEEDS_ANSWER("needs_answer", "Reply"),
    NEEDS_ANSWER_OTHER("needs_answer_other", "Others"),
    WAITING_REPLY("waiting_reply", "Waiting"),
    NEEDS_APPROVAL("needs_approval", "Approve"),
    SCHEDULING("scheduling", "Schedule"),
    ACTION_REQUIRED("action_required", "Action"),
    FYI("fyi", null),
    RESOLVED("resolved", null),
    PAYMENT_DUE("payment_due", "Pay"),
    TO_REVIEW("to_review", "Review"),
    READ_LATER("read_later", "Read"),
    RECEIPT("receipt", null),
    NOTIFICATION("notification", null);

    companion object {
        fun from(raw: String?): TriageLabel? = raw?.let { r -> entries.firstOrNull { it.raw == r } }
    }
}

/**
 * One triage label, built-in or custom — the core's `get_triage_labels` /
 * `set_triage_labels` JSON shape `{slug,name,description,not_for,color,builtin,enabled}`.
 */
data class TriageLabelDef(
    val slug: String,
    val name: String,
    val description: String = "",
    val notFor: String = "",
    val color: String? = null,
    val builtin: Boolean = false,
    val enabled: Boolean = true,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("slug", slug).put("name", name).put("description", description)
        .put("not_for", notFor).put("color", color ?: JSONObject.NULL)
        .put("builtin", builtin).put("enabled", enabled)

    companion object {
        /** `fyi` is the fallback label: it can't be disabled (or deleted). */
        const val FALLBACK = "fyi"
        val SLUG = Regex("^[a-z0-9_]{1,40}$")

        fun parseList(json: String): List<TriageLabelDef> = runCatching {
            val a = JSONArray(json)
            (0 until a.length()).map { i ->
                val o = a.getJSONObject(i)
                TriageLabelDef(
                    o.optString("slug"), o.optString("name"), o.optString("description"),
                    o.optString("not_for"), o.optString("color").takeIf { !o.isNull("color") && it.isNotEmpty() },
                    o.optBoolean("builtin"), o.optBoolean("enabled", true),
                )
            }
        }.getOrDefault(emptyList())

        fun listJson(labels: List<TriageLabelDef>): String =
            JSONArray().apply { labels.forEach { put(it.toJson()) } }.toString()
    }
}

/**
 * Display names for custom triage slugs, read by every row. `local` is the engine's
 * label list (channel rows); `org` is each org's `triage-labels` (MX rows, keyed by org
 * id). Snapshot state so rows recompose when a list loads.
 * ponytail: a global holder, not DI — one app process, two small maps.
 */
object TriageLabelNames {
    var local by mutableStateOf<Map<String, String>>(emptyMap())
    var org by mutableStateOf<Map<String, Map<String, String>>>(emptyMap())

    /** A custom slug's chip text: the label's name, else the slug title-cased. */
    fun name(slug: String, accountKey: String, isDomain: Boolean): String =
        (if (isDomain) org[accountKey] else local)?.get(slug)
            ?: slug.split('_').filter { it.isNotEmpty() }.joinToString(" ") { it.replaceFirstChar(Char::uppercase) }
}

/** Jev priority score (0–4) → row chip: ≥ 3.5 Urgent, ≥ 2.5 High, else none. */
enum class TriagePriority(val label: String) {
    URGENT("Urgent"), HIGH("High");

    companion object {
        fun from(score: Double?): TriagePriority? = when {
            score == null -> null
            score >= 3.5 -> URGENT
            score >= 2.5 -> HIGH
            else -> null
        }
    }
}
