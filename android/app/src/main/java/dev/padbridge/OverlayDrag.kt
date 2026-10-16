package dev.padbridge

import kotlin.math.hypot

/** Keep the badge above the finger after crossing the drag threshold. */
class OverlayDrag(private val downX: Float, private val downY: Float, private val startX: Float, private val startY: Float, private val slop: Float, private val lift: Float) {
    var dragged = false
        private set
    fun move(pointerX: Float, pointerY: Float, maximumY: Float = Float.POSITIVE_INFINITY): Pair<Float, Float>? {
        val dx = pointerX - downX; val dy = pointerY - downY
        if (hypot(dx, dy) > slop) dragged = true
        val targetY = startY + dy
        // Fade out the finger clearance near the bottom, keeping every edge reachable.
        val clearance = lift * ((maximumY - targetY) / (lift * 2).coerceAtLeast(1f)).coerceIn(0f, 1f)
        return if (dragged) startX + dx to targetY - clearance else null
    }
}
