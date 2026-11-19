package com.inbox2.app.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Design tokens ported 1:1 from the iOS app's Theme.swift (itself adapted from the
// desktop tokens.css — Vista Aero atmosphere × violet mobile direction). Dark is the
// default; light mirrors the iOS light theme. Same hex values, same names, so the two
// clients render identically. See docs/iOS-App.md §6.

/** Parse "#rrggbb"/"rrggbb" → Color. */
fun colorHex(hex: String, alpha: Float = 1f): Color {
    val s = hex.removePrefix("#")
    val v = s.toLong(16)
    return Color(
        red = ((v shr 16) and 0xff) / 255f,
        green = ((v shr 8) and 0xff) / 255f,
        blue = (v and 0xff) / 255f,
        alpha = alpha,
    )
}

private fun rgb(r: Int, g: Int, b: Int, a: Float = 1f) =
    Color(r / 255f, g / 255f, b / 255f, a)

/** Always-white Aero edge highlight (web --bevel, iOS Color.bevel). Same in both themes. */
fun bevel(alpha: Float) = Color.White.copy(alpha = alpha)

/** Dimming backdrop (web --scrim, iOS Color.scrim). Always black, in both themes. */
fun scrim(alpha: Float) = Color.Black.copy(alpha = alpha)

/** The full color set for one theme — mirrors iOS `ThemePalette`. */
data class ThemePalette(
    // Surfaces
    val bgBase: Color,
    val bgPanel: Color,
    val bgSurface: Color,
    val bgRaised: Color,
    val bgElevated: Color,
    val bgInput: Color,
    // Text
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val textMuted: Color,
    val textLink: Color,
    val textSender: Color,
    val textWarm: Color,
    // Accents
    val accentViolet: Color,
    val accentPrimary: Color,
    val accentWarm: Color,
    val accentWarmBright: Color,
    val accentSuccess: Color,
    val accentWarning: Color,
    val accentDanger: Color,
    val accentPurple: Color,
    val accentAmber: Color,
    val accentTeal: Color,
    // Borders
    val borderDefault: Color,
    val borderSubtle: Color,
    val borderStrong: Color,
    // Status
    val statusOpen: Color,
    val statusPending: Color,
    val statusArchived: Color,
    val statusSnoozed: Color,
    val statusUrgent: Color,
    val statusAI: Color,
    // WebView email-reader CSS colors (hex strings — the reader needs CSS colors)
    val webBg: String,
    val webText: String,
    val webMuted: String,
    val webLink: String,
    val webQuoteBorder: String,
    val webStatusBg: String,
    val webStatusText: String,
    // Brand ring (violet → pink → amber)
    val ringColors: List<Color>,
    // Zone category palette (blue/amber/violet/green/rose/teal) — the API only ever
    // sends these keys; each theme picks shades that hold contrast on its surfaces.
    val zoneColors: Map<String, Color>,
    val isDark: Boolean,
    /** Label colour on a solid `accentViolet` fill. White except on Soirée's gold. */
    val onAccent: Color = Color.White,
    /** Fill for floating toasts/bars (`glowCapsule`) where the default — white on light,
     *  `bgElevated` on dark — lands too close to the page. Atelier/Soirée need it: their
     *  gold hairline can't carry the separation a vivid ring did. */
    val floatFill: Color? = null,
    // Log-level text colours (App logs panel; iOS status*Text).
    val statusDangerText: Color = Color(0xFFF87171),
    val statusWarnText: Color = Color(0xFFFACC15),
    val statusInfoText: Color = Color(0xFF60A5FA),
    val statusDebugText: Color = Color(0xFF6B7280),
    /** Groovebox's toy-synth treatments (keycaps, dome, LED, solid chips). Null on every
     *  other theme, which keeps their existing look. */
    val groove: GrooveStyle? = null,
) {
    /** A zone category's colour by palette key; unknown/null keys read as blue. */
    fun zone(key: String?): Color = zoneColors[key] ?: zoneColors.getValue("blue")

    /** Closed sweep gradient — the single source for avatar rings + the Bridge orb. */
    val ringGradient: Brush
        get() = Brush.sweepGradient(ringColors + ringColors.first())

    companion object {
        val Dark = ThemePalette(
            bgBase = colorHex("090a0e"),
            bgPanel = colorHex("0d0f15"),
            bgSurface = colorHex("15171f"),
            bgRaised = colorHex("1b1d25"),
            bgElevated = colorHex("1f212b"),
            bgInput = colorHex("06070c"),
            textPrimary = colorHex("e0e0e8"),
            textSecondary = colorHex("a0a0b0"),
            textTertiary = colorHex("707080"),
            textMuted = colorHex("4a4a58"),
            textLink = colorHex("a0a8b8"),
            textSender = colorHex("e8e8ee"),
            textWarm = colorHex("c8a070"),
            accentViolet = colorHex("7c5cfc"),
            accentPrimary = colorHex("a0a8b8"),
            accentWarm = rgb(27, 105, 212, 0.85f),
            accentWarmBright = rgb(40, 120, 230),
            accentSuccess = colorHex("7aaa8c"),
            accentWarning = colorHex("1B69D4"),
            accentDanger = colorHex("c48a88"),
            accentPurple = colorHex("a898c0"),
            accentAmber = colorHex("d0b468"),
            accentTeal = colorHex("78a8a0"),
            borderDefault = rgb(255, 255, 255, 0.06f),
            borderSubtle = rgb(255, 255, 255, 0.03f),
            borderStrong = rgb(255, 255, 255, 0.10f),
            statusOpen = colorHex("a0a8b8"),
            statusPending = colorHex("c8a060"),
            statusArchived = colorHex("585868"),
            statusSnoozed = colorHex("a898c0"),
            statusUrgent = colorHex("c48a88"),
            statusAI = colorHex("78a8a0"),
            webBg = "#0b0d12",
            webText = "#e0e0e8",
            webMuted = "#7b8494",
            webLink = "#5aa0ff",
            webQuoteBorder = "#2a2e38",
            webStatusBg = "#15171f",
            webStatusText = "#9aa3b2",
            ringColors = listOf(colorHex("a05cff"), colorHex("ff5ca8"), colorHex("ff9d5c")),
            zoneColors = mapOf(
                "blue" to colorHex("5b8def"), "amber" to colorHex("d9a441"), "violet" to colorHex("9a8cc0"),
                "green" to colorHex("6fb08a"), "rose" to colorHex("d98a9a"), "teal" to colorHex("5fb3b3"),
            ),
            isDark = true,
        )

        // Light ramp (iOS a4560ef6): native ink/accents over grouped surfaces — white
        // cards on #f2f2f7, white inputs carried by their border stroke.
        val Light = ThemePalette(
            bgBase = colorHex("f2f2f7"),
            bgPanel = colorHex("ffffff"),
            bgSurface = colorHex("f6f6f8"),
            bgRaised = colorHex("ffffff"),
            bgElevated = colorHex("ffffff"),
            bgInput = colorHex("ffffff"),
            textPrimary = colorHex("1d1d1f"),
            textSecondary = colorHex("3c3c43"),
            textTertiary = colorHex("6e6e73"),
            textMuted = colorHex("8e8e93"),
            textLink = colorHex("0069d9"),
            textSender = colorHex("000000"),
            textWarm = colorHex("b25000"),
            accentViolet = colorHex("6a3ff0"),
            accentPrimary = colorHex("0069d9"),
            accentWarm = rgb(0, 105, 217, 0.90f),
            accentWarmBright = colorHex("007aff"),
            accentSuccess = colorHex("248a3d"),
            accentWarning = colorHex("0069d9"),
            accentDanger = colorHex("d70015"),
            accentPurple = colorHex("8944ab"),
            accentAmber = colorHex("b25000"),
            accentTeal = colorHex("0b7f8c"),
            borderDefault = rgb(0, 0, 0, 0.11f),
            borderSubtle = rgb(0, 0, 0, 0.06f),
            borderStrong = rgb(0, 0, 0, 0.16f),
            statusOpen = colorHex("0069d9"),
            statusPending = colorHex("b25000"),
            statusArchived = colorHex("8e8e93"),
            statusSnoozed = colorHex("8944ab"),
            statusUrgent = colorHex("d70015"),
            statusAI = colorHex("0b7f8c"),
            webBg = "#ffffff",
            webText = "#1d1d1f",
            webMuted = "#6e6e73",
            webLink = "#0069d9",
            webQuoteBorder = "#d5d5da",
            webStatusBg = "#f2f2f7",
            webStatusText = "#6e6e73",
            ringColors = listOf(colorHex("8a3cf0"), colorHex("e0479a"), colorHex("f0894c")),
            zoneColors = mapOf(
                "blue" to colorHex("2f64d0"), "amber" to colorHex("a8701a"), "violet" to colorHex("6d5aa8"),
                "green" to colorHex("3d8a5f"), "rose" to colorHex("b8506a"), "teal" to colorHex("2a8585"),
            ),
            isDark = false,
            statusDangerText = colorHex("c0392b"), statusWarnText = colorHex("b07a00"),
            statusInfoText = colorHex("2563c8"), statusDebugText = colorHex("6b7280"),
        )

        // Atelier + Soirée — the quiet-luxury pair (iOS Theme.swift, web tokens.css
        // [data-theme-variant]). Ivory/cognac/gold by day, bottle green/champagne/gold
        // by night; `accentViolet` carries the theme accent and the ring turns brushed
        // gold. Both switch AppFont to Jost + Bodoni Moda.
        private val goldRing = listOf(colorHex("e7cf98"), colorHex("a97f3c"), colorHex("f1dfb4"), colorHex("b8914a"))

        val Atelier = ThemePalette(
            bgBase = colorHex("f5efe6"),
            bgPanel = colorHex("fffdf9"),
            bgSurface = colorHex("fbf8f3"),
            bgRaised = colorHex("fffdf9"),
            bgElevated = colorHex("fffdf9"),
            bgInput = colorHex("fffdf9"),
            textPrimary = colorHex("211b17"),
            textSecondary = colorHex("4a3f37"),
            textTertiary = colorHex("7a6d60"),
            textMuted = colorHex("9a8d80"),
            textLink = colorHex("8e4f28"),
            textSender = colorHex("1a1511"),
            textWarm = colorHex("9a7440"),
            accentViolet = colorHex("8e4f28"),
            accentPrimary = colorHex("8e4f28"),
            accentWarm = rgb(142, 79, 40, 0.92f),
            accentWarmBright = colorHex("9c5a31"),
            accentSuccess = colorHex("5e7a52"),
            accentWarning = colorHex("8e4f28"),
            accentDanger = colorHex("9c3b36"),
            accentPurple = colorHex("7b5b78"),
            accentAmber = colorHex("9a7440"),
            accentTeal = colorHex("4f7a6e"),
            borderDefault = rgb(90, 60, 30, 0.14f),
            borderSubtle = rgb(90, 60, 30, 0.08f),
            borderStrong = rgb(90, 60, 30, 0.20f),
            statusOpen = colorHex("8e4f28"),
            statusPending = colorHex("9a7440"),
            statusArchived = colorHex("9a8d80"),
            statusSnoozed = colorHex("7b5b78"),
            statusUrgent = colorHex("9c3b36"),
            statusAI = colorHex("4f7a6e"),
            webBg = "#fffdf9",
            webText = "#211b17",
            webMuted = "#7a6d60",
            webLink = "#8e4f28",
            webQuoteBorder = "#e4d9c8",
            webStatusBg = "#f5efe6",
            webStatusText = "#7a6d60",
            ringColors = goldRing,
            zoneColors = Light.zoneColors,
            isDark = false,
            floatFill = colorHex("e2d5bf"),
            statusDangerText = colorHex("9c3b36"), statusWarnText = colorHex("9a6a10"),
            statusInfoText = colorHex("4c5f86"), statusDebugText = colorHex("7a6d60"),
        )

        val Soiree = ThemePalette(
            bgBase = colorHex("0b110f"),
            bgPanel = colorHex("0e1512"),
            bgSurface = colorHex("141e19"),
            bgRaised = colorHex("17221d"),
            bgElevated = colorHex("1a2620"),
            bgInput = colorHex("060a08"),
            textPrimary = colorHex("efe7d7"),
            textSecondary = colorHex("b9ae98"),
            textTertiary = colorHex("8a8270"),
            textMuted = colorHex("5e594c"),
            textLink = colorHex("d9bd82"),
            textSender = colorHex("f4ede0"),
            textWarm = colorHex("d9ba78"),
            accentViolet = colorHex("c9a661"),
            accentPrimary = colorHex("c9a661"),
            accentWarm = rgb(201, 166, 97, 0.85f),
            accentWarmBright = colorHex("d9ba78"),
            accentSuccess = colorHex("7fa88a"),
            accentWarning = colorHex("c9a661"),
            accentDanger = colorHex("c98b84"),
            accentPurple = colorHex("a898c0"),
            accentAmber = colorHex("d0b468"),
            accentTeal = colorHex("7fa89c"),
            borderDefault = rgb(239, 231, 215, 0.07f),
            borderSubtle = rgb(239, 231, 215, 0.035f),
            borderStrong = rgb(201, 166, 97, 0.22f),
            statusOpen = colorHex("c9a661"),
            statusPending = colorHex("d0b468"),
            statusArchived = colorHex("5e594c"),
            statusSnoozed = colorHex("a898c0"),
            statusUrgent = colorHex("c98b84"),
            statusAI = colorHex("7fa89c"),
            webBg = "#0e1512",
            webText = "#efe7d7",
            webMuted = "#8a8270",
            webLink = "#d9bd82",
            webQuoteBorder = "#26332c",
            webStatusBg = "#141e19",
            webStatusText = "#b9ae98",
            ringColors = goldRing,
            zoneColors = Dark.zoneColors,
            isDark = true,
            onAccent = colorHex("1a140c"),
            floatFill = colorHex("283a31"),
            statusInfoText = colorHex("93c5fd"), statusDebugText = colorHex("8a8270"),
        )

        // Groovebox — a toy synth on a guidebook grid (web tokens.css
        // [data-theme-variant="groovebox"], lib/groovebox.js). Near-black islands, one
        // pastel per role: lavender primary, teal success/checked, mustard warning +
        // clock, coral danger, pink tags, LED-green unread. AppFont → Figtree + Rubik.
        val Groovebox = ThemePalette(
            bgBase = colorHex("0a0a0b"),
            bgPanel = colorHex("121214"),
            bgSurface = colorHex("121214"),
            bgRaised = colorHex("1b1b1f"),
            bgElevated = colorHex("222227"),
            bgInput = colorHex("1b1b1f"),
            textPrimary = colorHex("f3f0ea"),
            textSecondary = colorHex("b4b0b8"),
            textTertiary = colorHex("85818c"),
            // Web's muted is #5d5a63; on phone panels small text needs at least the tertiary ink.
            textMuted = colorHex("85818c"),
            textLink = colorHex("c4b2ff"),
            textSender = colorHex("f7f4ee"),
            textWarm = colorHex("f0b545"),
            accentViolet = colorHex("a68cf0"),
            accentPrimary = colorHex("a68cf0"),
            accentWarm = rgb(166, 140, 240, 0.9f),
            accentWarmBright = colorHex("c4b2ff"),
            accentSuccess = colorHex("44c2b3"),
            accentWarning = colorHex("f0b545"),
            accentDanger = colorHex("f2785c"),
            accentPurple = colorHex("a68cf0"),
            accentAmber = colorHex("f0b545"),
            accentTeal = colorHex("44c2b3"),
            borderDefault = rgb(243, 240, 234, 0.07f),
            borderSubtle = rgb(243, 240, 234, 0.035f),
            borderStrong = rgb(243, 240, 234, 0.12f),
            statusOpen = colorHex("a68cf0"),
            statusPending = colorHex("f0b545"),
            statusArchived = colorHex("85818c"),
            statusSnoozed = colorHex("f0a3bd"),
            statusUrgent = colorHex("f2785c"),
            statusAI = colorHex("44c2b3"),
            webBg = "#121214",
            webText = "#f3f0ea",
            webMuted = "#85818c",
            webLink = "#c4b2ff",
            webQuoteBorder = "#2a2a2e",
            webStatusBg = "#1b1b1f",
            webStatusText = "#b4b0b8",
            ringColors = listOf(colorHex("f2785c"), colorHex("f0b545"), colorHex("44c2b3"), colorHex("a68cf0")),
            zoneColors = mapOf(
                "blue" to colorHex("a68cf0"), "amber" to colorHex("f0b545"), "violet" to colorHex("c4b2ff"),
                "green" to colorHex("5fd68a"), "rose" to colorHex("f0a3bd"), "teal" to colorHex("44c2b3"),
            ),
            isDark = true,
            onAccent = colorHex("1a1424"),
            floatFill = colorHex("1f1f24"),
            groove = GrooveStyle(),
        )

        /** Light tile behind the dark inbox2 cube logo (unified avatar / logo tile). */
        val unifiedLogoTile = colorHex("f2f3f7")
    }
}

