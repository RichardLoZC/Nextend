package dev.padbridge

import android.app.Activity
import android.app.AlertDialog
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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
    private lateinit var controlContainer: ScrollView
    private lateinit var connectionInfo: TextView
    private lateinit var usbButton: Button
    private lateinit var wifiButton: Button
    private lateinit var idleArt: View
    private lateinit var hideButton: Button
    private lateinit var heading: TextView
    private var receiver: Receiver? = null
    private var resumed = false
    private var surfaceReady = false
    private var wireless = false
    private var streaming = false
    private var wifiLock: WifiManager.WifiLock? = null
    private var generation = 0
    private var connectionText = UiText("用 USB 连接 Mac，在 Mac 上点击连接。", "Connect the Mac with USB, then click Connect on the Mac.")
    private var latestStats: RenderStats? = null
    @Volatile private var actualRefresh = 60f
    private lateinit var key: ByteArray
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Language.load(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        key = readKey()
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surface = SurfaceView(this); surface.holder.addCallback(this)
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        // Keep video on its own Surface. Only the small UI overlay changes language.
        idleCover = GlassBackdrop(this); root.addView(idleCover, FrameLayout.LayoutParams(-1, -1))
        fpsOverlay = FpsOverlay(this); fpsOverlay.attach(root)
        surface.setOnClickListener { if (streaming) toggleMenu() }
        fpsOverlay.setOnClickListener { if (streaming) toggleMenu() }
        buildMenu()
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> sizeMenu() }
        setContentView(root)
        window.insetsController?.hide(WindowInsets.Type.systemBars())
        window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
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
        usbButton = button(tr("USB 有线", "USB")) { wireless = false; restart() }
        wifiButton = button(tr("加密无线", "Encrypted Wi-Fi")) { wireless = true; restart() }
        add(row(usbButton, wifiButton), top = 16)
        connectionInfo = text("", 13f, GlassColors.muted).apply { setPadding(0, dp(12), 0, dp(12)); setTextIsSelectable(true) }
        add(connectionInfo, top = 4)
        val fps = Switch(this).apply {
            text = tr("显示 FPS", "Show FPS"); textSize = 16f; setTextColor(GlassColors.ink); isChecked = fpsOverlay.enabledByUser
            setOnCheckedChangeListener { _, checked -> fpsOverlay.setEnabledByUser(checked); fpsOverlay.updateVisibility(streaming) }
        }
        add(row(fps, button(tr("FPS 样式", "FPS style")) { showFpsSettings() }), top = 4)
        val chinese = button("中文") { chooseLanguage(false) }
        val english = button("English") { chooseLanguage(true) }
        for ((view, selected) in listOf(chinese to !Language.english, english to Language.english)) styleSelected(view, selected)
        add(row(chinese, english), top = 10)
        add(button(tr("重新配对", "Pair again")) {
            AlertDialog.Builder(this).setMessage(tr("断开当前连接并撤销配对？之后需要通过 USB 重新连接 Mac。", "Disconnect and revoke pairing? You will need USB to pair with the Mac again."))
                .setPositiveButton(tr("重新配对", "Pair again")) { _, _ -> stop(); key = PairCrypto.random(32); File(filesDir, "pairing.key").writeBytes(key); wireless = false; restart() }
                .setNegativeButton(tr("取消", "Cancel"), null).show()
        }, 48, 10)
        hideButton = button(tr("返回桌面", "Back to desktop")) { controlContainer.visibility = View.GONE }; add(hideButton, 48, 10)
        controlContainer = ScrollView(this).apply {
            isFillViewport = false; clipToPadding = false; setPadding(dp(12), dp(12), dp(12), dp(12)); addView(controls); visibility = visible
        }
        root.addView(controlContainer, FrameLayout.LayoutParams(dp(504), -2, Gravity.CENTER))
        updateMenuState(); sizeMenu()
    }
    private fun chooseLanguage(english: Boolean) { Language.select(this, english); buildMenu(); fpsOverlay.showRate(latestStats?.fps) }
    private fun sizeMenu() {
        if (root.width == 0 || root.height == 0) return
        val width = minOf(dp(504), (root.width - dp(24)).coerceAtLeast(1))
        val maximum = (root.height - dp(24)).coerceAtLeast(1)
        controlContainer.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(maximum, View.MeasureSpec.AT_MOST))
        val params = controlContainer.layoutParams as FrameLayout.LayoutParams
        val height = minOf(controlContainer.measuredHeight, maximum)
        if (params.width != width || params.height != height) { params.width = width; params.height = height; controlContainer.layoutParams = params }
    }
    private fun toggleMenu() { controlContainer.visibility = if (controlContainer.visibility == View.VISIBLE) View.GONE else View.VISIBLE; sizeMenu() }
    private fun styleSelected(view: Button, selected: Boolean) {
        view.background = GlassPanelDrawable(resources.displayMetrics.density, selected, 16f)
        view.setTextColor(if (selected) Color.WHITE else GlassColors.ink); view.isSelected = selected
        view.contentDescription = view.text.toString() + if (selected) tr("，已选择", ", selected") else ""
    }
    private fun updateMenuState() {
        if (!::usbButton.isInitialized) return
        styleSelected(usbButton, !wireless); styleSelected(wifiButton, wireless)
        usbButton.isEnabled = !streaming; wifiButton.isEnabled = !streaming
        heading.text = if (streaming) tr("已连接", "Connected") else tr("等待连接", "Ready to connect")
        idleArt.visibility = if (streaming) View.GONE else View.VISIBLE
        hideButton.visibility = if (streaming) View.VISIBLE else View.GONE
        var details = connectionText.text
        if (streaming) latestStats?.let {
            details += "\n" + tr("呈现", "Rendered") + String.format(Locale.ROOT, " %.1f fps · ", it.fps) + tr("面板", "Display") + String.format(Locale.ROOT, " %.0f Hz", it.displayHz)
            details += "\n" + tr("解码", "Decoded") + String.format(Locale.ROOT, " %.1f fps · ", it.decodeFps) + tr("丢弃", "Dropped") + " ${it.dropped} · " + tr("温控", "Thermal") + " ${it.thermal}"
        }
        connectionInfo.text = details
        fpsOverlay.updateVisibility(streaming); sizeMenu()
    }
    private fun showFpsSettings() {
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(8), dp(24), dp(8)) }
        body.addView(text(tr("拖动 FPS 可调整位置。", "Drag the FPS overlay to move it."), 14f, GlassColors.muted))
        val size = text("${fpsOverlay.sizeSp} sp", 16f); body.addView(size)
        body.addView(SeekBar(this).apply {
            min = 12; max = 64; progress = fpsOverlay.sizeSp; contentDescription = tr("字号", "Font size")
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) { if (fromUser) { fpsOverlay.setSize(value); size.text = "$value sp" } }
                override fun onStartTrackingTouch(bar: SeekBar) {}
                override fun onStopTrackingTouch(bar: SeekBar) {}
            })
        })
        fun choice(title: String, names: List<String>, selected: Int, change: (Int) -> Unit): Spinner {
            body.addView(text(title, 14f, GlassColors.muted))
            val spinner = Spinner(this).apply {
                adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, names)
                setSelection(selected); contentDescription = title
                onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                    override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) { change(position) }
                    override fun onNothingSelected(parent: AdapterView<*>?) {}
                }
            }
            body.addView(spinner, LinearLayout.LayoutParams(-1, dp(48)))
            return spinner
        }
        choice(tr("字体", "Font"), listOf(tr("无衬线", "Sans serif"), tr("等宽", "Monospace"), tr("衬线", "Serif")), fpsOverlay.fontIndex) { fpsOverlay.setFont(it) }
        val colors = listOf(Color.WHITE, Color.BLACK, 0xFF75F5BD.toInt(), 0xFFFFDE59.toInt(), 0xFF72D8FF.toInt(), 0xFFFF8FB4.toInt())
        val colorPicker = choice(tr("颜色", "Color"), listOf(tr("白色", "White"), tr("黑色", "Black"), tr("薄荷绿", "Mint"), tr("黄色", "Yellow"), tr("蓝色", "Blue"), tr("粉色", "Pink"), tr("自定义", "Custom")), colors.indexOf(fpsOverlay.textColorValue).let { if (it < 0) 6 else it }) { if (it < colors.size) fpsOverlay.setColor(colors[it]) }
        body.addView(button(tr("自定义颜色…", "Custom color…")) {
            val input = EditText(this).apply { setSingleLine(); setText(String.format(Locale.ROOT, "#%06X", fpsOverlay.textColorValue and 0xFFFFFF)); contentDescription = "RGB #RRGGBB" }
            val dialog = AlertDialog.Builder(this).setTitle(tr("颜色 · #RRGGBB", "Color · #RRGGBB")).setView(input).setPositiveButton(tr("应用", "Apply"), null).setNegativeButton(tr("取消", "Cancel"), null).create()
            dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val value = input.text.toString().trim()
                if (!Regex("#[0-9a-fA-F]{6}").matches(value)) input.error = tr("请输入六位 RGB 色值，如 #75F5BD", "Enter six RGB digits, e.g. #75F5BD")
                else {
                    val selectedColor = Color.parseColor(value); fpsOverlay.setColor(selectedColor)
                    colorPicker.setSelection(colors.indexOf(selectedColor).let { if (it < 0) 6 else it })
                    dialog.dismiss()
                }
            } }; dialog.show()
        }, LinearLayout.LayoutParams(-1, dp(48)))
        AlertDialog.Builder(this).setTitle(tr("FPS 样式", "FPS style")).setView(body).setPositiveButton(tr("完成", "Done"), null).show()
    }
    private fun readKey(): ByteArray {
        val file = File(filesDir, "pairing.key")
        return if (file.exists() && file.length() == 32L) file.readBytes() else PairCrypto.random(32).also { file.writeBytes(it) }
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
        val address = if (wireless) wifiAddress() else "127.0.0.1"
        if (address == null) {
            connectionText = UiText("没有可用 Wi-Fi 地址，请连接局域网或使用 USB。", "No Wi-Fi address. Join a local network or use USB.")
            controlContainer.visibility = View.VISIBLE; updateMenuState(); return
        }
        val mode = display!!.mode; val owner = generation; actualRefresh = mode.refreshRate
        val width = maxOf(mode.physicalWidth, mode.physicalHeight); val height = minOf(mode.physicalWidth, mode.physicalHeight)
        receiver = Receiver(address, key, surface.holder.surface, width, height, display?.hdrCapabilities?.supportedHdrTypes ?: intArrayOf(),
            status = { message, active -> runOnUiThread {
                if (owner != generation || !resumed) return@runOnUiThread
                connectionText = message
                if (active && !streaming) { controlContainer.visibility = View.GONE; latestStats = null; fpsOverlay.showRate(null) }
                if (!active) { controlContainer.visibility = View.VISIBLE; latestStats = null }
                streaming = active; updateWifiLatency(wireless && streaming)
                idleCover.visibility = if (streaming) View.GONE else View.VISIBLE
                actualRefresh = display?.mode?.refreshRate ?: 0f; updateMenuState()
            } }, stats = { stats -> runOnUiThread {
                if (owner != generation || !resumed || !streaming) return@runOnUiThread
                actualRefresh = display?.mode?.refreshRate ?: 0f
                latestStats = stats; fpsOverlay.showRate(stats.fps); updateMenuState()
            } }, mode = { fps -> runOnUiThread {
                if (owner != generation || !resumed) return@runOnUiThread
                val selected = display?.supportedModes?.filter { maxOf(it.physicalWidth, it.physicalHeight) == width && minOf(it.physicalWidth, it.physicalHeight) == height }
                    ?.minByOrNull { kotlin.math.abs(it.refreshRate - fps) }
                window.attributes = window.attributes.apply { preferredDisplayModeId = selected?.modeId ?: 0; preferredRefreshRate = fps.toFloat() }
            } }, refresh = { actualRefresh }, thermal = { getSystemService(PowerManager::class.java).currentThermalStatus }).also { it.start() }
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
        generation++; updateWifiLatency(false); streaming = false; latestStats = null
        if (::fpsOverlay.isInitialized) fpsOverlay.updateVisibility(false)
        if (::idleCover.isInitialized) idleCover.visibility = View.VISIBLE
        receiver?.close(); receiver = null
    }
    override fun onResume() { super.onResume(); resumed = true; restart() }
    override fun onPause() { resumed = false; stop(); super.onPause() }
    override fun onConfigurationChanged(configuration: Configuration) { super.onConfigurationChanged(configuration); root.post { sizeMenu() } }
    override fun surfaceCreated(holder: SurfaceHolder) { surfaceReady = true; restart() }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { surfaceReady = false; stop() }
}
