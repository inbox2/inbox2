package com.inbox2.app.engine

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** A locally-saved compose draft (iOS DraftStore.SavedDraft). */
data class SavedDraft(
    val id: String,
    val accountKey: String?,
    val to: String,
    val cc: String,
    val subject: String,
    val body: String,
    val bcc: String = "",
) {
    val preview: String get() = subject.ifBlank { body.take(60) }.ifBlank { "(empty draft)" }
}

/** Local compose drafts persisted as JSON (iOS DraftStore over UserDefaults). Feeds the
 *  Drafts folder + compose resume. */
class DraftStore(context: Context) {
    private val sp = context.applicationContext.getSharedPreferences("inbox2_drafts", Context.MODE_PRIVATE)

    fun all(): List<SavedDraft> = runCatching {
        val arr = JSONArray(sp.getString("drafts", "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            SavedDraft(o.getString("id"), o.optString("accountKey").ifEmpty { null },
                o.optString("to"), o.optString("cc"), o.optString("subject"), o.optString("body"), o.optString("bcc"))
        }
    }.getOrDefault(emptyList())

    fun save(d: SavedDraft) {
        val others = all().filterNot { it.id == d.id }
        persist(others + d)
    }

    fun delete(id: String) = persist(all().filterNot { it.id == id })

    fun get(id: String): SavedDraft? = all().firstOrNull { it.id == id }

    private fun persist(list: List<SavedDraft>) {
        val arr = JSONArray()
        list.forEach { d ->
            arr.put(JSONObject().put("id", d.id).put("accountKey", d.accountKey ?: "")
                .put("to", d.to).put("cc", d.cc).put("subject", d.subject).put("body", d.body).put("bcc", d.bcc))
        }
        sp.edit().putString("drafts", arr.toString()).apply()
    }
}
