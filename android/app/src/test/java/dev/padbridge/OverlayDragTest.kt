package dev.padbridge

import org.junit.Assert.*
import org.junit.Test

class OverlayDragTest {
    @Test fun tapDoesNotMoveOrLiftTheBadge() {
        val drag = OverlayDrag(80f, 50f, 60f, 40f, 8f, 60f)
        assertNull(drag.move(82f, 51f))
        assertFalse(drag.dragged)
    }
    @Test fun dragStaysAboveTheFingerAndDoesNotTurnIntoATap() {
        val drag = OverlayDrag(80f, 50f, 60f, 40f, 8f, 60f)
        assertEquals(460f to 280f, drag.move(480f, 350f))
        assertTrue(drag.dragged)
        // Moving back to the start still completes a drag, never a menu click.
        assertEquals(60f to -20f, drag.move(80f, 50f))
        assertTrue(drag.dragged)
    }
    @Test fun releaseCoordinatesCanCompleteADragWithoutMoveEvents() {
        val drag = OverlayDrag(0f, 0f, 100f, 100f, 8f, 40f)
        assertEquals(300f to 260f, drag.move(200f, 200f))
        assertEquals(OverlayPosition(1f, 1f), OverlayPosition.fromPixels(300f, 260f, 240, 200, 80, 40))
    }
    @Test fun fingerClearanceFadesSoTheBottomEdgeIsReachable() {
        val drag = OverlayDrag(80f, 50f, 60f, 40f, 8f, 60f)
        assertEquals(60f to 600f, drag.move(80f, 610f, 600f))
        assertEquals(60f to 510f, drag.move(80f, 550f, 600f))
    }
}
