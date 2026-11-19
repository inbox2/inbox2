package com.inbox2.app.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.inbox2.app.R

// Type scale, spacing, and radii ported from iOS Theme.swift (AppFont / Space / Radius).
// iOS uses SF Pro; Android leads with the platform sans (Roboto / device default) at the
// same point sizes + weights so the rhythm matches — or, under the Atelier/Soirée
// themes, Jost for UI text and Bodoni Moda for the title tier; under Groovebox, Figtree
// + Rubik (all SIL OFL variable TTFs, in res/font). `mono` is the monospaced face for code/IDs/
// the `mx` brand token.

object AppFont {
    /** The luxury face set is live. Flipped by ThemeManager; a Compose state so every
     *  style getter below recomposes its readers on the switch. */
    var luxe by mutableStateOf(false)
    /** The Groovebox face set (Figtree UI, Rubik titles) + its rounder [Radius] scale. */
    var groovebox by mutableStateOf(false)

    @OptIn(androidx.compose.ui.text.ExperimentalTextApi::class)
    private fun variable(res: Int, weights: List<Int>) = FontFamily(weights.map { w ->
        Font(res, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))
    })
    private val jost by lazy { variable(R.font.jost, listOf(400, 500, 600, 700)) }
    private val bodoni by lazy { variable(R.font.bodoni_moda, listOf(400, 500, 600)) }
    private val figtree by lazy { variable(R.font.figtree, listOf(400, 500, 600, 700)) }
    private val rubik by lazy { variable(R.font.rubik, listOf(500, 600, 700)) }

    fun ui(size: Int, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size.sp, fontWeight = weight, fontFamily = if (luxe) jost else if (groovebox) figtree else null)

    /** Title tier: the high-contrast serif under the luxury themes, Rubik bold under
     *  Groovebox (web --display-weight 700), else `ui` semibold. */
    private fun heading(size: Int) =
        if (luxe) TextStyle(fontSize = size.sp, fontWeight = FontWeight.Medium, fontFamily = bodoni)
        else if (groovebox) TextStyle(fontSize = size.sp, fontWeight = FontWeight.Bold, fontFamily = rubik)
        else ui(size, FontWeight.SemiBold)

    /** Small section labels: Rubik under Groovebox, else `ui` semibold. */
    fun label(size: Int) =
        if (groovebox) TextStyle(fontSize = size.sp, fontWeight = FontWeight.SemiBold, fontFamily = rubik)
        else ui(size, FontWeight.SemiBold)

    fun mono(size: Int = 12, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size.sp, fontWeight = weight, fontFamily = FontFamily.Monospace)

    val display get() = heading(26)                 // onboarding/empty-state hero
    val title get() = heading(22)                   // screen + section titles
    val title2 get() = ui(19, FontWeight.SemiBold)  // sub-headers, prominent nav/bulk icons
    val title3 get() = ui(17, FontWeight.SemiBold)  // row headers, back chevron
    val xl get() = heading(20)
    val lg get() = ui(18, FontWeight.SemiBold)
    val body get() = ui(17)                         // default body — settings rows, list detail
    val md get() = ui(16, FontWeight.Medium)
    val base get() = ui(15)
    val sm get() = ui(14)
    val xs get() = ui(13)
    val xs2 get() = ui(12)
    val xs3 get() = ui(11, FontWeight.Medium)
}

/**
 * The product label "inbox2 mx" with the `mx` run in a monospaced (code) face — iOS
 * AttributedString.inbox2mx. Other runs inherit the host Text's style.
 */
fun inbox2mxAnnotated(text: String = "inbox2 mx"): androidx.compose.ui.text.AnnotatedString {
    val i = text.lowercase().indexOf("mx")
    return androidx.compose.ui.text.buildAnnotatedString {
        if (i < 0) { append(text); return@buildAnnotatedString }
        append(text.substring(0, i))
        pushStyle(androidx.compose.ui.text.SpanStyle(fontFamily = FontFamily.Monospace))
        append(text.substring(i, i + 2))
        pop()
        append(text.substring(i + 2))
    }
}

object Space {
    val s1 = 4.dp
    val s2 = 8.dp
    val s3 = 12.dp
    val s4 = 16.dp
    val s5 = 20.dp
    val s6 = 24.dp
    val s8 = 32.dp
}

/** Corner radii. Groovebox runs rounder, toy-like corners (web tokens 6/9/14/20). */
object Radius {
    val xs = 2.dp
    val sm get() = if (AppFont.groovebox) 6.dp else 3.dp
    val md get() = if (AppFont.groovebox) 9.dp else 5.dp
    val lg get() = if (AppFont.groovebox) 14.dp else 8.dp
    val xl get() = if (AppFont.groovebox) 20.dp else 12.dp
    val full = 9999.dp
}
