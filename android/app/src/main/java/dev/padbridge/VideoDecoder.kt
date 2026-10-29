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
    private val mime: String, private val width: Int, private val height: Int, private val fps: Int, private val color: VideoColor,
    private val ack: (Long, Boolean, Double) -> Unit,
    private val presented: (Long, Double) -> Unit,
    private val requestKeyframe: () -> Unit,
    private val outputFormat: (Map<String, Int>) -> Unit,
    private val fail: (String) -> Unit,
    private val sessionID: String = java.util.UUID.randomUUID().toString()
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
    private var codec: MediaCodec? = null // codec handler only
    @Volatile private var desiredSurface: Surface? = null
    private var configuredSurface: Surface? = null
    private val targetLock = Any()
    @Volatile private var targetVersion = 0L
    private var configuredVersion = -1L
    private var configuredOnce = false
    private var needsSurfaceKeyframe = false
    private val info = hardwareDecoder(mime, width, height, fps, color == VideoColor.HLG)
        ?: run { thread.quitSafely(); throw IllegalArgumentException("No hardware $mime decoder supports ${width}×${height} at $fps fps") }
    val name: String = info.name
    val visible: Boolean get() = !closed && desiredSurface?.isValid == true

    private fun reportFailure(message: String) { DiagnosticLog.event("decoder.error", sessionID, mapOf("message" to message)); fail(message) }

    /** A missing Surface suspends decoding, never the authenticated connection. */
    fun setSurface(surface: Surface?) {
        if (closed) return
        synchronized(targetLock) {
            if (desiredSurface === surface) return
            desiredSurface = surface; targetVersion++
        }
        DiagnosticLog.event("decoder.surface", sessionID, mapOf("visible" to (surface?.isValid == true)))
        handler.post { if (!closed) applySurface() }
    }
    fun awaitSurfaceRelease() {
        val done = CountDownLatch(1)
        if (handler.post { done.countDown() } && !done.await(1500, TimeUnit.MILLISECONDS)) {
            reportFailure("Decoder surface release timed out")
        }
    }
    private fun discardBufferedFrames() {
        while (pending.isNotEmpty()) ack(pending.removeFirst().sequence, false, 0.0)
        received.keys.toList().forEach { ack(it, false, 0.0) }
        received.clear(); inputs.clear(); presentationPending.clear(); awaitingKeyframe = true
    }
    private fun releaseCodec() {
        val old = codec; codec = null; configuredSurface = null
        if (old != null) { runCatching { old.stop() }; runCatching { old.release() } }
        discardBufferedFrames()
    }
    private fun applySurface() {
        val (surface, version) = synchronized(targetLock) { desiredSurface?.takeIf { it.isValid } to targetVersion }
        if (version == configuredVersion && surface === configuredSurface && (surface == null || codec != null)) return
        releaseCodec(); configuredVersion = version
        if (surface == null || closed) return
        formatAccepted = color == VideoColor.SDR
        try {
            val mc = MediaCodec.createByCodecName(name)
            codec = mc; configuredSurface = surface
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
            mc.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(mc: MediaCodec, index: Int) { if (!closed && mc === codec) { inputs.add(index); pump() } }
                override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (!closed && mc === codec) runCatching {
                        if (!formatAccepted) { mc.releaseOutputBuffer(index, false); return }
                        val render = targetVersion == configuredVersion && desiredSurface === configuredSurface && desiredSurface?.isValid == true
                        val start = received[info.presentationTimeUs]
                        if (start != null && render) {
                            presentationPending[info.presentationTimeUs] = start
                            // Render callbacks are optional telemetry and must not hold sender credit.
                            while (presentationPending.size > 240) presentationPending.remove(presentationPending.keys.first())
                        }
                        mc.releaseOutputBuffer(index, render)
                        received.remove(info.presentationTimeUs)
                        if (start != null) ack(info.presentationTimeUs, render, (System.nanoTime() - start) / 1e6)
                    }.onFailure { if (targetVersion == configuredVersion && desiredSurface === configuredSurface) reportFailure("Decoder output failed: ${it.message}") }
                }
                override fun onError(mc: MediaCodec, error: MediaCodec.CodecException) { if (!closed && mc === codec && targetVersion == configuredVersion && desiredSurface === configuredSurface) reportFailure("Hardware decoder failed: ${error.diagnosticInfo}") }
                override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                    if (closed || mc !== codec) return
                    android.util.Log.i("PadBridge", "decoder-format $format")
                    fun read(key: String) = if (format.containsKey(key)) format.getInteger(key) else -1
                    val values = listOf(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_TRANSFER,
                        MediaFormat.KEY_COLOR_RANGE, MediaFormat.KEY_PROFILE, MediaFormat.KEY_COLOR_FORMAT).associateWith { read(it) }
                    formatAccepted = color != VideoColor.HLG ||
                        (values[MediaFormat.KEY_COLOR_STANDARD] == MediaFormat.COLOR_STANDARD_BT2020 &&
                         values[MediaFormat.KEY_COLOR_TRANSFER] == MediaFormat.COLOR_TRANSFER_HLG &&
                         values[MediaFormat.KEY_COLOR_RANGE] == MediaFormat.COLOR_RANGE_LIMITED)
                    DiagnosticLog.event("decoder.format", sessionID, values)
                    if (formatAccepted) outputFormat(values) else reportFailure("HDR decoder color format mismatch; output stopped")
                }
            }, handler)
            mc.setOnFrameRenderedListener({ source, pts, _ ->
                if (!closed && source === codec) presentationPending.remove(pts)?.let { start ->
                    // Clock this on arrival; vendor callback timestamps need not
                    // be useful for a cross-device photon-latency measurement.
                    presented(pts, (System.nanoTime() - start) / 1e6)
                }
            }, handler)
            surface.setFrameRate(fps.toFloat(), Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            mc.configure(format, surface, null, 0)
            mc.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            mc.start()
            if (configuredOnce || needsSurfaceKeyframe) requestKeyframe()
            needsSurfaceKeyframe = false
            configuredOnce = true
        } catch (e: Exception) {
            val obsolete = targetVersion != version || desiredSurface !== surface || !surface.isValid
            releaseCodec()
            if (!obsolete && !closed) reportFailure("Could not prepare video output: ${e.message}")
        }
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
            if (codec == null || desiredSurface == null) { needsSurfaceKeyframe = true; ack(frame.sequence, false, 0.0); return@post }
            if (pending.size >= 3 || (awaitingKeyframe && !frame.keyframe)) {
                desync(); ack(frame.sequence, false, 0.0)
            } else { pending.add(frame); pump() }
        }
    }
    private fun desync() {
        awaitingKeyframe = true
        if (codec == null || desiredSurface == null) return
        val now = System.nanoTime()
        if (now - lastRequest > 300_000_000) { lastRequest = now; requestKeyframe() }
    }
    private fun pump() {
        val codec = codec ?: return
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
            } catch (e: Exception) { reportFailure("Could not submit frame: ${e.message}"); return }
        }
    }
    override fun close() { closeWhenReleased {} }
    // Called once by the owning receiver worker. The lease callback runs only
    // after native codec cleanup, even if the bounded wait below expires.
    fun closeWhenReleased(onReleased: () -> Unit) {
        if (closed) return
        closed = true; desiredSurface = null
        val latch = CountDownLatch(1)
        handler.post {
            releaseCodec()
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
