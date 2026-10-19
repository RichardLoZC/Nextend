package dev.padbridge

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/** Bonjour is discovery only; every candidate must prove the USB-paired key.
 * Idle resume polls can only fill a connection already requested on the Mac. */
class PadConnectRequest(context: Context, private val key: () -> ByteArray,
                        private val ready: (Boolean) -> Boolean,
                        private val incoming: (Socket, ByteArray, () -> Boolean) -> Boolean) : AutoCloseable {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val hosts = ConcurrentHashMap<String, String>()
    @Volatile private var running = true
    @Volatile private var paused = false
    private var socket: Socket? = null
    private var discovering = false
    private val requestLock = Any()
    private var requestID = 0
    private var busy = false
    private val poller = Thread({
        while (running) {
            try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
            if (running && !paused && hosts.isNotEmpty()) runCatching { begin(key(), automatic = true) {} }
        }
    }, "Nextend-reverse-poll")
    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) {}
        override fun onDiscoveryStopped(type: String) {}
        override fun onStartDiscoveryFailed(type: String, code: Int) {}
        override fun onStopDiscoveryFailed(type: String, code: Int) {}
        override fun onServiceLost(info: NsdServiceInfo) { hosts.remove(info.serviceName) }
        override fun onServiceFound(info: NsdServiceInfo) {
            if (!running || hosts.size >= 8 || info.serviceType != "_nextend._tcp.") return
            @Suppress("DEPRECATION")
            manager.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                override fun onServiceResolved(info: NsdServiceInfo) {
                    @Suppress("DEPRECATION") val address = info.host
                    if (running && address is Inet4Address && info.port == 49372) hosts[info.serviceName] = address.hostAddress!!
                }
            })
        }
    }
    fun start() {
        runCatching { manager.discoverServices("_nextend._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery); discovering = true }
        poller.start()
    }
    fun setStreaming(active: Boolean) { paused = active; cancel() }
    fun request(key: ByteArray, done: (Boolean) -> Unit) {
        begin(key, automatic = false, done)
    }
    private fun begin(pairedKey: ByteArray, automatic: Boolean, done: (Boolean) -> Unit) {
        val owner = synchronized(requestLock) {
            if (!running || paused || !ready(automatic) || (automatic && busy)) null
            else {
                // A user action replaces the poll atomically. No poll can steal
                // the gap between cancellation and reserving the next attempt.
                runCatching { socket?.close() }; socket = null
                busy = true; ++requestID
            }
        }
        if (owner == null) { if (!automatic) done(false); return }
        fun current() = synchronized(requestLock) { running && owner == requestID }
        Thread({
            var accepted = false
            val candidates = (if (automatic) emptyList() else listOf("127.0.0.1")) + hosts.values.toList().sorted()
            for (host in candidates.distinct().take(9)) {
                if (!current()) break
                val client = Socket()
                var handedOff = false
                try {
                    synchronized(requestLock) { if (running && requestID == owner) socket = client else { client.close(); return@Thread } }
                    client.connect(InetSocketAddress(host, 49372), 1200)
                    val channel = SecureChannel(client, pairedKey, requestClient = true)
                    channel.send(byteArrayOf(1) + JSONObject().put("type", if (automatic) "resume" else "connect").toString().toByteArray())
                    val reply = channel.receive(); require(reply.firstOrNull() == 1.toByte() && reply.size <= 512)
                    val result = JSONObject(String(reply, 1, reply.size - 1))
                    require(result.getString("type") == "connect-result" && result.get("accepted") is Boolean)
                    require(!result.has("reverse") || result.get("reverse") is Boolean)
                    accepted = result.getBoolean("accepted")
                    if (accepted && result.optBoolean("reverse", false)) {
                        require(host != "127.0.0.1")
                        // No buffered bytes or request keys cross into video. Receiver
                        // performs a fresh PDB1 handshake with the current pairing key.
                        synchronized(requestLock) {
                            if (running && requestID == owner && java.security.MessageDigest.isEqual(pairedKey, key())) {
                                // acceptReverse takes ownership synchronously.
                                // A rejected handoff is closed by this attempt.
                                handedOff = incoming(client, pairedKey, ::current)
                                if (handedOff) socket = null
                            }
                        }
                        if (!handedOff) accepted = false
                    }
                    if (accepted || !automatic) break
                } catch (_: Exception) { accepted = false }
                finally {
                    synchronized(requestLock) { if (socket === client) socket = null }
                    if (!handedOff) runCatching { client.close() }
                }
            }
            synchronized(requestLock) { if (requestID == owner) busy = false }
            if (current()) done(accepted)
        }, "Nextend-connect-request").start()
    }
    fun cancel() { synchronized(requestLock) { requestID++; busy = false; runCatching { socket?.close() }; socket = null } }
    override fun close() {
        running = false; cancel(); poller.interrupt()
        if (discovering) runCatching { manager.stopServiceDiscovery(discovery) }; hosts.clear()
    }
}
