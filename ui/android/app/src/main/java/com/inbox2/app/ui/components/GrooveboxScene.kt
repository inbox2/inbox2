package com.inbox2.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.foundation.background
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import com.inbox2.app.theme.GrooveStyle
import com.inbox2.app.theme.colorHex
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.tan

// The Groovebox guidebook scene — a port of web lib/groovebox.js (buildGroovebox +
// drawGroovebox): charcoal ground, violet iso-grid, outlined pastel objects parked at
// the edges. `progress` in [0, 1]: the grid fades up over the first 40%, then the
// objects appear one after another. Layout runs in dp so a phone matches web's
// phone-width scene (unit floors at 0.6).

private val INK = colorHex("f3f0ea")
private val CORAL = colorHex("f2785c")
private val MUSTARD = colorHex("f0b545")
private val TEAL = colorHex("44c2b3")
private val LAVENDER = colorHex("a68cf0")
private val PINK = colorHex("f0a3bd")

private sealed interface Shape {
    val color: Color
    data class Arc(val x: Float, val y: Float, val r: Float, override val color: Color) : Shape
    data class Dial(val x: Float, val y: Float, val r: Float, override val color: Color) : Shape
    data class Pyramid(val x: Float, val y: Float, val s: Float, override val color: Color) : Shape
    data class Key(val x: Float, val y: Float, val s: Float, override val color: Color) : Shape
    data class Pom(val x: Float, val y: Float, val r: Float, override val color: Color) : Shape
}

/** buildGroovebox(w, h) in px, with `u` already scaled by density. */
private fun build(w: Float, h: Float, density: Float): Pair<Float, List<Shape>> {
    val u = max(0.6f, min(w, h) / density / 900f) * density
    val shapes = mutableListOf<Shape>()
    listOf(CORAL, MUSTARD, TEAL, LAVENDER).forEachIndexed { i, c ->
        shapes += Shape.Arc(-20 * u, h + 20 * u, (300 - i * 34) * u, c)
    }
    shapes += Shape.Dial(120 * u, 110 * u, 70 * u, LAVENDER)
    shapes += Shape.Pyramid(w - 150 * u, 150 * u, 120 * u, CORAL)
    shapes += Shape.Pyramid(w - 60 * u, 200 * u, 90 * u, MUSTARD)
    shapes += Shape.Key(w - 140 * u, h * 0.52f, 92 * u, TEAL)
    shapes += Shape.Key(w - 110 * u, h * 0.52f + 120 * u, 92 * u, MUSTARD)
    shapes += Shape.Key(w - 230 * u, h - 120 * u, 92 * u, INK)
    listOf(
        Triple(0.32f, 0.96f, CORAL), Triple(0.55f, 0.985f, LAVENDER), Triple(0.74f, 0.93f, TEAL),
        Triple(0.42f, 0.04f, PINK), Triple(0.63f, 0.025f, MUSTARD), Triple(0.88f, 0.97f, PINK),
    ).forEach { (fx, fy, c) -> shapes += Shape.Pom(w * fx, h * fy, 9 * u, c) }
    return u to shapes
}

private fun DrawScope.grid(line: Color, alpha: Float) {
    val cellW = 64f * density
    val cellH = cellW * tan(PI / 6).toFloat()
    val slope = cellH / cellW
    val w = size.width
    val h = size.height
    val span = w * slope + h
    val stroke = 1.5f * density
    var c = -span
    while (c <= span + h) {
        drawLine(line, Offset(0f, c), Offset(w, c + w * slope), stroke, alpha = alpha)
        drawLine(line, Offset(0f, c), Offset(w, c - w * slope), stroke, alpha = alpha)
        c += cellH
    }
}

private fun DrawScope.shape(s: Shape, u: Float, a: Float) {
    val stroke = Stroke(3 * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
    when (s) {
        is Shape.Arc -> drawArc(s.color, -90f, 90f, false, Offset(s.x - s.r, s.y - s.r), Size(2 * s.r, 2 * s.r), a, stroke)
        is Shape.Dial -> {
            drawCircle(s.color, s.r, Offset(s.x, s.y), a, stroke)
            val r = s.r * 0.36f
            val cx = s.x + s.r * 0.12f
            val cy = s.y - s.r * 0.2f
            drawArc(s.color, 135f, 243f, false, Offset(cx - r, cy - r), Size(2 * r, 2 * r), a, stroke)
        }
        is Shape.Pyramid -> drawPath(Path().apply {
            moveTo(s.x - s.s * 0.6f, s.y); lineTo(s.x, s.y - s.s); lineTo(s.x + s.s * 0.6f, s.y); close()
            moveTo(s.x, s.y - s.s); lineTo(s.x + s.s * 0.12f, s.y)
        }, s.color, a, stroke)
        is Shape.Key -> {
            val k = s.s
            val cr = CornerRadius(20 * u)
            val cap = Size(k, k * 0.82f)
            drawRoundRect(s.color, Offset(s.x + 8 * u, s.y - 8 * u), cap, cr, stroke, a * 0.5f) // skirt
            drawRoundRect(s.color, Offset(s.x, s.y), cap, cr, stroke, a)
            drawRoundRect(INK, Offset(s.x + k * 0.3f, s.y + k * 0.16f), Size(k * 0.38f, k * 0.2f), CornerRadius(k * 0.1f), stroke, a)
        }
        is Shape.Pom -> drawCircle(s.color, s.r, Offset(s.x, s.y), a)
    }
}

/** drawGroovebox(ctx, scene, p): the whole scene at progress [p]. */
fun DrawScope.drawGroovebox(g: GrooveStyle, p: Float = 1f, gridLine: Color = g.grid) {
    val (u, shapes) = build(size.width, size.height, density)
    drawRect(g.ground)
    grid(gridLine, min(1f, p / 0.4f))
    val t = max(0f, (p - 0.3f) / 0.7f) * shapes.size
    shapes.forEachIndexed { i, s ->
        val a = (t - i).coerceIn(0f, 1f)
        if (a > 0f) shape(s, u, a)
    }
}

/** The guidebook scene at [progress] (1 = fully drawn). `progress` is read in the draw
 *  phase, so animating it redraws without recomposing. */
@Composable
fun GrooveboxScene(g: GrooveStyle, progress: () -> Float, modifier: Modifier = Modifier) {
    // ponytail: layout rebuilt per frame — 17 shapes, cheaper than caching it.
    Canvas(modifier) { drawGroovebox(g, progress()) }
}

/** A page ground: the finished guidebook scene under Groovebox, else plain `bgBase`. */
@Composable
fun Modifier.pageGround(): Modifier {
    val p = com.inbox2.app.theme.theme
    val g = p.groove ?: return background(p.bgBase)
    return drawBehind { drawGroovebox(g, gridLine = g.pageGrid) }
}
