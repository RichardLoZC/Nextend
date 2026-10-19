package dev.padbridge

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

data class VideoFrame(val sequence: Long, val keyframe: Boolean, val bytes: ByteArray, val receivedNS: Long)

/** One handler owns all codec operations. Both queued frames and codec input are bounded. */
class VideoDecoder(
    surface: Surface, mime: String, width: Int, height: Int, fps: Int, private val color: VideoColor,
    private val ack: (Long, Boolean, Double) -> Unit,
    private val presented: (Long, Double) -> Unit,
    private val requestKeyframe: () -> Unit,
    private val outputFormat: (Map<String, Int>) -> Unit,
    private val fail: (String) -> Unit
) : AutoCloseable {
    private val thread = HandlerThread("PadBridge-codec").also { it.start() }
    private val handler = Handler(thread.looper)
    private val pending = ArrayDeque<VideoFrame>()
    private val inputs = ArrayDeque<Int>()
    private val received = mutableMapOf<Long, Long>()
    private val presentationPending = linkedMapOf<Long, Long>()
    private val enqueued = AtomicInteger(0)
    @Volatile private var closed = false
    private var awaitingKeyframe = true
    private var lastRequest = 0L
    private var formatAccepted = color == VideoColor.SDR
    private val codec: MediaCodec
    val name: String
    init {
        val info = hardwareDecoder(mime, width, height, fps, color == VideoColor.HLG)
            ?: run { thread.quitSafely(); throw IllegalArgumentException("No hardware $mime decoder supports ${width}×${height} at $fps fps") }
        name = info.name
        codec = try { MediaCodec.createByCodecName(name) }
            catch (e: Exception) { thread.quitSafely(); throw e }
        try {
            val format = MediaFormat.createVideoFormat(mime, width, height)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, if (color == VideoColor.HLG) MediaFormat.COLOR_STANDARD_BT2020 else MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, if (color == VideoColor.HLG) MediaFormat.COLOR_TRANSFER_HLG else MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            if (color == VideoColor.HLG) format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10)
            if (info.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            codec.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(mc: MediaCodec, index: Int) { if (!closed) { inputs.add(index); pump() } }
                override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (!closed) runCatching {
                        if (!formatAccepted) { mc.releaseOutputBuffer(index, false); return }
                        val start = received.remove(info.presentationTimeUs)
                        if (start != null) {
                            presentationPending[info.presentationTimeUs] = start
                            // Render callbacks are optional telemetry and must not hold sender credit.
                            while (presentationPending.size > 240) presentationPending.remove(presentationPending.keys.first())
                        }
                        mc.releaseOutputBuffer(index, true)
                        if (start != null) ack(info.presentationTimeUs, true, (System.nanoTime() - start) / 1e6)
                    }.onFailure { fail("Decoder output failed: ${it.message}") }
                }
                override fun onError(mc: MediaCodec, error: MediaCodec.CodecException) { if (!closed) fail("Hardware decoder failed: ${error.diagnosticInfo}") }
                override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                    if (closed) return
                    android.util.Log.i("PadBridge", "decoder-format $format")
                    fun read(key: String) = if (format.containsKey(key)) format.getInteger(key) else -1
                    val values = listOf(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_TRANSFER,
                        MediaFormat.KEY_COLOR_RANGE, MediaFormat.KEY_PROFILE, MediaFormat.KEY_COLOR_FORMAT).associateWith { read(it) }
                    formatAccepted = color != VideoColor.HLG ||
                        (values[MediaFormat.KEY_COLOR_STANDARD] == MediaFormat.COLOR_STANDARD_BT2020 &&
                         values[MediaFormat.KEY_COLOR_TRANSFER] == MediaFormat.COLOR_TRANSFER_HLG &&
                         values[MediaFormat.KEY_COLOR_RANGE] == MediaFormat.COLOR_RANGE_LIMITED)
                    if (formatAccepted) outputFormat(values) else fail("HDR decoder color format mismatch; output stopped")
                }
            }, handler)
            codec.setOnFrameRenderedListener({ _, pts, _ ->
                if (!closed) presentationPending.remove(pts)?.let { start ->
                    // Clock this on arrival; vendor callback timestamps need not
                    // be useful for a cross-device photon-latency measurement.
                    presented(pts, (System.nanoTime() - start) / 1e6)
                }
            }, handler)
            codec.configure(format, surface, null, 0)
            codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            codec.start()
        } catch (e: Exception) { codec.release(); thread.quitSafely(); throw e }
    }
    fun submit(frame: VideoFrame) {
        if (closed) return
        if (enqueued.incrementAndGet() > 3) {
            enqueued.decrementAndGet()
            handler.post { if (!closed) { desync(); ack(frame.sequence, false, 0.0) } }
            return
        }
        handler.post {
            enqueued.decrementAndGet()
            if (closed) return@post
            if (pending.size >= 3 || (awaitingKeyframe && !frame.keyframe)) {
                desync(); ack(frame.sequence, false, 0.0)
            } else { pending.add(frame); pump() }
        }
    }
    private fun desync() {
        awaitingKeyframe = true
        val now = System.nanoTime()
        if (now - lastRequest > 300_000_000) { lastRequest = now; requestKeyframe() }
    }
    private fun pump() {
        while (!closed && inputs.isNotEmpty() && pending.isNotEmpty()) {
            val frame = pending.removeFirst()
            if (awaitingKeyframe && !frame.keyframe) { ack(frame.sequence, false, 0.0); continue }
            val index = inputs.removeFirst()
            try {
                val buffer = codec.getInputBuffer(index) ?: error("Decoder input buffer missing")
                require(frame.bytes.size <= buffer.capacity()) { "Encoded frame exceeds hardware buffer capacity" }
                buffer.clear(); buffer.put(frame.bytes)
                received[frame.sequence] = frame.receivedNS
                check(received.size <= 6) { "Decoder did not present frames in time" }
                codec.queueInputBuffer(index, 0, frame.bytes.size, frame.sequence, 0)
                awaitingKeyframe = false
            } catch (e: Exception) { fail("Could not submit frame: ${e.message}"); return }
        }
    }
    override fun close() { closeWhenReleased {} }
    // Called once by the owning receiver worker. The lease callback runs only
    // after native codec cleanup, even if the bounded wait below expires.
    fun closeWhenReleased(onReleased: () -> Unit) {
        if (closed) return
        closed = true
        val latch = CountDownLatch(1)
        handler.post {
            runCatching { codec.stop() }; runCatching { codec.release() }
            pending.clear(); received.clear(); presentationPending.clear()
            onReleased(); latch.countDown(); thread.quitSafely()
        }
        // The caller is the receiver worker, never the codec handler.
        latch.await(2, TimeUnit.SECONDS)
    }
    companion object {
        fun hardwareDecoder(mime: String, width: Int, height: Int, fps: Int, main10: Boolean = false): MediaCodecInfo? =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                !info.isEncoder && info.isHardwareAccelerated && info.supportedTypes.contains(mime) &&
                    runCatching {
                        val caps = info.getCapabilitiesForType(mime)
                        caps.videoCapabilities?.areSizeAndRateSupported(width, height, fps.toDouble()) == true &&
                            (!main10 || (mime == "video/hevc" && caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 }))
                    }.getOrDefault(false)
            }
    }
}
