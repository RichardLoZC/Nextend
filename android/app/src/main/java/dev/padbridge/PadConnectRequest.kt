package dev.padbridge

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject
import android.os.Handler
import android.os.Looper
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
    private val discoveryHandler = Handler(Looper.getMainLooper())
    // Discovery/resolve state is confined to the main looper. Socket workers
    // only read the concurrent address cache.
    private var discovery: NsdManager.DiscoveryListener? = null
    private var discoveryEpoch = 0
    private var discoveryAttempt = 0
    private val known = linkedMapOf<String, NsdServiceInfo>()
    private val pendingResolve = linkedSetOf<String>()
    private val resolveAttempts = mutableMapOf<String, Int>()
    private var resolving: String? = null
    private var resolveToken = 0
    private val requestLock = Any()
    private var requestID = 0
    private var busy = false
    private val poller = Thread({
        while (running) {
            try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
            if (running && !paused && hosts.isNotEmpty()) runCatching { begin(key(), automatic = true) {} }
        }
    }, "Nextend-reverse-poll")
    fun start() {
        discoveryHandler.post { restartDiscovery(clearHosts = true) }
        poller.start()
    }
    fun refreshDiscovery(clearHosts: Boolean = false) {
        discoveryHandler.post {
            if (running) { discoveryAttempt = 0; restartDiscovery(clearHosts) }
        }
    }
    private fun restartDiscovery(clearHosts: Boolean) {
        if (!running) return
        val epoch = ++discoveryEpoch
        discoveryHandler.removeCallbacksAndMessages(null)
        discovery?.let { runCatching { manager.stopServiceDiscovery(it) } }; discovery = null
        known.clear(); pendingResolve.clear(); resolveAttempts.clear(); resolving = null; resolveToken++
        if (clearHosts) hosts.clear()
        fun current() = running && discoveryEpoch == epoch
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) { discoveryHandler.post { if (current()) discoveryAttempt = 0 } }
            override fun onDiscoveryStopped(type: String) { discoveryHandler.post { if (current()) retryDiscovery(epoch) } }
            override fun onStartDiscoveryFailed(type: String, code: Int) { discoveryHandler.post { if (current()) retryDiscovery(epoch) } }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) { discoveryHandler.post {
                if (current()) { hosts.remove(info.serviceName); known.remove(info.serviceName); pendingResolve.remove(info.serviceName); resolveAttempts.remove(info.serviceName) }
            } }
            override fun onServiceFound(info: NsdServiceInfo) { discoveryHandler.post {
                if (current() && info.serviceType == "_nextend._tcp." && (known.size < 8 || known.containsKey(info.serviceName))) {
                    known[info.serviceName] = info
                    pendingResolve.add(info.serviceName)
                    resolveNext(epoch)
                }
            } }
        }
        discovery = listener
        try { manager.discoverServices("_nextend._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
        catch (_: Exception) { retryDiscovery(epoch) }
    }
    private fun retryDiscovery(epoch: Int) {
        if (!running || discoveryEpoch != epoch) return
        // Invalidate late callbacks before stopping the failed registration.
        discoveryEpoch++; val next = discoveryEpoch
        discovery?.let { runCatching { manager.stopServiceDiscovery(it) } }; discovery = null
        val delay = (1000L shl discoveryAttempt.coerceAtMost(5)).coerceAtMost(30_000)
        discoveryAttempt++
        discoveryHandler.postDelayed({ if (running && discoveryEpoch == next) restartDiscovery(clearHosts = true) }, delay)
    }
    private fun resolveNext(epoch: Int) {
        if (!running || discoveryEpoch != epoch || resolving != null) return
        val name = pendingResolve.firstOrNull() ?: return
        pendingResolve.remove(name)
        val info = known[name] ?: return resolveNext(epoch)
        resolving = name; val token = ++resolveToken
        var timeout: Runnable? = null
        fun complete(address: String?) {
            if (!running || discoveryEpoch != epoch || resolveToken != token || resolving != name) return
            timeout?.let { discoveryHandler.removeCallbacks(it) }
            resolving = null
            if (known[name] === info) {
                if (address != null) {
                    if (!hosts.containsKey(name) && hosts.size >= 8) hosts.keys.firstOrNull()?.let { hosts.remove(it) }
                    hosts[name] = address; resolveAttempts.remove(name)
                }
                else {
                    hosts.remove(name)
                    val attempt = resolveAttempts[name] ?: 0; resolveAttempts[name] = attempt + 1
                    val delay = (500L shl attempt.coerceAtMost(6)).coerceAtMost(30_000)
                    discoveryHandler.postDelayed({
                        if (running && discoveryEpoch == epoch && known[name] === info) { pendingResolve.add(name); resolveNext(epoch) }
                    }, delay)
                }
            }
            resolveNext(epoch)
        }
        timeout = Runnable { complete(null) }
        discoveryHandler.postDelayed(timeout!!, 6000)
        try {
            @Suppress("DEPRECATION")
            manager.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) { discoveryHandler.post { complete(null) } }
                override fun onServiceResolved(info: NsdServiceInfo) { discoveryHandler.post {
                    @Suppress("DEPRECATION") val address = info.host
                    complete(if (address is Inet4Address && info.port == 49372) address.hostAddress else null)
                } }
            })
        } catch (_: Exception) { complete(null) }
    }
    fun setStreaming(active: Boolean) { paused = active; cancel() }
    fun request(key: ByteArray, done: (Boolean) -> Unit) {
        refreshDiscovery()
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
            val candidates = sequence {
                if (!automatic) {
                    yield("127.0.0.1")
                    // USB remains first. Give a freshly restarted discovery a
                    // short opportunity to return before declaring no Mac found.
                    for (i in 0 until 15) {
                        if (!current() || hosts.isNotEmpty()) break
                        Thread.sleep(100)
                    }
                }
                yieldAll(hosts.values.toList().sorted())
            }
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
        discoveryHandler.post {
            discoveryEpoch++; discoveryHandler.removeCallbacksAndMessages(null)
            discovery?.let { runCatching { manager.stopServiceDiscovery(it) } }; discovery = null
            known.clear(); pendingResolve.clear(); hosts.clear()
        }
    }
}
