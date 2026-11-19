package com.inbox2.app.model

import org.json.JSONArray
import org.json.JSONObject

// Store-read models that carry a little JSON parsing for display. Ported from the iOS
// LocalRule / LocalAgent / OutboxItem (InboxStore.swift).

/** An on-device auto-rule (local_rules). Conditions/action stored as JSON. */
data class LocalRule(
    val key: String,
    val name: String,
    val conditionsJSON: String,
    val actionJSON: String,
    val enabled: Boolean,
    val accountKey: String?,
) {
    val id: String get() = key

    /** "to contains waseem@… · from is …" from the conditions array. */
    val conditionSummary: String
        get() = runCatching {
            val arr = JSONArray(conditionsJSON)
            if (arr.length() == 0) return "Any message"
            (0 until arr.length()).mapNotNull { i ->
                val c = arr.optJSONObject(i) ?: return@mapNotNull null
                val f = c.optString("field").ifEmpty { return@mapNotNull null }
                val op = c.optString("op", "is")
                val v = c.opt("value")?.toString() ?: ""
                "$f $op ${if (v.length > 22) v.take(22) + "…" else v}"
            }.joinToString(" · ")
        }.getOrDefault("Any message").ifEmpty { "Any message" }

    /** "Run agent (claude-code)" / "Archive" / "Set priority …". */
    val actionSummary: String
        get() = runCatching {
            val obj = JSONObject(actionJSON)
            when (obj.optString("type")) {
                "run_agent" -> "Run agent (${obj.optString("adapter_id", "agent")})"
                "builtin" -> obj.optString("builtin", "Built-in action").replaceFirstChar { it.uppercase() }
                "set_quadrant" -> "Set priority: ${obj.optString("quadrant")}"
                else -> obj.optString("type", "Action").replace("_", " ").replaceFirstChar { it.uppercase() }
            }
        }.getOrDefault("—")

    /** run_agent rules need the desktop CLI harness; built-ins run on-device. */
    val needsDesktop: Boolean get() = actionJSON.contains("\"run_agent\"")
}

/** An installed CLI agent (local_agents) rules can dispatch to. */
data class LocalAgent(
    val displayName: String,
    val adapterId: String,
    val version: String?,
    val enabled: Boolean,
) {
    val id: String get() = adapterId
}

/** A queued outgoing send (outbox_messages). Payload is the composed OutgoingMessage. */
data class OutboxItem(
    val key: String,
    val accountKey: String,
    val payloadJSON: String,
    val status: String,
    val retryCount: Int,
    val maxRetries: Int,
    val errorMessage: String?,
    val createdAt: String,
) {
    val id: String get() = key
    private val payload: JSONObject get() = runCatching { JSONObject(payloadJSON) }.getOrDefault(JSONObject())

    val recipient: String
        get() {
            val to = payload.optString("to_address")
            val first = MailAddress.parseList(to).firstOrNull()
            return first?.let { it.name.ifEmpty { it.email } } ?: "(no recipient)"
        }

    val subject: String
        get() = payload.optString("subject").trim().ifEmpty { "(no subject)" }

    val preview: String
        get() = payload.optString("body_plain").trim().replace("\n", " ")

    val isFailed: Boolean get() = status == OutboxStatusValue.FAILED
    val isSending: Boolean get() = status == OutboxStatusValue.SENDING

    val statusLine: String
        get() = when (status) {
            OutboxStatusValue.FAILED -> "Failed · $retryCount/$maxRetries tries"
            OutboxStatusValue.SENDING -> "Sending…"
            else -> if (retryCount > 0) "Waiting · try $retryCount/$maxRetries" else "Waiting to send"
        }

    val time: String get() = RelativeTime.short(createdAt)
}
