package dev.padbridge

/** Wire values are explicit; unknown colors must never silently become SDR. */
enum class VideoColor(val wire: String, val title: String, val bitDepth: Int) {
    SDR("bt709-limited-sdr", "SDR · BT.709", 8),
    HLG("bt2020-limited-hlg10", "HDR · HLG 10-bit", 10);

    companion object {
        fun negotiate(value: String, codec: String, hlgSupported: Boolean): VideoColor {
            val color = entries.firstOrNull { it.wire == value } ?: error("Unsupported color mode")
            require(codec == "hevc" || codec == "h264") { "Unsupported codec" }
            require(color != HLG || (codec == "hevc" && hlgSupported)) { "HDR requires an HLG display and hardware HEVC Main10 decoding" }
            return color
        }
    }
}
