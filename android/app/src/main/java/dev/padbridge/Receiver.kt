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
    private val address: String, private val key: ByteArray, private val surface: Surface,
    private val panelWidth: Int, private val panelHeight: Int,
    private val hdrTypes: IntArray,
    private val status: (UiText, Boolean) -> Unit,
    private val stats: (RenderStats) -> Unit,
    private val mode: (Int) -> Unit, private val refresh: () -> Float,
    private val thermal: () -> Int
) : AutoCloseable {
    @Volatile private var running = true
    @Volatile private var server: ServerSocket? = null
    @Volatile private var socket: Socket? = null
    private val lifecycleLock = Any()
    private val worker = Thread({ listen() }, "PadBridge-receiver")
    fun start() { worker.start() }
    private fun waiting() = if (address == "127.0.0.1") UiText("用 USB 连接 Mac，在 Mac 上点击连接。", "Connect the Mac with USB, then click Connect on the Mac.") else UiText("无线地址 $address · 首次连接需先通过 USB 配对。", "Wi-Fi address $address · Pair through USB before the first wireless connection.")
    private fun listen() {
        try {
            val listener = ServerSocket().also { server = it }
            listener.reuseAddress = true
            listener.bind(java.net.InetSocketAddress(InetAddress.getByName(address), PORT), 1)
            listener.soTimeout = 1000
            status(waiting(), false)
            while (running) {
                val client = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                synchronized(lifecycleLock) { if (running) socket = client else client.close() }
                if (!running) { client.close(); break }
                try { client.use { val secure = SecureChannel(it, key); if (running) serve(secure) }; if (running) status(waiting(), false) }
                catch (e: Exception) { if (running) status(UiText("连接结束：${e.message}\n等待 Mac 重新连接", "Connection ended: ${e.message}\nWaiting for the Mac to reconnect"), false) }
                finally { synchronized(lifecycleLock) { if (socket === client) socket = null } }
            }
        } catch (e: Exception) { if (running) status(UiText("监听失败：${e.message}", "Could not listen: ${e.message}"), false) }
        finally { runCatching { server?.close() } }
    }
    private fun serve(channel: SecureChannel) {
        var decoder: VideoDecoder? = null
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        val rendered = AtomicLong(0); val decoded = AtomicLong(0); val dropped = AtomicLong(0); val totalReceived = AtomicLong(0)
        val renderDelayBits = AtomicLong(0)
        val actualFormat = AtomicReference<Map<String, Int>>(emptyMap())
        var color = VideoColor.SDR
        var lastRendered = 0L; var lastDecoded = 0L; var lastTime = System.nanoTime()
        fun send(value: JSONObject) { channel.send(byteArrayOf(1) + value.toString().toByteArray()) }
        try {
            send(JSONObject().put("type", "hello").put("version", 1).put("width", panelWidth).put("height", panelHeight)
                .put("input", false).put("refresh", refresh()).put("hdrTypes", JSONArray(hdrTypes.toList())))
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
            color = VideoColor.negotiate(config.getString("color"), encoding, hlgSupported)
            require(config.optInt("bitDepth", 8) == color.bitDepth)
            require(!config.optBoolean("input", false))
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
                .put("color", color.wire).put("bitDepth", color.bitDepth))
            val summary = UiText("$width × $height · $fps fps 目标 · ${encoding.uppercase()} · ${color.title}", "$width × $height · Target $fps fps · ${encoding.uppercase()} · ${color.title}")
            status(summary, true)
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
            channel.close(); scheduler.shutdownNow(); decoder?.close()
            runCatching { surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
        }
    }
    override fun close() {
        synchronized(lifecycleLock) { running = false; runCatching { socket?.close() }; runCatching { server?.close() } }
        if (Thread.currentThread() !== worker) worker.join(2500)
    }
    companion object { const val PORT = 49371 }
}
