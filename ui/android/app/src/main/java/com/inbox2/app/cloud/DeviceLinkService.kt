package com.inbox2.app.cloud

import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.browser.customtabs.CustomTabsIntent
import com.inbox2.app.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URL
import java.net.URLEncoder

/**
 * Device-link ("link this device to your inbox2 account") flow — the OAuth-style,
 * loopback-redirect + PKCE handshake against the web approval page. Mirrors the iOS/web
 * device-link client and reuses the same machinery as [com.inbox2.app.oauth.OAuthService]:
 * a local ServerSocket on 127.0.0.1 captures the `GET /cb?code=…` redirect, consent is
 * approved in a Custom Tab (the system browser, signed in to the web account), and the
 * captured code is exchanged — PKCE-verified, no bearer — for a minted `ink_` token that
 * IS the account bearer (adopted by [CloudSession.adoptLinkedToken]).
 */
class DeviceLinkService(private val context: Context) {
    /** Constants — the web approval page (mirrors the desktop/iOS LINK_URL) and the
     *  loopback callback path. The token mint reuses the app's API base ([AppConfig]). */
    private object Link {
        const val URL = "https://mail.inbox2.com/link"
        const val CALLBACK_PATH = "/cb"
        const val PLATFORM = "android"
        const val TIMEOUT_MS = 180_000L
    }

    /** Full flow: bind a loopback port, open the approval page in a Custom Tab, await the
     *  `/cb` redirect, verify state, then exchange the code for the account token. */
    suspend fun link(): String = withContext(Dispatchers.IO) {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            val port = server.localPort
            val state = java.util.UUID.randomUUID().toString()
            val pkce = Pkce.create()
            val redirect = "http://127.0.0.1:$port${Link.CALLBACK_PATH}"

            val url = "${Link.URL}" +
                "?device_name=${enc(deviceName())}" +
                "&platform=${Link.PLATFORM}" +
                "&redirect_uri=${enc(redirect)}" +
                "&state=${enc(state)}" +
                "&code_challenge=${enc(pkce.challenge)}" +
                "&code_challenge_method=S256"

            withContext(Dispatchers.Main) {
                CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
            }

            // Bound wait: cancel/timeout closes the socket (use {}) and throws — non-fatal.
            val page = "<html><body style='font:16px -apple-system,Roboto;text-align:center;padding:40px'>inbox2 is linked. You can go back to the app.</body></html>"
            val (code, returnedState) = withTimeout(Link.TIMEOUT_MS) { awaitLoopbackCode(server, page) }
            require(returnedState == state) { "State mismatch" }
            exchange(code, redirect, pkce.verifier)
        }
    }

    /** POST the captured code (+ PKCE verifier) to mint the `ink_` token. No auth header. */
    private fun exchange(code: String, redirectUri: String, verifier: String): String {
        val body = JSONObject()
            .put("code", code)
            .put("code_verifier", verifier)
            .put("redirect_uri", redirectUri)
            .toString()
        val resp = JSONObject(httpPostJson("${AppConfig.apiBase}/auth/device-link/token", body))
        return resp.optString("token").ifEmpty { throw IllegalStateException("No token in response") }
    }

    private fun deviceName(): String =
        listOf(Build.MANUFACTURER, Build.MODEL).filter { !it.isNullOrBlank() }
            .joinToString(" ").ifBlank { "Android device" }

    // ── tiny HTTP helper (mirrors OAuthService) ──────────────────────────────
    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    private fun httpPostJson(url: String, json: String): String {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            instanceFollowRedirects = false   // never replay the code/token across a redirect
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", "application/json")
            outputStream.use { it.write(json.toByteArray()) }
        }
        val ok = c.responseCode in 200..299
        val body = (if (ok) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
        if (!ok) throw IllegalStateException("HTTP ${c.responseCode}: ${body.take(200)}")
        return body
    }

    /** A PKCE (RFC 7636) verifier/challenge pair. The verifier is 64 bytes of CSPRNG
     *  entropy, base64url-encoded (no padding); the challenge is its SHA-256, base64url
     *  (S256). The verifier is sent only on the token exchange, the challenge only on link. */
    private class Pkce private constructor(val verifier: String, val challenge: String) {
        companion object {
            private fun b64url(bytes: ByteArray) = android.util.Base64.encodeToString(
                bytes, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
            )
            fun create(): Pkce {
                val bytes = ByteArray(64).also { java.security.SecureRandom().nextBytes(it) }
                val verifier = b64url(bytes)
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(verifier.toByteArray(Charsets.US_ASCII))
                return Pkce(verifier, b64url(digest))
            }
        }
    }
}

/** Read the single redirect line off a loopback socket and answer with a tiny page. */
internal fun awaitLoopbackCode(server: ServerSocket, page: String): Pair<String, String> {
    server.accept().use { conn ->
        val reader = conn.getInputStream().bufferedReader()
        val firstLine = reader.readLine() ?: ""           // "GET /cb?code=…&state=… HTTP/1.1"
        val path = firstLine.split(" ").getOrNull(1) ?: ""
        conn.getOutputStream().bufferedWriter().apply {
            write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${page.toByteArray().size}\r\nConnection: close\r\n\r\n$page")
            flush()
        }
        val query = Uri.parse("http://127.0.0.1$path")
        val code = query.getQueryParameter("code")
            ?: throw IllegalStateException(query.getQueryParameter("error") ?: "No code")
        return code to (query.getQueryParameter("state") ?: "")
    }
}
