package dev.padbridge

import org.junit.Assert.*
import org.junit.Test

class VideoColorTest {
    @Test fun hdrRequiresBothCodecAndDisplaySupport() {
        assertEquals(VideoColor.HLG, VideoColor.negotiate("bt2020-limited-hlg10", "hevc", true))
        assertThrows(IllegalArgumentException::class.java) { VideoColor.negotiate("bt2020-limited-hlg10", "h264", true) }
        assertThrows(IllegalArgumentException::class.java) { VideoColor.negotiate("bt2020-limited-hlg10", "hevc", false) }
    }
    @Test fun oldSdrAndUnknownModeAreDistinct() {
        assertEquals(VideoColor.SDR, VideoColor.negotiate("bt709-limited-sdr", "h264", false))
        assertThrows(IllegalStateException::class.java) { VideoColor.negotiate("bt2020-pq", "hevc", true) }
    }
}
