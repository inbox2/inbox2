package com.inbox2.app.engine

import android.content.Context

/** The four Outlook-style mark-as-read modes (iOS MarkReadMode / desktop MARK_READ_MODES). */
enum class MarkReadMode(val raw: String, val title: String, val detail: String) {
    IMMEDIATE("immediate", "When opened", "Marked read the moment you open it."),
    DELAY("delay", "After a delay", "Marked read after it's been on screen a few seconds."),
    SELECTION_CHANGE("selectionChange", "When I leave it", "Marked read when you go back or open another."),
    NEVER("never", "Manually only", "Never marked read automatically.");

    // Default: mark read the moment a message is opened (a quick open/back still
    // counts; the delay mode would cancel its dwell on a fast exit).
    companion object { fun fromRaw(r: String?) = entries.firstOrNull { it.raw == r } ?: IMMEDIATE }
}

/** Persists the mark-as-read preference (mode + dwell seconds) — iOS MarkReadManager. */
class MarkReadPrefs(context: Context) {
    private val sp = context.applicationContext.getSharedPreferences("inbox2_markread", Context.MODE_PRIVATE)

    var mode: MarkReadMode
        get() = MarkReadMode.fromRaw(sp.getString("mode", null))
        set(v) { sp.edit().putString("mode", v.raw).apply() }

    var delaySeconds: Int
        get() = sp.getInt("delay", 5).let { if (it > 0) it else 5 }
        set(v) { sp.edit().putInt("delay", v).apply() }
}
