package com.inbox2.app

/**
 * Runtime configuration. The Rails base is used by the engine to refresh OAuth tokens
 * and by the inbox2 mx (domain/MX) REST client. Like iOS, the base includes `/api/v1`
 * (the engine, OAuth proxy, and image proxy all build paths on top of it). Default is
 * the hosted test deployment so the app works from anywhere with cloud push; point
 * `apiBase` at e.g. `http://10.0.2.2:4000/api/v1` (emulator → host loopback) to
 * develop against a local Rails.
 */
object AppConfig {
    const val DEFAULT_API_BASE = "https://api.inbox2.com/api/v1"
    /** Same key as iOS (`inbox2_cloud_api_base`); the sign-in screen's Advanced field. */
    private const val PREFS = "inbox2_config"
    private const val KEY_BASE = "inbox2_cloud_api_base"

    @Volatile
    var apiBase: String = DEFAULT_API_BASE
        private set

    /** Load the stored override before the engine boots (Inbox2App.onCreate) — the
     *  engine takes the base once at construction, the cloud client reads it per call. */
    fun load(context: android.content.Context) {
        apiBase = context.applicationContext.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
            .getString(KEY_BASE, null)?.trim()?.takeIf { it.startsWith("http") } ?: DEFAULT_API_BASE
    }

    /** Persist + apply an override; blank restores the default. Takes effect for the
     *  cloud client at once and for the engine on the next launch. */
    fun setApiBase(context: android.content.Context, value: String) {
        val v = value.trim().trimEnd('/')
        context.applicationContext.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
            .edit().putString(KEY_BASE, v.ifEmpty { null }).apply()
        apiBase = v.takeIf { it.startsWith("http") } ?: DEFAULT_API_BASE
    }
}
