package dev.padbridge

import org.junit.Assert.*
import org.junit.Test

class TouchGestureTest {
    private val sent = mutableListOf<TouchCommand>()
    private var menus = 0
    private val gesture = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) })
    private fun p(id: Int, x: Float = 400f, y: Float = 400f) = TouchPoint(id, x, y)
    private fun event(action: TouchGesture.Action, time: Long, vararg points: TouchPoint) = gesture.accept(action, points.toList(), points.lastOrNull()?.id ?: 0, time)

    @Test fun tapWaitsForReleaseAndUsesAbsoluteCoordinates() {
        event(TouchGesture.Action.DOWN, 0, p(9))
        assertTrue(sent.isEmpty())
        event(TouchGesture.Action.UP, 80, p(9, 402f, 403f))
        assertEquals(listOf(TouchCommand("click", .4, .4)), sent)
    }
    @Test fun dragHasBalancedButtonsAndKeepsItsPointerIdentity() {
        event(TouchGesture.Action.DOWN, 0, p(7))
        event(TouchGesture.Action.MOVE, 20, p(7, 800f, 900f))
        event(TouchGesture.Action.UP, 40, p(7, 1200f, 1100f))
        assertEquals(listOf("down", "move", "move", "up"), sent.map { it.phase })
        assertEquals(TouchCommand("down", .4, .4), sent.first())
        assertEquals(TouchCommand("up", 1.0, 1.0), sent.last())
    }
    @Test fun canceledDragNeverClicksAndANewDownReleasesOldDrag() {
        event(TouchGesture.Action.DOWN, 0, p(4)); event(TouchGesture.Action.MOVE, 20, p(4, 700f))
        event(TouchGesture.Action.DOWN, 30, p(5)); event(TouchGesture.Action.CANCEL, 40, p(5))
        assertEquals(listOf("down", "move", "cancel"), sent.map { it.phase })
    }
    @Test fun twoFingerScrollDoesNotClickAndDoesNotResumeOneFingerDrag() {
        event(TouchGesture.Action.DOWN, 0, p(7))
        event(TouchGesture.Action.POINTER_DOWN, 40, p(7), p(12, 600f))
        event(TouchGesture.Action.MOVE, 60, p(12, 600f, 500f), p(7, 400f, 500f))
        event(TouchGesture.Action.POINTER_UP, 80, p(12, 600f, 500f), p(7, 400f, 500f))
        event(TouchGesture.Action.MOVE, 100, p(12, 800f, 600f))
        event(TouchGesture.Action.UP, 120, p(12, 800f, 600f))
        assertEquals(1, sent.size); assertEquals("scroll", sent.single().phase)
        assertEquals(.1, sent.single().dy, .00001); assertEquals(0, menus)
    }
    @Test fun addingFingersDuringDragReleasesWithoutOpeningMenu() {
        event(TouchGesture.Action.DOWN, 0, p(1)); event(TouchGesture.Action.MOVE, 10, p(1, 450f))
        event(TouchGesture.Action.POINTER_DOWN, 20, p(1, 450f), p(2))
        event(TouchGesture.Action.POINTER_DOWN, 30, p(1, 450f), p(2), p(3))
        event(TouchGesture.Action.UP, 100, p(3))
        assertEquals("cancel", sent.last().phase); assertEquals(0, menus)
    }
    @Test fun surfaceAspectRatioMapsExactlyWithoutInventingLetterboxes() {
        val wide = TouchViewport(1600, 900)
        assertEquals(.5 to .5, wide.point(800f, 450f))
        assertEquals(0.0 to 0.0, wide.point(0f, 0f))
        assertEquals(1.0 to 1.0, wide.point(1600f, 900f))
        assertEquals(1.0 to 1.0, wide.point(1800f, 1200f, true))
        val tall = TouchViewport(900, 1600)
        assertEquals(0.0 to 0.0, tall.point(0f, 0f))
        assertEquals(1.0 to 1.0, tall.point(900f, 1600f))
        assertNull(TouchViewport(0, 0).point(0f, 0f))
    }
    @Test fun downOutsideSurfaceNeverReachesDesktop() {
        val viewport = TouchViewport(1000, 1000)
        assertNull(viewport.point(Float.NaN, 400f)); assertNull(viewport.point(400f, Float.POSITIVE_INFINITY))
        gesture.accept(TouchGesture.Action.DOWN, listOf(p(3, -20f, 30f)), 3, 0)
        gesture.accept(TouchGesture.Action.UP, listOf(p(3)), 3, 80)
        assertTrue(sent.isEmpty())
    }
    @Test fun twoFingerTapIsRightClickAndNeverScrolls() {
        event(TouchGesture.Action.DOWN, 0, p(1))
        event(TouchGesture.Action.POINTER_DOWN, 20, p(1), p(2, 600f))
        event(TouchGesture.Action.POINTER_UP, 90, p(1), p(2, 600f))
        event(TouchGesture.Action.UP, 110, p(1))
        assertEquals(listOf(TouchCommand("rightclick", .5, .4)), sent)
    }
    @Test fun trackpadMovesRelativelyWithoutHoldingMouse() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(4)), 4, 0)
        g.accept(TouchGesture.Action.MOVE, listOf(p(4, 500f)), 4, 20)
        g.accept(TouchGesture.Action.UP, listOf(p(4, 500f)), 4, 40)
        assertTrue(sent.filter { it.phase !in listOf("begin", "end") }.all { it.phase == "hover" }); assertEquals(.1, sent.sumOf { it.dx }, .00001)
    }
    @Test fun threeFingerDragReleasesOnFirstLiftAndDoesNotResume() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 0)
        g.accept(TouchGesture.Action.POINTER_DOWN, listOf(p(1), p(2)), 2, 20)
        g.accept(TouchGesture.Action.POINTER_DOWN, listOf(p(1), p(2), p(3)), 3, 30)
        g.accept(TouchGesture.Action.MOVE, listOf(p(1, 500f), p(2, 500f), p(3, 500f)), 1, 40)
        g.accept(TouchGesture.Action.POINTER_UP, listOf(p(1, 500f), p(2, 500f), p(3, 500f)), 3, 50)
        g.accept(TouchGesture.Action.MOVE, listOf(p(1, 700f), p(2, 700f)), 1, 60)
        g.accept(TouchGesture.Action.UP, listOf(p(1, 700f)), 1, 70)
        assertEquals(listOf("begin", "down", "move", "up", "end"), sent.map { it.phase })
        assertEquals(.1, sent[2].dx, .00001)
    }
    @Test fun fourFingerSwipeFiresOnlyOnce() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 0)
        for (n in 2..4) g.accept(TouchGesture.Action.POINTER_DOWN, (1..n).map { p(it) }, n, n * 10L)
        g.accept(TouchGesture.Action.MOVE, (1..4).map { p(it, 200f) }, 1, 60)
        g.accept(TouchGesture.Action.MOVE, (1..4).map { p(it, 100f) }, 1, 80)
        g.accept(TouchGesture.Action.UP, listOf(p(1, 100f)), 1, 100)
        assertEquals(listOf("begin", "space-right", "end"), sent.map { it.phase })
    }
    @Test fun systemCancelReleasesThreeFingerDrag() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 0)
        for (n in 2..3) g.accept(TouchGesture.Action.POINTER_DOWN, (1..n).map { p(it) }, n, n * 10L)
        g.accept(TouchGesture.Action.MOVE, (1..3).map { p(it, 500f) }, 1, 60)
        g.accept(TouchGesture.Action.CANCEL, (1..3).map { p(it) }, 1, 70)
        assertEquals(listOf("begin", "down", "move", "cancel"), sent.map { it.phase })
    }
    @Test fun oppositeFingerMotionIsNeverASecondaryTap() {
        event(TouchGesture.Action.DOWN, 0, p(1, 400f))
        event(TouchGesture.Action.POINTER_DOWN, 20, p(1, 400f), p(2, 600f))
        event(TouchGesture.Action.MOVE, 40, p(1, 300f), p(2, 700f))
        event(TouchGesture.Action.POINTER_UP, 80, p(1, 300f), p(2, 700f))
        event(TouchGesture.Action.UP, 100, p(1, 300f))
        assertTrue(sent.isEmpty())
    }
    @Test fun secondTapCanDragAndReleasesOnCancel() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true, tapDrag = true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 0)
        g.accept(TouchGesture.Action.MOVE, listOf(p(1, 500f)), 1, 200)
        g.accept(TouchGesture.Action.CANCEL, listOf(p(1, 500f)), 1, 400)
        assertEquals(listOf("begin", "down", "move", "cancel"), sent.map { it.phase })
        assertEquals(.1, sent[2].dx, .00001)
    }
    @Test fun secondStationaryTapStillClicksAndMultiTouchDoesNotBecomeTapDrag() {
        val g = TouchGesture(TouchViewport(1000, 1000), 8f, { sent.add(it) }, true, tapDrag = true)
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 0)
        g.accept(TouchGesture.Action.UP, listOf(p(1)), 1, 80)
        assertEquals(listOf("begin", "click", "end"), sent.map { it.phase })
        sent.clear()
        g.accept(TouchGesture.Action.DOWN, listOf(p(1)), 1, 200)
        g.accept(TouchGesture.Action.POINTER_DOWN, listOf(p(1), p(2)), 2, 220)
        g.accept(TouchGesture.Action.MOVE, listOf(p(1, 500f), p(2, 500f)), 1, 240)
        g.accept(TouchGesture.Action.POINTER_UP, listOf(p(1, 500f), p(2, 500f)), 2, 260)
        g.accept(TouchGesture.Action.UP, listOf(p(1, 500f)), 1, 280)
        assertEquals(listOf("begin", "scroll", "end"), sent.map { it.phase })
    }
    @Test fun tapDragNeedsARecentNearbyTapAndNeverSurvivesReset() {
        val history = TouchTapHistory(300, 60f)
        assertFalse(history.consume(p(1), 100))
        history.remember(p(1), 100); assertFalse(history.consume(p(1), 401))
        history.remember(p(1), 500); assertFalse(history.consume(p(1, 700f), 600))
        history.remember(p(1), 700); history.clear(); assertFalse(history.consume(p(1), 800))
        history.remember(p(1), 900); assertTrue(history.consume(p(2, 410f), 1000))
        assertFalse(history.consume(p(2, 410f), 1100))
    }
}
