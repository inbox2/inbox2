package com.inbox2.app.cloud

import com.inbox2.app.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar

/**
 * Fetches the short, ready-to-speak weather line for the Bridge morning brief from the
 * inbox2 API (`GET /weather`, IP-based, unauthenticated) — the Android counterpart to
 * iOS WeatherService. Fully best-effort: any failure (offline, non-morning) yields null
 * and the brief simply omits the line. Only hits the network in the morning.
 */
object WeatherService {
    private const val TIMEOUT_MS = 5000

    /** The weather line to append to a brief, or null outside morning (local hour < 12,
     *  matching the core's brief window) or on any failure. */
    suspend fun morningLine(): String? {
        if (Calendar.getInstance().get(Calendar.HOUR_OF_DAY) >= 12) return null
        return fetch()
    }

    private suspend fun fetch(): String? = withContext(Dispatchers.IO) {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL("${AppConfig.apiBase}/weather").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Accept", "application/json")
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
            }
            if (conn.responseCode != 200) return@withContext null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            JSONObject(body).optString("short").takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }
}
