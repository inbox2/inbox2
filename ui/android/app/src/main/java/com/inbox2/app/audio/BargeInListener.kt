package com.inbox2.app.audio

import android.content.Context

/**
 * Hands-free barge-in (iOS `KeywordSpotter`): while the Bridge speaks — a reply or a
 * brief — keep the mic open and listen for the shared stop-words ("cancel" / "stop" /
 * "ok" …) so the user can interrupt without reaching for the screen. The recognizer
 * loop lives in [KeywordListener].
 */
class BargeInListener(context: Context) : KeywordListener(context) {
    companion object {
        /** The universal stop-words — keep in sync with iOS `KeywordSpotter.stopWords`. */
        val STOP_WORDS = setOf("cancel", "stop", "ok", "okay", "enough")
    }

    /** Called with the matched stop-word the first time one is heard in a run. */
    var onStopWord: ((String) -> Unit)? = null

    /** Whole-word match on the freshly-spoken tail (mirrors iOS `KeywordSpotter.scan`):
     *  "stopwatch"/"okra" don't trigger, and only the newest word fires. */
    override fun matched(words: List<String>): Boolean {
        val hit = words.lastOrNull { it in STOP_WORDS } ?: return false
        onStopWord?.invoke(hit)
        return true
    }
}
