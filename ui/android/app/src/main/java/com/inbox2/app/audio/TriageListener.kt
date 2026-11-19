package com.inbox2.app.audio

import android.content.Context
import com.inbox2.app.model.ConversationAction

/**
 * Hands-free voice triage (iOS `TriageListener`): after a read-aloud finishes,
 * listen for a filing keyword — "trash"/"delete"/"bin" or "archive" — and call
 * back the matched [ConversationAction]; a dismissal ("no", "skip", or any of
 * the universal stop-words) closes the window without acting. The recognizer
 * loop lives in [KeywordListener].
 */
class TriageListener(context: Context) : KeywordListener(context) {
    companion object {
        /** Single spoken keyword → the action it triages (iOS TriageListener.commands). */
        val COMMANDS: Map<String, ConversationAction> = mapOf(
            "trash" to ConversationAction.Trash,
            "delete" to ConversationAction.Trash,
            "bin" to ConversationAction.Trash,
            "archive" to ConversationAction.Archive,
        )

        /** Spoken dismissals: triage phrasing + the universal stop-words, so
         *  "ok"/"stop" interrupts a read-aloud exactly like it interrupts the Bridge. */
        val CANCEL_WORDS: Set<String> =
            BargeInListener.STOP_WORDS + setOf("no", "nope", "nothing", "skip", "leave", "dismiss", "never")
    }

    /** Called with the matched action the first time a keyword is heard in a run. */
    var onTriage: ((ConversationAction) -> Unit)? = null

    /** Called the first time a dismissal word is heard — close without acting. */
    var onCancel: (() -> Unit)? = null

    /** Newest word only fires — mirrors iOS TriageListener.scan. */
    override fun matched(words: List<String>): Boolean {
        val newest = words.last()
        COMMANDS[newest]?.let { onTriage?.invoke(it); return true }
        if (newest in CANCEL_WORDS) { onCancel?.invoke(); return true }
        return false
    }
}
