package dev.padbridge

import kotlin.math.roundToInt

/** Fractions refer to the current landscape window, independent of panel density. */
data class DisplayArea(val enabled: Boolean = false, val top: Double = 0.03, val right: Double = 0.0,
                       val bottom: Double = 0.0, val left: Double = 0.0) {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && it in 0.0..0.2 }) }
    data class Rect(val left: Int, val top: Int, val width: Int, val height: Int)
    fun fit(width: Int, height: Int, videoWidth: Int, videoHeight: Int): Rect {
        require(width > 0 && height > 0 && videoWidth > 0 && videoHeight > 0)
        val l = if (enabled) (left * width).roundToInt() else 0
        val t = if (enabled) (top * height).roundToInt() else 0
        val availableW = (width - l - if (enabled) (right * width).roundToInt() else 0).coerceAtLeast(1)
        val availableH = (height - t - if (enabled) (bottom * height).roundToInt() else 0).coerceAtLeast(1)
        val scale = minOf(availableW.toDouble() / videoWidth, availableH.toDouble() / videoHeight)
        val w = (videoWidth * scale).roundToInt().coerceIn(1, availableW)
        val h = (videoHeight * scale).roundToInt().coerceIn(1, availableH)
        // Pin the menu bar to the safe top edge. Any letterbox space stays below it.
        return Rect(l + (availableW - w) / 2, t + if (enabled) 0 else (availableH - h) / 2, w, h)
    }
}
