package dev.padbridge

import android.app.Activity
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Network
import android.net.NetworkRequest
import android.net.LinkProperties
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.PowerManager
import android.view.*
import android.widget.*
import java.io.File
import java.net.Inet4Address
import java.util.Locale

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var root: FrameLayout
    private lateinit var surface: SurfaceView
    private lateinit var idleCover: View
    private lateinit var fpsOverlay: FpsOverlay
    private lateinit var touchSurface: TouchSurface
    private lateinit var controlContainer: ScrollView
    private lateinit var connectionInfo: TextView
    private lateinit var idleArt: View
    private lateinit var connectButton: Button
    private var connectionRequest: PadConnectRequest? = null
    private var requesting = false
    private var requestToken = 0
    private var requestMessage: String? = null
    private lateinit var heading: TextView
    private val receivers = mutableMapOf<Boolean, Receiver>()
    @Volatile private var usbReceiver: Receiver? = null
    @Volatile private var reverseReceiver: Receiver? = null
    private val receiverTokens = mutableMapOf<Boolean, Any>()
    private val listening = mutableSetOf<Boolean>()
    private val listenerRetries = mutableMapOf<Boolean, Int>()
    private val retryTokens = mutableMapOf<Boolean, Any>()
    private val sessionLease = SessionLease()
    private var activeTransport: Boolean? = null
    @Volatile private var wirelessAddress: String? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var resumed = false
    private var surfaceReady = false
    private var streaming = false
    private var wifiLock: WifiManager.WifiLock? = null
    private var generation = 0
    private var connectionText = UiText("用 USB 连接 Mac，在 Mac 上点击连接。", "Connect the Mac with USB, then click Connect on the Mac.")
    private var latestStats: RenderStats? = null
    @Volatile private var actualRefresh = 60f
    private val pairingLock = Any()
    private lateinit var key: ByteArray
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Language.load(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        key = readKey()
        root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            // A gesture belongs entirely to the video or the FPS badge. A
            // second finger on the badge must not split off a desktop drag.
            isMotionEventSplittingEnabled = false
        }
        surface = SurfaceView(this); surface.holder.addCallback(this)
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        // Keep video on its own Surface. Only the small UI overlay changes language.
        idleCover = GlassBackdrop(this); root.addView(idleCover, FrameLayout.LayoutParams(-1, -1))
        fpsOverlay = FpsOverlay(this); fpsOverlay.attach(root)
        touchSurface = TouchSurface(surface)
        surface.setOnTouchListener { view, event -> if (streaming) touchSurface.onTouch(view, event) else false }
        buildMenu()
        root.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) touchSurface.cancel()
            sizeMenu()
        }
        setContentView(root)
        window.insetsController?.hide(WindowInsets.Type.systemBars())
        window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun changed() { runOnUiThread { refreshWireless() } }
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
        }
        getSystemService(ConnectivityManager::class.java).registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
        networkCallback = callback
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun text(label: String, size: Float, color: Int = GlassColors.ink, bold: Boolean = false) = TextView(this).apply {
        text = label; textSize = size; setTextColor(color); gravity = Gravity.CENTER
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }
    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = label; isAllCaps = false; textSize = 14f; setTextColor(GlassColors.ink)
        background = GlassPanelDrawable(resources.displayMetrics.density, false, 16f)
        minHeight = 0; minimumHeight = 0; stateListAnimator = null; setOnClickListener { action() }
    }
    private fun row(left: View, right: View) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        addView(left, LinearLayout.LayoutParams(0, dp(48), 1f).apply { marginEnd = dp(6) })
        addView(right, LinearLayout.LayoutParams(0, dp(48), 1f).apply { marginStart = dp(6) })
    }
    private fun buildMenu() {
        val visible = if (::controlContainer.isInitialized) controlContainer.visibility else View.VISIBLE
        if (::controlContainer.isInitialized) root.removeView(controlContainer)
        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(24), dp(28), dp(24)); background = GlassPanelDrawable(resources.displayMetrics.density); elevation = dp(14).toFloat()
        }
        fun add(view: View, height: Int = -2, top: Int = 0) {
            controls.addView(view, LinearLayout.LayoutParams(-1, if (height < 0) height else dp(height)).apply { topMargin = dp(top) })
        }
        val brand = LinearLayout(this).apply { gravity = Gravity.CENTER; orientation = LinearLayout.HORIZONTAL }
        brand.addView(ImageView(this).apply { setImageResource(R.mipmap.ic_launcher); contentDescription = "Nextend" }, LinearLayout.LayoutParams(dp(40), dp(40)))
        brand.addView(text("Nextend", 22f, bold = true), LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(12) })
        add(brand)
        heading = text(tr("等待连接", "Ready to connect"), 26f, bold = true); add(heading, top = 18)
        idleArt = BridgeIllustration(this); add(idleArt, 120, 12)
        connectionInfo = text("", 13f, GlassColors.muted).apply { setPadding(0, dp(12), 0, dp(12)); setTextIsSelectable(true) }
        add(connectionInfo, top = 4)
        connectButton = button(tr("连接", "Connect")) { requestConnection() }; add(connectButton, 48, 10)
        controlContainer = ScrollView(this).apply {
            isFillViewport = false; clipToPadding = false; setPadding(dp(12), dp(12), dp(12), dp(12)); addView(controls); visibility = visible
        }
        root.addView(controlContainer, FrameLayout.LayoutParams(dp(504), -2, Gravity.CENTER))
        updateMenuState(); sizeMenu()
    }
    private fun sizeMenu() {
        if (root.width == 0 || root.height == 0) return
        val width = minOf(dp(504), (root.width - dp(24)).coerceAtLeast(1))
        val maximum = (root.height - dp(24)).coerceAtLeast(1)
        controlContainer.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(maximum, View.MeasureSpec.AT_MOST))
        val params = controlContainer.layoutParams as FrameLayout.LayoutParams
        val height = minOf(controlContainer.measuredHeight, maximum)
        if (params.width != width || params.height != height) { params.width = width; params.height = height; controlContainer.layoutParams = params }
    }
    private fun updateMenuState() {
        if (!::connectionInfo.isInitialized) return
        heading.text = tr("等待连接", "Ready to connect")
        connectionInfo.text = requestMessage ?: if (listening.isEmpty()) tr("正在准备连接…", "Preparing connection…") else ""
        connectButton.isEnabled = !requesting && listening.isNotEmpty()
        connectButton.text = if (requesting) tr("正在连接…", "Connecting…") else tr("连接", "Connect")
        fpsOverlay.updateVisibility(streaming); sizeMenu()
    }
    private fun requestConnection() {
        if (requesting || streaming) return
        requesting = true; requestMessage = null; updateMenuState()
        val owner = generation; val token = ++requestToken
        connectionRequest?.request(readKey()) { accepted -> runOnUiThread {
            if (!resumed || owner != generation || token != requestToken || streaming) return@runOnUiThread
            requesting = false
            requestMessage = if (accepted) tr("等待 Mac…", "Waiting for Mac…") else tr("请打开已配对的 Mac。首次连接请在 Mac 上通过 USB 配对。", "Open the paired Mac. For first use, pair with USB from the Mac.")
            updateMenuState()
            // The request acknowledges intent, not a completed video connection.
            // A Mac-side permission/network failure must not leave a stale wait.
            if (accepted) root.postDelayed({
                if (resumed && owner == generation && token == requestToken && !streaming) {
                    requestMessage = tr("连接超时，请在 Mac 查看状态。", "Connection timed out. Check the Mac for details.")
                    updateMenuState()
                }
            }, 20_000)
        } }
    }
    private fun applySettings(value: org.json.JSONObject) {
        Language.select(this, value.getString("language") == "en")
        fpsOverlay.setEnabledByUser(value.getBoolean("showFPS")); fpsOverlay.setSize(value.getInt("size"))
        fpsOverlay.setFont(value.getInt("font")); fpsOverlay.setColor(Color.parseColor(value.getString("color")))
        fpsOverlay.setPosition(value.getDouble("x").toFloat(), value.getDouble("y").toFloat())
        buildMenu(); updateMenuState()
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
        stop(); updateMenuState()
        if (!resumed || !surfaceReady) return
        startReceiver(false, "127.0.0.1")
        refreshWireless()
    }
    private fun refreshWireless() {
        if (!resumed || !surfaceReady) return
        val address = wifiAddress()
        if (wirelessAddress == address && (address == null || receivers.containsKey(true))) return
        receiverTokens.remove(true); retryTokens.remove(true); listening.remove(true)
        reverseReceiver = null
        receivers.remove(true)?.close()
        if (activeTransport == true) setStreaming(false)
        if (wirelessAddress != address) listenerRetries.remove(true)
        wirelessAddress = address
        if (address != null) startReceiver(true, address)
        updateMenuState()
    }
    private fun setStreaming(active: Boolean) {
        touchSurface.disable()
        streaming = active
        if (!active) activeTransport = null
        requestToken++; connectionRequest?.setStreaming(active); requesting = false; requestMessage = null
        latestStats = null; fpsOverlay.showRate(null)
        controlContainer.visibility = if (active) View.GONE else View.VISIBLE
        idleCover.visibility = if (active) View.GONE else View.VISIBLE
        updateWifiLatency(active && activeTransport == true)
    }
    private fun startReceiver(wireless: Boolean, address: String) {
        retryTokens.remove(wireless)
        val token = Any(); receiverTokens[wireless] = token
        val mode = display!!.mode; val owner = generation; actualRefresh = mode.refreshRate
        val width = maxOf(mode.physicalWidth, mode.physicalHeight); val height = minOf(mode.physicalWidth, mode.physicalHeight)
        fun current() = owner == generation && resumed && receiverTokens[wireless] === token
        receivers[wireless] = Receiver(address, { readKey() }, surface.holder.surface, width, height, display?.hdrCapabilities?.supportedHdrTypes ?: intArrayOf(),
            lease = sessionLease, wifiAddress = { wirelessAddress }, listening = { available -> runOnUiThread {
                if (!current()) return@runOnUiThread
                if (available) {
                    listening.add(wireless); listenerRetries.remove(wireless)
                } else {
                    listening.remove(wireless); receiverTokens.remove(wireless)
                    if (wireless) reverseReceiver = null else usbReceiver = null
                    receivers.remove(wireless)?.close()
                    val attempt = listenerRetries[wireless] ?: 0
                    if (attempt < 5) {
                        listenerRetries[wireless] = attempt + 1
                        val retry = Any(); retryTokens[wireless] = retry
                        // Retry only this endpoint. Generation, token and address
                        // checks cancel retries after pause, re-pairing or a new IP.
                        root.postDelayed({
                            if (owner == generation && resumed && surfaceReady && retryTokens[wireless] === retry && !receiverTokens.containsKey(wireless) &&
                                (!wireless || wirelessAddress == address)) startReceiver(wireless, address)
                        }, 500L shl attempt)
                    }
                }
                updateMenuState()
            } },
            status = { message, active -> runOnUiThread {
                if (!current()) return@runOnUiThread
                if (!active && activeTransport != wireless) return@runOnUiThread
                connectionText = message
                if (active) activeTransport = wireless
                setStreaming(active)
                actualRefresh = display?.mode?.refreshRate ?: 0f; updateMenuState()
            } }, stats = { stats -> runOnUiThread {
                if (!current() || !streaming || activeTransport != wireless) return@runOnUiThread
                actualRefresh = display?.mode?.refreshRate ?: 0f
                latestStats = stats; fpsOverlay.showRate(stats.fps); updateMenuState()
            } }, mode = { fps -> runOnUiThread {
                if (!current()) return@runOnUiThread
                val selected = display?.supportedModes?.filter { maxOf(it.physicalWidth, it.physicalHeight) == width && minOf(it.physicalWidth, it.physicalHeight) == height }
                    ?.minByOrNull { kotlin.math.abs(it.refreshRate - fps) }
                window.attributes = window.attributes.apply { preferredDisplayModeId = selected?.modeId ?: 0; preferredRefreshRate = fps.toFloat() }
            } }, touchMode = { endpoint, value -> runOnUiThread {
                if (current() && streaming && activeTransport == wireless) touchSurface.configure(value, endpoint)
            } }, settings = { value -> runOnUiThread {
                if (current() && streaming && activeTransport == wireless) applySettings(value)
            } }, resetPairing = {
                // Persist revocation before the authenticated acknowledgement.
                synchronized(pairingLock) {
                    val store = android.util.AtomicFile(File(filesDir, "pairing.key"))
                    val out = store.startWrite()
                    try { out.write(PairCrypto.random(32)); store.finishWrite(out) }
                    catch (e: Exception) { store.failWrite(out); throw e }
                }

            }, pairingChanged = { runOnUiThread { key = readKey(); if (resumed) restart() } }, refresh = { actualRefresh }, thermal = { getSystemService(PowerManager::class.java).currentThermalStatus }).also {
                if (wireless) reverseReceiver = it else usbReceiver = it
                it.start()
            }
    }
    private fun updateWifiLatency(active: Boolean) {
        if (active && wifiLock == null) {
            runCatching {
                val manager = applicationContext.getSystemService(WifiManager::class.java)
                manager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "PadBridge-video").also {
                    it.setReferenceCounted(false); it.acquire(); wifiLock = it
                }
            }.onFailure { android.util.Log.w("PadBridge", "Wi-Fi low latency request unavailable", it) }
        } else if (!active) {
            wifiLock?.let { if (it.isHeld) runCatching { it.release() } }
            wifiLock = null
        }
    }
    private fun stop() {
        reverseReceiver = null; usbReceiver = null
        requestToken++; connectionRequest?.setStreaming(false); requesting = false; requestMessage = null
        if (::touchSurface.isInitialized) touchSurface.disable()
        generation++; receiverTokens.clear(); retryTokens.clear(); listening.clear(); listenerRetries.clear(); updateWifiLatency(false); streaming = false; activeTransport = null; latestStats = null
        if (::fpsOverlay.isInitialized) fpsOverlay.updateVisibility(false)
        if (::idleCover.isInitialized) idleCover.visibility = View.VISIBLE
        receivers.values.forEach { it.close() }; receivers.clear(); wirelessAddress = null
        if (::controlContainer.isInitialized) controlContainer.visibility = View.VISIBLE
    }
    override fun onResume() {
        super.onResume(); resumed = true
        connectionRequest = PadConnectRequest(this, { readKey() }, ready = { automatic ->
            // The Surface lease can outlive the old socket while MediaCodec
            // finishes releasing it. Do not consume a new Mac handoff early.
            sessionLease.isAvailable() && (reverseReceiver?.canAcceptReverse() == true || (!automatic && usbReceiver?.canAcceptReverse() == true))
        }) { client, pairedKey, current ->
            current() && reverseReceiver?.acceptReverse(client, pairedKey) == true
        }
        connectionRequest?.start(); restart()
    }
    override fun onPause() { resumed = false; connectionRequest?.close(); connectionRequest = null; requesting = false; stop(); super.onPause() }
    override fun onDestroy() {
        networkCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        networkCallback = null
        super.onDestroy()
    }
    override fun onConfigurationChanged(configuration: Configuration) { super.onConfigurationChanged(configuration); root.post { sizeMenu() } }
    override fun surfaceCreated(holder: SurfaceHolder) { surfaceReady = true; restart() }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { surfaceReady = false; stop() }
}
