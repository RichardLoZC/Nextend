package dev.padbridge

import org.junit.Assert.*
import org.junit.Test

class OverlayPositionTest {
    @Test fun draggingClampsToAllEdges() {
        assertEquals(OverlayPosition(0f, 1f), OverlayPosition.fromPixels(-100f, 5000f, 1000, 600, 100, 50))
        assertEquals(900f to 550f, OverlayPosition(1f, 1f).pixels(1000, 600, 100, 50))
    }
    @Test fun preservesRelativeLocationAfterResize() {
        val position = OverlayPosition.fromPixels(450f, 275f, 1000, 600, 100, 50)
        assertEquals(OverlayPosition(.5f, .5f), position)
        assertEquals(200f to 125f, position.pixels(600, 300, 200, 50))
    }
    @Test fun largeFontsAndInvalidPreferencesStayOnScreen() {
        assertEquals(0f to 0f, OverlayPosition(1f, 1f).pixels(100, 100, 120, 120))
        assertEquals(0f to 0f, OverlayPosition(Float.NaN, Float.POSITIVE_INFINITY).pixels(100, 100, 20, 20))
    }
}
