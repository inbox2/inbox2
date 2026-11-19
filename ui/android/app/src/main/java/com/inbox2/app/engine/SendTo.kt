package com.inbox2.app.engine

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import com.inbox2.app.cloud.awaitLoopbackCode
import com.inbox2.app.model.Conversation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket

/** Send to… on the phone (docs/MCP-Client.md, TODO 48.14): the JSON of the core's `mcp_*`
 *  FFI, and the browser half of sign-in. Draft-only: a tool runs only from Create. */
data class McpPreset(val name: String, val url: String, val auth: String)

data class McpConnection(val id: String, val name: String, val url: String, val auth: String, val status: String) {
    val needsAuth: Boolean get() = status == "needs_auth"
}

data class McpField(val key: String, val label: String, val description: String, val kind: String, val options: List<String>, val required: Boolean)

data class McpDraft(val name: String, val description: String, val fields: List<McpField>, val values: Map<String, String>)

/** What Send to… made for a Lore item (the chip on the row). */
data class LoreSentRef(val itemKey: String, val connectionName: String, val reference: String?, val url: String?) {
    val chipLabel: String get() = reference ?: "Sent to $connectionName"

    companion object {
        /** The item key the desktop uses too (web `uid`): `mx:conv_…` or `local:conv_…`. */
        fun key(c: Conversation) = "${if (c.isDomain) "mx" else "local"}:${c.id}"
    }
}

object McpJson {
    private fun JSONObject.str(k: String) = if (isNull(k)) null else optString(k).ifEmpty { null }
    private fun objects(json: String) = JSONArray(json).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
    private fun strings(a: JSONArray?) = if (a == null) emptyList() else (0 until a.length()).map { a.getString(it) }

    fun presets(json: String) = objects(json).map { McpPreset(it.optString("name"), it.optString("url"), it.optString("auth")) }
    private fun connection(o: JSONObject) = McpConnection(o.optString("id"), o.optString("name"), o.optString("url"), o.optString("auth"), o.optString("status"))
    fun connections(json: String) = objects(json).map(::connection)

    fun drafts(json: String) = objects(json).map { d ->
        val fields = d.getJSONArray("fields").let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }.map { f ->
                McpField(f.optString("key"), f.optString("label"), f.optString("description"), f.optString("kind"), strings(f.optJSONArray("options")), f.optBoolean("required"))
            }
        }
        val values = d.getJSONObject("values").let { v -> v.keys().asSequence().associateWith { v.optString(it) } }
        McpDraft(d.optString("name"), d.optString("description"), fields, values)
    }

    fun sent(o: JSONObject) = LoreSentRef(o.optString("item_key"), o.optString("connection_name"), o.str("reference"), o.str("url"))
    fun sentList(json: String) = objects(json).map(::sent)
    fun itemJson(c: Conversation): String = JSONObject()
        .put("subject", c.subject).put("detail", c.preview).put("from", c.sender)
        .put("address", c.email).put("domain", LoreText.orgDomain(c.email) ?: "").toString()
}

/** Bind a loopback port, let `begin` start the sign-in, open the browser, wait for the
 *  one redirect back and hand the code to `finish`. A server that needs no sign-in stops
 *  after `begin` (the device-link pattern; the core holds the PKCE verifier). */
suspend fun mcpSignIn(context: Context, begin: suspend (String) -> String, finish: suspend (String, String) -> Unit) = withContext(Dispatchers.IO) {
    ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { server ->
        val begun = JSONObject(begin("http://127.0.0.1:${server.localPort}/cb"))
        if (begun.has("connected")) return@use
        val state = begun.getString("state")
        withContext(Dispatchers.Main) {
            CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(begun.getString("authorize_url")))
        }
        val page = "<html><body style='font:16px -apple-system,Roboto;text-align:center;padding:40px'>Connected. You can go back to inbox2.</body></html>"
        val (code, returned) = withTimeout(300_000L) { awaitLoopbackCode(server, page) }
        require(returned == state) { "The sign-in did not come back correctly." }
        finish(state, code)
    }
}
