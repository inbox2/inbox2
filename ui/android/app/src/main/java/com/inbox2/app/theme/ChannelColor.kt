package com.inbox2.app.theme

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Deterministic per-channel colors, ported 1:1 from iOS ChannelColor.swift. Keyed by
// account key so a mailbox renders the same hue everywhere (agenda strip, month dots,
// load chart). Opens on a BMW-style electric blue and fans across distinct hues; each
// entry is a gradient (lighter top → deeper bottom) for the Vista-Aero beveled feel.
object ChannelColor {
    val electricBlue = colorHex("4DA6FF")
    val electricBlueDeep = colorHex("0A63E6")
    val violet = colorHex("A78BFF")
    val violetDeep = colorHex("6A3FE0")
    val amber = colorHex("FFB35C")              // also the triage toast accent
    val amberDeep = colorHex("F0822E")
    val coral = colorHex("FF7A6B")              // also the destructive toast accent
    val coralDeep = colorHex("E0463F")
    /** The Bridge orb's lower-right terminator shade (deep navy, drawn at 80%). */
    val orbShadow = colorHex("081026")

    /** Named gradient pairs — single source so chrome/toasts reference these rather
     *  than re-typing the hexes (mirrors iOS ChannelColor). */
    val amberGradient = listOf(amber, amberDeep)
    val coralGradient = listOf(coral, coralDeep)
    /** Settings-tab steel accent (iOS MobileChrome.NavStyle steel). */
    val steel = listOf(colorHex("EAEEF4"), colorHex("9AA2AE"))

    val gradients: List<List<Color>> = listOf(
        listOf(electricBlue, electricBlueDeep),
        listOf(colorHex("32E0C4"), colorHex("0FA48C")),
        listOf(violet, violetDeep),
        listOf(colorHex("FF74B8"), colorHex("E03F92")),
        amberGradient,
        listOf(colorHex("5FD98A"), colorHex("2FA85E")),
        coralGradient,
        listOf(colorHex("6E8BFF"), colorHex("3F52E0")),
    )

    /** Palette index — by position in `order` (connected-account list), else FNV-1a hash. */
    fun index(key: String, order: List<String> = emptyList()): Int {
        val i = order.indexOf(key)
        if (i >= 0) return i % gradients.size
        if (key.isEmpty()) return 0
        var h = 0xcbf29ce484222325uL
        for (b in key.encodeToByteArray()) {
            h = (h xor b.toUByte().toULong()) * 0x100000001b3uL
        }
        return (h % gradients.size.toULong()).toInt()
    }

    fun stops(key: String, order: List<String> = emptyList()): List<Color> =
        gradients[index(key, order)]

    /** Top → bottom gradient for bars and the event accent strip. */
    fun gradient(key: String, order: List<String> = emptyList()): Brush =
        Brush.linearGradient(
            colors = stops(key, order),
            start = Offset.Zero,
            end = Offset(0f, Float.POSITIVE_INFINITY),
        )

    /** Single representative color (lighter top stop) for dots/small marks. */
    fun base(key: String, order: List<String> = emptyList()): Color =
        stops(key, order).first()
}
