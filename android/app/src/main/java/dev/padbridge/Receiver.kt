package dev.padbridge

import android.view.Surface
import android.view.Display
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class Receiver(
    private val address: String, private val key: () -> ByteArray, private val surface: Surface,
    private val panelWidth: Int, private val panelHeight: Int,
    private val hdrTypes: IntArray,
    private val lease: SessionLease,
    private val wifiAddress: () -> String?,
    private val listening: (Boolean) -> Unit,
    private val status: (UiText, Boolean) -> Unit,
    private val stats: (RenderStats) -> Unit,
    private val mode: (Int) -> Unit, private val refresh: () -> Float,
    private val touchMode: (TouchSender, TouchMode) -> Unit,
    private val settings: (JSONObject) -> Unit, private val resetPairing: () -> Unit, private val pairingChanged: () -> Unit,
    private val thermal: () -> Int
) : AutoCloseable {
    @Volatile private var running = true
    @Volatile private var server: ServerSocket? = null
    @Volatile private var socket: Socket? = null
    private val lifecycleLock = Any()
    private val worker = Thread({ listen() }, "PadBridge-receiver")
    private var reverseWorker: Thread? = null
    fun start() { worker.start() }
    private fun listen() {
        try {
            val listener = ServerSocket().also { server = it }
            listener.reuseAddress = true
            listener.bind(java.net.InetSocketAddress(InetAddress.getByName(address), PORT), 1)
            listener.soTimeout = 1000
            listening(true)
            while (running) {
                val client = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                val claimed = synchronized(lifecycleLock) {
                    if (running && socket == null) { socket = client; true } else false
                }
                if (!claimed) { client.close(); continue }
                handle(client)
            }
        } catch (e: Exception) { if (running) android.util.Log.w("PadBridge", "Listener unavailable", e) }
        finally { runCatching { server?.close() }; if (running) listening(false) }
    }
    /** Takes ownership only on success; no second transport may replace an active socket. */
    fun canAcceptReverse(): Boolean = synchronized(lifecycleLock) { running && socket == null && lease.isAvailable() }
    fun acceptReverse(client: Socket, pairedKey: ByteArray): Boolean = synchronized(lifecycleLock) {
        if (!running || socket != null || !lease.isAvailable()) return@synchronized false
        socket = client
        reverseWorker = Thread({ handle(client, pairedKey) }, "Nextend-reverse-video").also { it.start() }
        true
    }
    private fun handle(client: Socket, authenticatedKey: ByteArray? = null) {
        var ownsSession = false
        var releaseDelegated = false
        var ended = UiText("连接已结束", "Disconnected")
        try {
            client.use {
                // Never let an unauthenticated socket acquire the shared Surface.
                val pairedKey = authenticatedKey ?: key()
                require(java.security.MessageDigest.isEqual(pairedKey, key())) { "Pairing changed" }
                val secure = SecureChannel(it, pairedKey)
                require(java.security.MessageDigest.isEqual(pairedKey, key())) { "Pairing changed" }
                if (!running) return@use
                ownsSession = lease.acquire(client)
                if (!ownsSession) {
                    secure.send(byteArrayOf(1) + JSONObject().put("type", "busy").toString().toByteArray())
                    return@use
                }
                if (running) {
                    require(java.security.MessageDigest.isEqual(pairedKey, key())) { "Pairing changed" }
                    releaseDelegated = true
                    serve(secure) { lease.release(client) }
                }
            }
        } catch (e: Exception) {
            ended = UiText("连接结束：${e.message}", "Connection ended: ${e.message}")
        } finally {
            // serve() closes its decoder before another transport can enter.
            if (ownsSession) {
                if (!releaseDelegated) lease.release(client)
                if (running) status(ended, false)
            }
            synchronized(lifecycleLock) { if (socket === client) socket = null }
        }
    }
    private fun serve(channel: SecureChannel, releaseSession: () -> Unit) {
        var decoder: VideoDecoder? = null
        var touch: TouchSender? = null
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        val rendered = AtomicLong(0); val decoded = AtomicLong(0); val dropped = AtomicLong(0); val totalReceived = AtomicLong(0)
        val renderDelayBits = AtomicLong(0)
        val actualFormat = AtomicReference<Map<String, Int>>(emptyMap())
        var color = VideoColor.SDR
        var lastRendered = 0L; var lastDecoded = 0L; var lastTime = System.nanoTime()
        fun send(value: JSONObject) { channel.send(byteArrayOf(1) + value.toString().toByteArray()) }
        try {
            send(JSONObject().put("type", "hello").put("version", 1).put("width", panelWidth).put("height", panelHeight)
                .put("input", false).put("touchVersion", 1).put("controlsVersion", 1).put("refresh", refresh()).put("hdrTypes", JSONArray(hdrTypes.toList()))
                .put("wifiAddress", wifiAddress()))
            val initial = channel.receive()
            require(initial.firstOrNull() == 1.toByte())
            require(initial.size <= 65536)
            val probe = JSONObject(String(initial, 1, initial.size - 1))
            require(probe.getString("type") == "probe" && probe.getInt("version") == 1)
            val width = probe.getInt("width"); val height = probe.getInt("height"); val fps = probe.getInt("fps")
            require(width in 640..3840 && height in 480..2160 && width % 4 == 0 && height % 4 == 0 && fps in listOf(60, 90, 120))
            val codecs = JSONArray()
            for ((name, mime) in listOf("hevc" to "video/hevc", "h264" to "video/avc")) {
                if (VideoDecoder.hardwareDecoder(mime, width, height, fps) != null) codecs.put(name)
            }
            val hlgSupported = hdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_HLG) &&
                VideoDecoder.hardwareDecoder("video/hevc", width, height, fps, main10 = true) != null
            val colors = JSONArray().put(VideoColor.SDR.wire)
            if (hlgSupported) colors.put(VideoColor.HLG.wire)
            send(JSONObject().put("type", "capabilities").put("codecs", codecs).put("colors", colors))
            val configured = channel.receive()
            require(configured.firstOrNull() == 1.toByte() && configured.size <= 65536)
            val config = JSONObject(String(configured, 1, configured.size - 1))
            require(config.getString("type") == "config" && config.getInt("version") == 1)
            require(config.getInt("width") == width && config.getInt("height") == height && config.getInt("fps") == fps)
            val encoding = config.getString("codec")
            require((0 until codecs.length()).any { codecs.getString(it) == encoding }) { "Codec not advertised for this configuration" }
            color = VideoColor.negotiate(config.getString("color"), encoding, hlgSupported)
            require(config.optInt("bitDepth", 8) == color.bitDepth)
            require(!config.optBoolean("input", false))
            val controlsNegotiated = config.optInt("controlsVersion", 0) == 1
            val touchNegotiated = config.optInt("touchVersion", 0) == 1
            mode(fps)
            surface.setFrameRate(fps.toFloat(), Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            if (!running) return
            decoder = VideoDecoder(surface, if (encoding == "hevc") "video/hevc" else "video/avc", width, height, fps, color,
                ack = { sequence, accepted, delay ->
                    if (accepted) decoded.incrementAndGet() else dropped.incrementAndGet()
                    runCatching { send(JSONObject().put("type", "ack").put("seq", sequence).put("decoded", accepted).put("receiveToDecodeMs", delay)) }
                        .onFailure { channel.close() }
                }, presented = { _, delay -> rendered.incrementAndGet(); renderDelayBits.set(java.lang.Double.doubleToRawLongBits(delay)) },
                requestKeyframe = { runCatching { send(JSONObject().put("type", "keyframe")) }.onFailure { channel.close() } },
                outputFormat = { values -> actualFormat.set(values) },
                fail = { message ->
                    runCatching { send(JSONObject().put("type", if (color == VideoColor.HLG) "hdr-error" else "error").put("message", message)) }
                    status(UiText("解码停止：$message", "Decoder stopped: $message"), false); channel.close()
                })
            send(JSONObject().put("type", "ready").put("decoder", decoder.name).put("width", width).put("height", height)
                .put("color", color.wire).put("bitDepth", color.bitDepth).also { if (touchNegotiated) it.put("touchVersion", 1); if (controlsNegotiated) it.put("controlsVersion", 1) })
            val summary = UiText("$width × $height · $fps fps 目标 · ${encoding.uppercase()} · ${color.title}", "$width × $height · Target $fps fps · ${encoding.uppercase()} · ${color.title}")
            status(summary, true)
            if (touchNegotiated) touch = TouchSender(width, height, ::send) { channel.close() }
            scheduler.scheduleAtFixedRate({
                val now = System.nanoTime(); val count = rendered.get(); val decodedCount = decoded.get()
                val rate = (count - lastRendered) * 1e9 / (now - lastTime)
                val decodeRate = (decodedCount - lastDecoded) * 1e9 / (now - lastTime)
                lastRendered = count; lastDecoded = decodedCount; lastTime = now
                runCatching {
                    send(JSONObject().put("type", "stats").put("renderFps", rate).put("rendered", count)
                        .put("decodeFps", decodeRate).put("decoded", decodedCount).put("renderCallbackLastDelayMs", java.lang.Double.longBitsToDouble(renderDelayBits.get()))
                        .put("received", totalReceived.get()).put("dropped", dropped.get()).put("displayHz", refresh()).put("thermal", thermal())
                    // Color evidence is reported only after MediaCodec's output-format callback.
                        // Nested stats extend v1 compatibly; old Mac rejects new message types.
                        .put("videoFormat", JSONObject().put("color", color.wire).put("format", JSONObject(actualFormat.get()))
                            .put("verified", actualFormat.get().isNotEmpty()).put("rendered", count)))
                    stats(RenderStats(rate, decodeRate, refresh(), dropped.get(), thermal()))
                }.onFailure { channel.close() }
            }, 1, 1, TimeUnit.SECONDS)
            while (running) {
                val body = channel.receive()
                when (body.firstOrNull()?.toInt()) {
                    1 -> {
                        require(body.size <= 65536)
                        val json = JSONObject(String(body, 1, body.size - 1))
                        when (json.getString("type")) {
                            "ping" -> send(JSONObject().put("type", "pong"))
                            "touch-mode" -> {
                                val endpoint = touch ?: error("Touch was not negotiated")
                                touchMode(endpoint, endpoint.setMode(json))
                            }
                            "pad-settings" -> { require(controlsNegotiated); settings(PadPreferences.validate(json)) }
                            "reset-pairing" -> {
                                require(controlsNegotiated)
                                resetPairing()
                                try { send(JSONObject().put("type", "pair-reset")) } finally { pairingChanged() }
                                return
                            }
                            "stop" -> return
                            else -> error("Unsupported control message")
                        }
                    }
                    2 -> {
                        require(body.size > 18 && body.size <= 4 * 1024 * 1024 + 18)
                        val seq = ByteBuffer.wrap(body, 1, 8).long
                        require(seq > 0)
                        totalReceived.incrementAndGet()
                        decoder.submit(VideoFrame(seq, body[17].toInt() == 1, body.copyOfRange(18, body.size), System.nanoTime()))
                    }
                    else -> error("Unknown data type")
                }
            }
        } catch (e: Exception) {
            runCatching { send(JSONObject().put("type", if (color == VideoColor.HLG) "hdr-error" else "error").put("message", e.message ?: "Receive failed")) }
            throw e
        } finally {
            touch?.close(); channel.close(); scheduler.shutdownNow()
            runCatching { surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
            // If vendor teardown exceeds our UI wait, retain the lease until
            // the codec handler actually releases the old decoder.
            decoder?.closeWhenReleased(releaseSession) ?: releaseSession()
        }
    }
    override fun close() {
        synchronized(lifecycleLock) { running = false; runCatching { socket?.close() }; runCatching { server?.close() } }
        if (Thread.currentThread() !== worker) worker.join(2500)
        val reverse = synchronized(lifecycleLock) { reverseWorker }
        if (Thread.currentThread() !== reverse) reverse?.join(2500)
    }
    companion object { const val PORT = 49371 }
}
