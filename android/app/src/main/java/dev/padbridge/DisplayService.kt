package dev.padbridge

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.net.*
import android.net.wifi.WifiManager
import android.os.*
import android.view.Display
import android.view.Surface
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address

/** Owns transport and session lifetime. Activities only lend a visible output Surface. */
class DisplayService : Service() {
    inner class LocalBinder : Binder() { val service: DisplayService get() = this@DisplayService }
    private val binder = LocalBinder()
    private val handler = Handler(Looper.getMainLooper())
    private var disposed = false
    private var uiOwner: Any? = null
    private var observer: (() -> Unit)? = null
    private var outputSurface: Surface? = null
    private val receivers = mutableMapOf<Boolean, Receiver>()
    @Volatile private var usbReceiver: Receiver? = null
    @Volatile private var reverseReceiver: Receiver? = null
    private val receiverTokens = mutableMapOf<Boolean, Any>()
    private val listening = mutableSetOf<Boolean>()
    private val listenerRetries = mutableMapOf<Boolean, Int>()
    private val retryTokens = mutableMapOf<Boolean, Any>()
    private val sessionLease = SessionLease()
    private val pairingLock = Any()
    private var generation = 0
    private var activeTransport: Boolean? = null
    @Volatile private var wirelessAddress: String? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var connectionRequest: PadConnectRequest? = null
    private var requestToken = 0
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    var streaming = false; private set
    var requesting = false; private set
    var requestMessage: String? = null; private set
    private val feedback = ConnectionFeedback()
    val connectionMessage: String? get() = requestMessage ?: feedback.message?.text
    var latestStats: RenderStats? = null; private set
    var requestedFPS = 60; private set
    var videoWidth = 3200; private set
    var videoHeight = 2136; private set
    var touchMode = TouchMode(false, 0, 0, 0); private set
    var touchEndpoint: TouchSender? = null; private set
    var settings: JSONObject? = null; private set
    val ready: Boolean get() = listening.isNotEmpty()
    private val panel: Display? get() = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    override fun onBind(intent: Intent): IBinder = binder
    override fun onCreate() {
        super.onCreate(); Language.load(this)
        settings = getSharedPreferences("settings", MODE_PRIVATE).getString("remote.settings", null)?.let { runCatching { JSONObject(it) }.getOrNull() }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, tr("拓展屏连接", "Display connection"), NotificationManager.IMPORTANCE_LOW))
        startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun changed() { handler.post { if (!disposed) refreshWireless() } }
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
        }
        getSystemService(ConnectivityManager::class.java).registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
        networkCallback = callback
        connectionRequest = PadConnectRequest(this, ::readKey, ready = { automatic ->
            sessionLease.isAvailable() && (reverseReceiver?.canAcceptReverse() == true || (!automatic && usbReceiver?.canAcceptReverse() == true))
        }) { client, pairedKey, current -> current() && reverseReceiver?.acceptReverse(client, pairedKey) == true }
        connectionRequest?.start(); restart()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { if (uiOwner != null) restart() else { shutdown(); stopSelf() } }
        return START_NOT_STICKY
    }
    fun attach(owner: Any, changed: () -> Unit) {
        uiOwner = owner; observer = changed; changed(); updateNotification()
    }
    fun setSurface(owner: Any, surface: Surface?, waitForRelease: Boolean = false) {
        if (uiOwner !== owner || disposed) return
        outputSurface = surface
        receivers.values.forEach { it.setSurface(surface, waitForRelease) }
    }
    fun detach(owner: Any) {
        if (uiOwner !== owner) return
        setSurface(owner, null)
        uiOwner = null; observer = null; updateNotification(); stopWhenIdle()
    }
    private fun stopWhenIdle() {
        handler.postDelayed({
            if (!disposed && uiOwner == null) {
                if (!streaming && receivers.values.none { it.hasClient() } && sessionLease.isAvailable()) stopSelf()
                else if (!streaming) stopWhenIdle()
            }
        }, 1500)
    }
    private fun changed() { if (!disposed) observer?.invoke() }
    fun requestConnection() {
        if (disposed || requesting || streaming) return
        // A manual retry also revives listeners whose previous attempts failed.
        if (!receivers.containsKey(false)) { listenerRetries.remove(false); startReceiver(false, "127.0.0.1") }
        refreshWireless()
        requesting = true; requestMessage = null; feedback.beginAttempt(); changed()
        val owner = generation; val token = ++requestToken
        connectionRequest?.request(readKey()) { accepted -> handler.post {
            if (disposed || owner != generation || token != requestToken || streaming) return@post
            requesting = false
            requestMessage = if (accepted) tr("等待 Mac…", "Waiting for Mac…") else tr("请打开已配对的 Mac。首次连接请在 Mac 上通过 USB 配对。", "Open the paired Mac. For first use, pair with USB from the Mac.")
            changed()
            if (accepted) handler.postDelayed({
                if (!disposed && owner == generation && token == requestToken && !streaming) {
                    requestMessage = tr("连接超时，请在 Mac 查看状态。", "Connection timed out. Check the Mac for details."); changed()
                }
            }, 20_000)
        } }
    }
    private fun readKey(): ByteArray = synchronized(pairingLock) {
        val file = File(filesDir, "pairing.key")
        if (file.exists() && file.length() == 32L) file.readBytes() else PairCrypto.random(32).also { file.writeBytes(it) }
    }
    private fun wifiAddress(): String? {
        val manager = getSystemService(ConnectivityManager::class.java)
        return manager.allNetworks.firstNotNullOfOrNull { network ->
            if (manager.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true)
                manager.getLinkProperties(network)?.linkAddresses?.firstOrNull { it.address is Inet4Address }?.address?.hostAddress
            else null
        }
    }
    private fun restart() {
        closeReceivers()
        if (disposed) return
        startReceiver(false, "127.0.0.1"); refreshWireless()
    }
    private fun refreshWireless() {
        if (disposed) return
        val address = wifiAddress()
        if (wirelessAddress == address && (address == null || receivers.containsKey(true))) return
        receiverTokens.remove(true); retryTokens.remove(true); listening.remove(true)
        reverseReceiver = null; receivers.remove(true)?.close()
        if (activeTransport == true) setStreaming(false)
        if (wirelessAddress != address) { listenerRetries.remove(true); connectionRequest?.refreshDiscovery(clearHosts = true) }
        wirelessAddress = address
        if (address != null) startReceiver(true, address) else feedback.listener(true, true)
        changed()
    }
    private fun setStreaming(active: Boolean, message: UiText? = null) {
        streaming = active
        feedback.session(active, message)
        if (!active) { activeTransport = null; touchEndpoint = null; touchMode = TouchMode(false, 0, 0, 0) }
        requestToken++; connectionRequest?.setStreaming(active); requesting = false; requestMessage = null
        latestStats = null; updateLocks(); updateNotification(); changed()
        if (!active && uiOwner == null) stopWhenIdle()
    }
    private fun startReceiver(wireless: Boolean, address: String) {
        if (disposed) return
        retryTokens.remove(wireless)
        val token = Any(); receiverTokens[wireless] = token
        val mode = panel?.mode ?: return
        val width = maxOf(mode.physicalWidth, mode.physicalHeight); val height = minOf(mode.physicalWidth, mode.physicalHeight)
        val owner = generation
        fun current() = !disposed && owner == generation && receiverTokens[wireless] === token
        receivers[wireless] = Receiver(address, ::readKey, width, height, panel?.hdrCapabilities?.supportedHdrTypes ?: intArrayOf(),
            lease = sessionLease, wifiAddress = { wirelessAddress }, listening = { available -> handler.post {
                if (!current()) return@post
                feedback.listener(wireless, available)
                if (available) { listening.add(wireless); listenerRetries.remove(wireless) }
                else {
                    listening.remove(wireless); receiverTokens.remove(wireless)
                    if (wireless) reverseReceiver = null else usbReceiver = null
                    receivers.remove(wireless)?.close()
                    val attempt = listenerRetries[wireless] ?: 0
                    run {
                        listenerRetries[wireless] = (attempt + 1).coerceAtMost(6)
                        val retry = Any(); retryTokens[wireless] = retry
                        handler.postDelayed({
                            if (!disposed && owner == generation && retryTokens[wireless] === retry && !receiverTokens.containsKey(wireless) &&
                                (!wireless || wirelessAddress == address)) startReceiver(wireless, address)
                        }, (500L shl attempt.coerceAtMost(6)).coerceAtMost(30_000))
                    }
                }
                changed()
            } }, status = { message, active -> handler.post {
                if (!current() || (!active && activeTransport != null && activeTransport != wireless)) return@post
                if (active) activeTransport = wireless
                setStreaming(active, message)
            } }, stats = { value -> handler.post {
                if (current() && streaming && activeTransport == wireless) { latestStats = value; changed() }
            } }, mode = { w, h, fps -> handler.post {
                if (current()) { videoWidth = w; videoHeight = h; requestedFPS = fps; changed() }
            } }, touchMode = { endpoint, value -> handler.post {
                if (current() && streaming && activeTransport == wireless) { touchEndpoint = endpoint; touchMode = value; changed() }
            } }, settings = { value -> handler.post {
                if (current() && streaming && activeTransport == wireless) {
                    // Legacy Macs omit this field. Preserve the same calibration in memory and on disk.
                    if (!value.has("safeArea")) settings?.optJSONObject("safeArea")?.let { value.put("safeArea", it) }
                    settings = value; Language.select(this, value.getString("language") == "en")
                    getSharedPreferences("settings", MODE_PRIVATE).edit().putString("remote.settings", value.toString()).apply()
                    updateNotification(); changed()
                }
            } }, resetPairing = {
                synchronized(pairingLock) {
                    val store = android.util.AtomicFile(File(filesDir, "pairing.key")); val out = store.startWrite()
                    try { out.write(PairCrypto.random(32)); store.finishWrite(out) }
                    catch (e: Exception) { store.failWrite(out); throw e }
                }
            }, pairingChanged = { handler.post { if (!disposed) restart() } }, refresh = { panel?.mode?.refreshRate ?: 60f },
            thermal = { getSystemService(PowerManager::class.java).currentThermalStatus }).also {
                if (wireless) reverseReceiver = it else usbReceiver = it
                it.setSurface(outputSurface); it.start()
            }
    }
    private fun updateLocks() {
        if (streaming && wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Nextend:connection").apply {
                setReferenceCounted(false); acquire()
            }
        } else if (!streaming) { wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null }
        if (streaming && activeTransport == true && wifiLock == null) {
            runCatching {
                wifiLock = applicationContext.getSystemService(WifiManager::class.java).createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Nextend-video").apply {
                    setReferenceCounted(false); acquire()
                }
            }.onFailure { android.util.Log.w("Nextend", "Wi-Fi low latency request unavailable", it) }
        } else if (!streaming || activeTransport != true) {
            wifiLock?.let { if (it.isHeld) runCatching { it.release() } }; wifiLock = null
        }
    }
    private fun closeReceivers() {
        generation++; receiverTokens.clear(); retryTokens.clear(); listening.clear(); listenerRetries.clear()
        feedback.clearListeners()
        reverseReceiver = null; usbReceiver = null
        receivers.values.forEach { it.close() }; receivers.clear(); wirelessAddress = null
        setStreaming(false)
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, DisplayService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.mipmap.ic_launcher).setContentTitle("Nextend")
            .setContentText(if (streaming) tr("连接保持中，返回 Nextend 继续显示", "Connection kept alive. Return to Nextend to view.") else tr("等待 Mac 连接", "Waiting for the Mac"))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, tr("断开", "Disconnect"), stop).build()).build()
    }
    private fun updateNotification() { if (!disposed) getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification()) }
    private fun shutdown() {
        if (disposed) return
        disposed = true
        observer?.invoke(); observer = null; uiOwner = null; outputSurface = null
        connectionRequest?.close(); connectionRequest = null
        closeReceivers()
        networkCallback?.let { runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } }; networkCallback = null
        handler.removeCallbacksAndMessages(null); stopForeground(STOP_FOREGROUND_REMOVE)
    }
    override fun onTaskRemoved(rootIntent: Intent?) { shutdown(); stopSelf() }
    override fun onDestroy() { shutdown(); super.onDestroy() }
    companion object { private const val CHANNEL = "nextend-connection"; private const val NOTIFICATION = 1; private const val STOP = "dev.padbridge.STOP" }
}