/** Groovebox treatments, hex-for-hex with web tokens.css. */
data class GrooveStyle(
    /** Unread dots + live state read as the synth's LEDs. */
    val led: Color = colorHex("5fd68a"),
    /** Selected/active tab: a cream keycap with a hard bottom edge and dark legend. */
    val creamKey: List<Color> = listOf(colorHex("f6f2e9"), colorHex("e4ded1")),
    val creamInk: Color = colorHex("1c1b1f"),
    val creamEdge: Color = colorHex("a9a192"),
    /** Secondary buttons: dark keycaps, 1dp white-9% top highlight. */
    val darkKey: List<Color> = listOf(colorHex("34343a"), colorHex("26262b")),
    val darkEdge: Color = colorHex("08080a"),
    val keyHighlight: Color = Color.White.copy(alpha = 0.09f),
    /** Primary action: the lavender dome (radial, lit from the upper left). */
    val dome: List<Color> = listOf(colorHex("d9ccff"), colorHex("a68cf0"), colorHex("8466e0")),
    val domeEdge: Color = colorHex("5a40a8"),
    val domeHighlight: Color = Color.White.copy(alpha = 0.45f),
    /** Selected list row: solid fill + lavender ring, no wash, no rail. */
    val rowSelected: Color = colorHex("262233"),
    val rowRing: Color = colorHex("a68cf0"),
    /** Chips/labels: solid pastel fill, dark ink, dark bottom shadow. */
    val chipInk: Color = colorHex("141416"),
    val chipShadow: Color = Color.Black.copy(alpha = 0.55f),
    /** The guidebook backdrop: charcoal ground + violet iso-grid (lib/groovebox.js). */
    val ground: Color = colorHex("2a2a2e"),
    val grid: Color = Color(148 / 255f, 121 / 255f, 216 / 255f, 0.42f),
    /** The grid behind app pages runs fainter than the launch scene's so panels read. */
    val pageGrid: Color = Color(148 / 255f, 121 / 255f, 216 / 255f, 0.22f),
    /** Rainbow nav tabs, in bar order: Inbox, Explorer, Compose, Calendar, Settings (iOS). */
    val navTabs: List<Color> = listOf(
        colorHex("f2785c"), colorHex("f0b545"), colorHex("44c2b3"), colorHex("a68cf0"), colorHex("f0a3bd"),
    ),
    /** Calendar hour lines and the current-time line (mustard, like the clock digits). */
    val timeGrid: Color = Color(148 / 255f, 121 / 255f, 216 / 255f, 0.25f),
    val nowLine: Color = colorHex("f0b545"),
    /** The pastel set event/chip colours snap to: lavender, teal, mustard, coral, pink, LED. */
    val pastels: List<Color> = listOf(
        colorHex("a68cf0"), colorHex("44c2b3"), colorHex("f0b545"),
        colorHex("f2785c"), colorHex("f0a3bd"), colorHex("5fd68a"),
    ),
) {
    /** The pastel nearest [c] by hue (greys read as lavender) — so a channel/calendar
     *  colour becomes a solid Groovebox block with dark ink. */
    fun pastel(c: Color): Color {
        val hsv = FloatArray(3)
        android.graphics.Color.RGBToHSV((c.red * 255).toInt(), (c.green * 255).toInt(), (c.blue * 255).toInt(), hsv)
        if (hsv[1] < 0.15f) return pastels[0]
        fun hue(x: Color) = FloatArray(3).also {
            android.graphics.Color.RGBToHSV((x.red * 255).toInt(), (x.green * 255).toInt(), (x.blue * 255).toInt(), it)
        }[0]
        return pastels.minBy { val d = kotlin.math.abs(hue(it) - hsv[0]); minOf(d, 360f - d) }
    }

    /** A stable pastel for a string key (recipient chips). With an [order] (the channel
     *  order) the key's position picks it, so neighbouring accounts never collide. */
    fun pastelFor(key: String, order: List<String> = emptyList()): Color {
        val i = order.indexOf(key)
        return pastels[if (i >= 0) i % pastels.size else Math.floorMod(key.lowercase().hashCode(), pastels.size)]
    }

    /** An event's pastel, varied per account (its channel-order slot) and per calendar
     *  (its colour shifts the slot) — snapping colours by hue sent every default-blue
     *  calendar to one lavender. Past events get the muted fill (45% into the ground). */
    fun eventFill(calendarHex: String?, accountKey: String, order: List<String>, past: Boolean): Color {
        val i = order.indexOf(accountKey).takeIf { it >= 0 } ?: Math.floorMod(accountKey.hashCode(), pastels.size)
        val shift = calendarHex?.let { Math.floorMod(it.lowercase().hashCode(), pastels.size) } ?: 0
        val c = pastels[(i + shift) % pastels.size]
        return if (past) androidx.compose.ui.graphics.lerp(ground, c, 0.45f) else c
    }
    /** Text on an event block: dark ink, or the secondary grey on a past (muted) block. */
    fun eventInk(past: Boolean): Color = if (past) colorHex("b4b0b8") else chipInk
}

