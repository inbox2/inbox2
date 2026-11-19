package com.inbox2.app.theme

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Appearance preference (iOS ThemeManager.Appearance). */
enum class Appearance(val raw: String, val title: String) {
    SYSTEM("system", "System"), DARK("dark", "Dark"), LIGHT("light", "Light"),
    SOIREE("soiree", "Soirée"), ATELIER("atelier", "Atelier"), GROOVEBOX("groovebox", "Groovebox");
    /** The quiet-luxury pair — swaps AppFont to Jost + Bodoni Moda. */
    val isLuxe get() = this == SOIREE || this == ATELIER
    companion object { fun fromRaw(r: String?) = entries.firstOrNull { it.raw == r } ?: SYSTEM }
}

/**
 * Resolves + persists the appearance preference (iOS ThemeManager). Holds the choice in
 * a Compose state so the UI recomposes on change; `palette(systemDark)` resolves to the
 * dark/light ThemePalette (System follows the OS).
 */
class ThemeManager(context: Context) {
    private val app = context.applicationContext
    private val sp = context.applicationContext.getSharedPreferences("inbox2_theme", Context.MODE_PRIVATE)

    var appearance by mutableStateOf(Appearance.fromRaw(sp.getString("appearance", null)))
        private set

    init { applyFonts(appearance) }

    private fun applyFonts(a: Appearance) {
        AppFont.luxe = a.isLuxe
        AppFont.groovebox = a == Appearance.GROOVEBOX
    }

    fun set(a: Appearance) {
        // Moving INTO Groovebox brings its launcher icon along; only on the transition, so
        // a later manual icon pick sticks, and leaving Groovebox leaves the icon alone.
        if (a == Appearance.GROOVEBOX && appearance != Appearance.GROOVEBOX)
            AppIconOption.select(app, AppIconOption.GROOVEBOX)
        appearance = a
        applyFonts(a)
        sp.edit().putString("appearance", a.raw).apply()
    }

    fun palette(systemDark: Boolean): ThemePalette = when (appearance) {
        Appearance.DARK -> ThemePalette.Dark
        Appearance.LIGHT -> ThemePalette.Light
        Appearance.SOIREE -> ThemePalette.Soiree
        Appearance.ATELIER -> ThemePalette.Atelier
        Appearance.GROOVEBOX -> ThemePalette.Groovebox
        Appearance.SYSTEM -> if (systemDark) ThemePalette.Dark else ThemePalette.Light
    }
}
