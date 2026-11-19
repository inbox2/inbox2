package com.inbox2.app.oauth

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import com.inbox2.app.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.net.URLEncoder

/** The two OAuth mail providers — mirrors iOS OAuthProvider. `providerType` is what the
 *  engine's add_account expects; `apiSegment` is the Rails proxy path. */
enum class OAuthProvider(val providerType: String, val apiSegment: String, val displayName: String) {
    GOOGLE("gmail", "google", "Google"),
    MICROSOFT("microsoft", "microsoft", "Microsoft"),
}

data class ConnectedTokens(val email: String, val accessToken: String, val refreshToken: String?)

/** A PKCE (RFC 7636) verifier/challenge pair. The verifier is 32 bytes of CSPRNG
 *  entropy, base64url-encoded; the challenge is its SHA-256, base64url-encoded (S256).
 *  The verifier is sent only on the token exchange, the challenge only on authorize. */
private class Pkce private constructor(val verifier: String, val challenge: String) {
    companion object {
        private fun b64url(bytes: ByteArray) = android.util.Base64.encodeToString(
            bytes, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
        )
        fun create(): Pkce {
            val bytes = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
            val verifier = b64url(bytes)
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
            return Pkce(verifier, b64url(digest))
        }
    }
}

/**
 * On-device OAuth via the Rails proxy (the proxy holds the client secret), using the
 * loopback-redirect pattern — the only redirect the proxy allows — so it works with the
 * existing Google/Microsoft client with no console changes. Ported from iOS OAuthService:
 * a local ServerSocket on 127.0.0.1 captures the `GET /oauth-callback?code=…` redirect;
 * consent is shown in a Custom Tab (the system browser, which providers require).
 */
class OAuthService(private val context: Context) {
    private val apiBase get() = AppConfig.apiBase

    /** Full flow: bind a loopback port, fetch the consent URL, open a Custom Tab, await
     *  the redirect, exchange the code for tokens, read the email. */
    suspend fun connect(provider: OAuthProvider, loginHint: String? = null): ConnectedTokens = withContext(Dispatchers.IO) {
        ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { server ->
            val port = server.localPort
            val state = java.util.UUID.randomUUID().toString()
            // PKCE (RFC 7636, S256): defense-in-depth for the loopback flow so a code
            // lifted from the redirect can't be redeemed without the verifier.
            val pkce = Pkce.create()
            val redirect = "http://127.0.0.1:$port/oauth-callback"
            val (authUrl, _) = authorizeUrl(provider, redirect, state, pkce.challenge, loginHint)

            // Open consent in the system browser (Custom Tab).
            withContext(Dispatchers.Main) {
                CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(authUrl))
            }

            val (code, returnedState) = awaitCallback(server)
            require(returnedState == state) { "State mismatch" }
            complete(provider, code, redirect, pkce.verifier)
        }
    }

    private fun authorizeUrl(provider: OAuthProvider, redirect: String, state: String, challenge: String, loginHint: String? = null): Pair<String, String> {
        // login_hint pre-selects the right account in the provider's picker on reconnect
        // (iOS OAuthService.authorizeURL) — the proxy forwards it to Google/Microsoft.
        val hint = if (!loginHint.isNullOrEmpty()) "&login_hint=${enc(loginHint)}" else ""
        val url = "$apiBase/auth/${provider.apiSegment}/authorize" +
            "?redirect_uri=${enc(redirect)}&state=${enc(state)}" +
            "&code_challenge=${enc(challenge)}&code_challenge_method=S256$hint"
        val obj = JSONObject(httpGet(url))
        return obj.getString("auth_url") to redirect
    }

    private fun complete(provider: OAuthProvider, code: String, redirectUri: String, verifier: String): ConnectedTokens {
        val body = JSONObject().put("code", code).put("redirect_uri", redirectUri).put("code_verifier", verifier).toString()
        val resp = JSONObject(httpPostJson("$apiBase/auth/${provider.apiSegment}/token", body))
        val access = resp.getString("access_token")
        val refresh = resp.optString("refresh_token").ifEmpty { null }
        val email = fetchEmail(provider, access)
        return ConnectedTokens(email, access, refresh)
    }

    private fun fetchEmail(provider: OAuthProvider, accessToken: String): String {
        val url = if (provider == OAuthProvider.GOOGLE)
            "https://www.googleapis.com/oauth2/v3/userinfo"
        else "https://graph.microsoft.com/v1.0/me"
        val obj = JSONObject(httpGet(url, bearer = accessToken))
        return obj.optString("email").ifEmpty { obj.optString("mail").ifEmpty { obj.optString("userPrincipalName") } }
            .also { require(it.isNotEmpty()) { "Couldn't read the account email." } }
    }

    /** Read the single redirect line off the loopback socket; return a tiny success page. */
    private fun awaitCallback(server: ServerSocket): Pair<String, String> {
        server.accept().use { conn ->
            val reader = conn.getInputStream().bufferedReader()
            val firstLine = reader.readLine() ?: ""           // "GET /oauth-callback?code=…&state=… HTTP/1.1"
            val path = firstLine.split(" ").getOrNull(1) ?: ""
            val page = "<html><body style='font:16px -apple-system,Roboto;text-align:center;padding:40px'>You're signed in. Return to inbox2.</body></html>"
            conn.getOutputStream().bufferedWriter().apply {
                write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ${page.toByteArray().size}\r\nConnection: close\r\n\r\n$page")
                flush()
            }
            val query = Uri.parse("http://127.0.0.1$path")
            val code = query.getQueryParameter("code") ?: throw IllegalStateException(query.getQueryParameter("error") ?: "No code")
            return code to (query.getQueryParameter("state") ?: "")
        }
    }

    // ── tiny HTTP helpers ────────────────────────────────────────────────────
    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    private fun httpGet(url: String, bearer: String? = null): String {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            instanceFollowRedirects = false   // never replay the bearer across a redirect
            bearer?.let { setRequestProperty("Authorization", "Bearer $it") }
        }
        return c.readBodyOrThrow()
    }

    private fun httpPostJson(url: String, json: String): String {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            instanceFollowRedirects = false   // never replay the OAuth code/token across a redirect
            setRequestProperty("Content-Type", "application/json")
            outputStream.use { it.write(json.toByteArray()) }
        }
        return c.readBodyOrThrow()
    }

    private fun HttpURLConnection.readBodyOrThrow(): String {
        val ok = responseCode in 200..299
        val stream = if (ok) inputStream else errorStream
        val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
        if (!ok) throw IllegalStateException("HTTP $responseCode: ${body.take(200)}")
        return body
    }
}