val LocalTheme = staticCompositionLocalOf { ThemePalette.Dark }

/** Convenience accessor — `theme.accentViolet` inside any composable. */
val theme: ThemePalette
    @Composable get() = LocalTheme.current

@Composable
fun Inbox2Theme(palette: ThemePalette = ThemePalette.Dark, content: @Composable () -> Unit) {
    // Material components (DropdownMenu, dividers, sheets) read MaterialTheme —
    // not our palette — so derive the slots they use, or popups render on the
    // default light surface in dark mode (iOS context menus follow the system
    // appearance; this keeps Android's matching the app surfaces).
    val base = if (palette.isDark) androidx.compose.material3.darkColorScheme()
    else androidx.compose.material3.lightColorScheme()
    val scheme = base.copy(
        primary = palette.accentViolet,
        background = palette.bgBase,
        onBackground = palette.textPrimary,
        surface = palette.bgElevated,
        onSurface = palette.textPrimary,
        onSurfaceVariant = palette.textSecondary,
        surfaceContainer = palette.bgElevated,
        surfaceContainerLow = palette.bgRaised,
        surfaceContainerHigh = palette.bgElevated,
        outlineVariant = palette.borderDefault,
    )
    androidx.compose.material3.MaterialTheme(colorScheme = scheme) {
        CompositionLocalProvider(LocalTheme provides palette, content = content)
    }
}
