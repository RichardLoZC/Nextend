package dev.padbridge

import kotlin.math.abs
import kotlin.math.hypot

data class TouchPoint(val id: Int, val x: Float, val y: Float)
data class TouchCommand(val phase: String, val x: Double = 0.0, val y: Double = 0.0, val dx: Double = 0.0, val dy: Double = 0.0)
data class TouchMode(val enabled: Boolean, val epoch: Int, val width: Int, val height: Int, val trackpad: Boolean = false)

/** One completed tap may arm the next contact for tap-and-drag. */
class TouchTapHistory(private val timeout: Long, private val distance: Float) {
    private var last: Pair<TouchPoint, Long>? = null
    fun clear() { last = null }
    fun remember(point: TouchPoint, time: Long) {
        last = if (point.x.isFinite() && point.y.isFinite()) point to time else null
    }
    fun consume(point: TouchPoint, time: Long): Boolean {
        val previous = last; clear()
        return previous != null && time - previous.second in 0..timeout &&
            hypot(point.x - previous.first.x, point.y - previous.first.y) <= distance
    }
}

/** Coordinates use the same complete Surface as MediaCodec SCALE_TO_FIT. */
class TouchViewport(viewWidth: Int, viewHeight: Int) {
    val width = viewWidth.toDouble()
    val height = viewHeight.toDouble()
    fun point(x: Float, y: Float, clamp: Boolean = false): Pair<Double, Double>? {
        if (width <= 0 || height <= 0 || !x.isFinite() || !y.isFinite()) return null
        val nx = x / width; val ny = y / height
        if (!clamp && (nx !in 0.0..1.0 || ny !in 0.0..1.0)) return null
        return nx.coerceIn(0.0, 1.0) to ny.coerceIn(0.0, 1.0)
    }
}

/** A contact-count change ends the previous action. Once any finger lifts,
 * all remaining contacts are inert until UP; no accidental click or drag. */
class TouchGesture(private val viewport: TouchViewport, private val slop: Float,
                   private val emit: (TouchCommand) -> Unit, private val trackpad: Boolean = false,
                   private val tapDrag: Boolean = false, private val completedTap: (TouchPoint, Long) -> Unit = { _, _ -> }) {
    enum class Action { DOWN, POINTER_DOWN, MOVE, POINTER_UP, UP, CANCEL }
    private var first: TouchPoint? = null
    private var count = 0
    private var started = 0L
    private var lifted = false
    private var moved = false
    private var held = false
    private var actionKind = ""
    private var origin = 0f to 0f
    private var previous = origin
    private var initialSpread = 0.0
    private var zoomAnchor = 0.0
    private var lastZoom = 0L
    private val starts = mutableMapOf<Int, TouchPoint>()
    fun cancel() {
        if (held || (trackpad && first != null)) emit(TouchCommand("cancel"))
        first = null; count = 0; held = false; lifted = false; moved = false; actionKind = ""; starts.clear()
    }
    private fun send(phase: String, p: Pair<Float, Float>, from: Pair<Float, Float> = p) {
        viewport.point(p.first, p.second, true)?.let {
            emit(TouchCommand(phase, it.first, it.second,
                ((p.first - from.first) / viewport.width).coerceIn(-1.0, 1.0),
                ((p.second - from.second) / viewport.height).coerceIn(-1.0, 1.0)))
        }
    }
    fun accept(action: Action, points: List<TouchPoint>, changedID: Int, time: Long) {
        if (action == Action.CANCEL) { cancel(); return }
        if (points.isEmpty() || points.any { !it.x.isFinite() || !it.y.isFinite() }) { cancel(); return }
        if (action == Action.DOWN) {
            cancel(); val p = points.first()
            if (viewport.point(p.x, p.y) == null) return
            if (trackpad) send("begin", p.x to p.y)
            starts[p.id] = p
            first = p; count = 1; started = time; origin = p.x to p.y; previous = origin
            return
        }
        val firstPoint = first ?: return
        if (action == Action.POINTER_DOWN) {
            if (held) { emit(TouchCommand("cancel")); held = false }
            if (lifted) return
            points.forEach { starts.putIfAbsent(it.id, it) }
            count = points.size; origin = centroid(points); previous = origin; actionKind = ""
            initialSpread = spread(points); zoomAnchor = initialSpread
            return
        }
        if (action == Action.POINTER_UP) {
            if (held) { send("up", previous); held = false }
            lifted = true; return
        }
        if (!lifted && (action == Action.MOVE || action == Action.UP)) {
            val center = if (count == 1) {
                val p = points.firstOrNull { it.id == firstPoint.id } ?: run { cancel(); return }
                p.x to p.y
            } else centroid(points)
            val distance = hypot(center.first - origin.first, center.second - origin.second)
            if (distance > slop || points.any { p -> starts[p.id]?.let { hypot(p.x - it.x, p.y - it.y) > slop } == true }) moved = true
            when {
                count == 1 && trackpad -> if (moved) {
                    if (tapDrag && !held) { send("down", origin); held = true }
                    send(if (held) "move" else "hover", center, previous)
                }
                count == 1 -> {
                    if (!held && moved) { send("down", origin); held = true }
                    if (held) send("move", center)
                }
                count == 2 && points.size == 2 -> {
                    val span = spread(points)
                    if (actionKind.isEmpty()) {
                        if (trackpad && abs(span - initialSpread) > slop * 2 && abs(span - initialSpread) > distance * 1.5) actionKind = "zoom"
                        else if (distance > slop) actionKind = "scroll"
                    }
                    if (actionKind == "scroll") send("scroll", center, previous)
                    if (actionKind == "zoom" && zoomAnchor > 0 && time - lastZoom >= 120) {
                        if (span / zoomAnchor > 1.12 || span / zoomAnchor < 0.89) {
                            send(if (span > zoomAnchor) "zoom-in" else "zoom-out", center)
                            zoomAnchor = span; lastZoom = time; moved = true
                        }
                    }
                }
                count == 3 && trackpad && points.size == 3 -> {
                    if (!held && distance > slop * 2) { send("down", origin); held = true }
                    if (held) send("move", center, previous)
                }
                count == 4 && trackpad && points.size == 4 && actionKind.isEmpty() && distance > slop * 8 -> {
                    val dx = center.first - origin.first; val dy = center.second - origin.second
                    actionKind = "swipe"
                    send(if (abs(dx) > abs(dy)) { if (dx > 0) "space-left" else "space-right" }
                        else { if (dy < 0) "mission-control" else "app-windows" }, center)
                }
            }
            previous = center
        }
        if (action == Action.UP) {
            if (held) { send("up", previous); held = false }
            else if (!moved && actionKind.isEmpty() && time - started <= 500) {
                if (count == 1) { send("click", origin); completedTap(firstPoint, time) }
                if (count == 2) send("rightclick", origin)
            }
            if (trackpad) send("end", previous)
            first = null; cancel()
        }
    }
    private fun centroid(points: List<TouchPoint>) = points.map { it.x }.average().toFloat() to points.map { it.y }.average().toFloat()
    private fun spread(points: List<TouchPoint>): Double = if (points.size == 2) hypot((points[0].x - points[1].x).toDouble(), (points[0].y - points[1].y).toDouble()) else 0.0
}
