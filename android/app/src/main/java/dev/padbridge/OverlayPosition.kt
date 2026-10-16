package dev.padbridge

/** Positions are fractions of the available travel, so rotation and font changes stay in bounds. */
data class OverlayPosition(val x: Float, val y: Float) {
    fun pixels(parentWidth: Int, parentHeight: Int, width: Int, height: Int): Pair<Float, Float> =
        clean(x) * (parentWidth - width).coerceAtLeast(0) to clean(y) * (parentHeight - height).coerceAtLeast(0)
    companion object {
        private fun clean(value: Float) = if (value.isFinite()) value.coerceIn(0f, 1f) else 0f
        fun fromPixels(x: Float, y: Float, parentWidth: Int, parentHeight: Int, width: Int, height: Int) =
            OverlayPosition(clean(x / (parentWidth - width).coerceAtLeast(1)), clean(y / (parentHeight - height).coerceAtLeast(1)))
    }
}
