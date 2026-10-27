package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class DisplayAreaTest {
    @Test fun topCutoutMovesTheWholeMenuBarWithoutCroppingOrStretching() {
        val rect = DisplayArea(enabled = true, top = 0.03).fit(3200, 2136, 3200, 2136)
        assertEquals(64, rect.top)
        assertTrue(rect.left >= 0 && rect.left + rect.width <= 3200)
        assertEquals(2136, rect.top + rect.height)
        assertTrue(abs(rect.width.toDouble() / rect.height - 3200.0 / 2136) < 0.001)
    }
    @Test fun oppositeMarginsAndDifferentAspectRatiosAlwaysKeepTheEntireDesktopInside() {
        for ((w, h) in listOf(3200 to 2136, 2400 to 1600, 1920 to 1080, 1024 to 768, 1 to 1)) {
            for ((vw, vh) in listOf(3200 to 2136, 1920 to 1080)) {
                val r = DisplayArea(true, .2, .2, .2, .2).fit(w, h, vw, vh)
                assertTrue(r.width > 0 && r.height > 0)
                assertTrue(r.left >= 0 && r.top >= 0)
                assertTrue(r.left + r.width <= w && r.top + r.height <= h)
                if (w > 1) assertTrue(abs(r.width.toDouble() / r.height - vw.toDouble() / vh) < 0.005)
            }
        }
    }
    @Test fun disablingAvoidanceRestoresTheOriginalFullPanelViewport() {
        val r = DisplayArea(false, .2, .2, .2, .2).fit(3200, 2136, 3200, 2136)
        assertEquals(DisplayArea.Rect(0, 0, 3200, 2136), r)
    }
    @Test fun unsafeMarginsAreRejectedBeforeTheyCanHideTheDesktop() {
        for (v in listOf(-.001, .201, Double.NaN, Double.POSITIVE_INFINITY)) {
            try { DisplayArea(top = v); fail("Accepted $v") } catch (_: IllegalArgumentException) {}
        }
    }
    @Test fun sideCutoutKeepsTopMenuVisibleAndUsesTheRemainingRectangle() {
        val r = DisplayArea(true, top = 0.0, left = .08).fit(2400, 1600, 3200, 2136)
        assertTrue(r.left >= 192); assertEquals(0, r.top)
        assertTrue(r.left + r.width <= 2400 && r.top + r.height <= 1600)
    }
}
