package dev.padbridge

import android.app.Activity
import android.Manifest
import android.content.*
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Build
import android.os.IBinder
import android.view.*
import android.widget.*

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
    private lateinit var heading: TextView
    private lateinit var updates: AppUpdates
    private var service: DisplayService? = null
    private var diagnosticExporting = false
    private var bound = false
    private var started = false
    private var resumed = false
    private var surfaceReady = false
    private var appliedSettings: String? = null
    private var displayArea = DisplayArea()
    private var appliedTouch: TouchMode? = null
    private var appliedEndpoint: TouchSender? = null
    private var requestedFPS = 0
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val current = (binder as DisplayService.LocalBinder).service
            service = current
            if (started) current.attach(this@MainActivity, ::render)
        }
        override fun onServiceDisconnected(name: ComponentName) {
            service = null; touchSurface.disable(); render()
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); Language.load(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS }
        window.setDecorFitsSystemWindows(false)
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK); isMotionEventSplittingEnabled = false }
        surface = SurfaceView(this); surface.holder.addCallback(this)
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        idleCover = GlassBackdrop(this); root.addView(idleCover, FrameLayout.LayoutParams(-1, -1))
        fpsOverlay = FpsOverlay(this); fpsOverlay.attach(root)
        touchSurface = TouchSurface(surface)
        surface.setOnTouchListener { view, event -> if (service?.streaming == true && resumed) touchSurface.onTouch(view, event) else false }
        updates = AppUpdates(this) { service?.streaming == true }
        buildMenu()
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
            if (r - l != or - ol || b - t != ob - ot) touchSurface.cancel()
            sizeMenu(); layoutVideo()
        }
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
        connectionInfo = text("", 13f, GlassColors.muted).apply { setPadding(0, dp(12), 0, dp(12)); setTextIsSelectable(true) }
        add(connectionInfo, top = 4)
        connectButton = button(tr("连接", "Connect")) { service?.requestConnection() }; add(connectButton, 48, 10)
        add(button(tr("应用更新", "App updates")) { updates.show() }, 44, 10)
        add(button(tr("导出诊断日志", "Export diagnostic logs")) { exportDiagnostics() }, 44, 10)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            add(button(tr("允许后台通知", "Allow background notifications")) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }, 44, 10)
            add(text(tr("切换应用后可从通知返回或断开，也可在 Mac 上断开。", "Return or disconnect from the notification while using other apps. You can also disconnect on the Mac."), 12f, GlassColors.muted), top = 8)
        }
        controlContainer = ScrollView(this).apply {
            isFillViewport = false; clipToPadding = false; setPadding(dp(12), dp(12), dp(12), dp(12)); addView(controls); visibility = visible
        }
        root.addView(controlContainer, FrameLayout.LayoutParams(dp(504), -2, Gravity.CENTER))
        updateMenuState(); sizeMenu()
    }
    private fun exportDiagnostics() {
        if (diagnosticExporting) return
        val title = "Nextend-diagnostics-Android-" + java.time.Instant.now().toString().replace(":", "-") + ".zip"
        runCatching {
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/zip").putExtra(Intent.EXTRA_TITLE, title), 80)
        }.onFailure { Toast.makeText(this, tr("无法打开保存位置，请稍后重试。", "Could not open the file picker. Try again."), Toast.LENGTH_LONG).show() }
    }
    @Deprecated("Platform Activity callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 80 || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        diagnosticExporting = true
        val owner = java.lang.ref.WeakReference(this)
        DiagnosticLog.export(applicationContext, uri) { success ->
            owner.get()?.takeIf { !it.isDestroyed && !it.isFinishing }?.let { activity ->
                activity.diagnosticExporting = false
                Toast.makeText(activity, if (success) tr("诊断日志已保存。", "Diagnostic logs saved.") else tr("日志导出失败，请换一个保存位置后重试。", "Could not export logs. Choose another location and retry."), Toast.LENGTH_LONG).show()
            }
        }
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
        val current = service
        heading.text = tr("等待连接", "Ready to connect")
        connectionInfo.text = current?.connectionMessage ?: if (current?.ready != true) tr("正在准备连接…", "Preparing connection…") else ""
        connectButton.isEnabled = current != null && !current.requesting
        connectButton.text = if (current?.requesting == true) tr("正在连接…", "Connecting…") else tr("连接", "Connect")
        fpsOverlay.updateVisibility(current?.streaming == true); sizeMenu()
    }
    private fun render() {
        if (!::root.isInitialized) return
        val current = service
        val active = current?.streaming == true
        if (active) updates.pause() else if (resumed && current?.ready == true) updates.maybeCheck()
        val settings = current?.settings
        if (settings != null && settings.toString() != appliedSettings) {
            appliedSettings = settings.toString(); applySettings(settings)
        }
        idleCover.visibility = if (active) View.GONE else View.VISIBLE
        controlContainer.visibility = if (active) View.GONE else View.VISIBLE
        fpsOverlay.showRate(current?.latestStats?.fps)
        if (resumed && active && current != null) {
            if (appliedTouch != current.touchMode || appliedEndpoint !== current.touchEndpoint || (current.touchMode.enabled && !touchSurface.enabled)) {
                appliedTouch = current.touchMode; appliedEndpoint = current.touchEndpoint
                touchSurface.configure(current.touchMode, current.touchEndpoint)
            }
        } else touchSurface.disable()
        if (current != null && requestedFPS != current.requestedFPS) {
            requestedFPS = current.requestedFPS
            val selected = display?.supportedModes?.filter { it.physicalWidth == display?.mode?.physicalWidth && it.physicalHeight == display?.mode?.physicalHeight }
                ?.minByOrNull { kotlin.math.abs(it.refreshRate - requestedFPS) }
            window.attributes = window.attributes.apply { preferredDisplayModeId = selected?.modeId ?: 0; preferredRefreshRate = requestedFPS.toFloat() }
        }
        layoutVideo(); updateMenuState()
        if (started && surfaceReady) current?.setSurface(this, surface.holder.surface)
    }
    private fun applySettings(value: org.json.JSONObject) {
        Language.select(this, value.getString("language") == "en")
        fpsOverlay.setEnabledByUser(value.getBoolean("showFPS")); fpsOverlay.setSize(value.getInt("size"))
        fpsOverlay.setFont(value.getInt("font")); fpsOverlay.setColor(Color.parseColor(value.getString("color")))
        fpsOverlay.setPosition(value.getDouble("x").toFloat(), value.getDouble("y").toFloat())
        value.optJSONObject("safeArea")?.let { area ->
            displayArea = DisplayArea(area.getBoolean("enabled"), area.getDouble("top"), area.getDouble("right"), area.getDouble("bottom"), area.getDouble("left"))
        }
        buildMenu(); layoutVideo()
    }
    private fun layoutVideo() {
        if (root.width <= 0 || root.height <= 0) return
        val area = displayArea.fit(root.width, root.height, service?.videoWidth ?: 3200, service?.videoHeight ?: 2136)
        val params = surface.layoutParams as FrameLayout.LayoutParams
        if (params.width != area.width || params.height != area.height || params.leftMargin != area.left || params.topMargin != area.top) {
            touchSurface.cancel()
            params.width = area.width; params.height = area.height
            params.leftMargin = area.left; params.topMargin = area.top; params.gravity = Gravity.TOP or Gravity.LEFT
            surface.layoutParams = params
        }
        // The FPS badge stays inside the same manually calibrated safe rectangle.
        val overlay = fpsOverlay.layoutParams as FrameLayout.LayoutParams
        if (overlay.width != area.width || overlay.height != area.height || overlay.leftMargin != area.left || overlay.topMargin != area.top) {
            overlay.width = area.width; overlay.height = area.height
            overlay.leftMargin = area.left; overlay.topMargin = area.top; overlay.gravity = Gravity.TOP or Gravity.LEFT
            fpsOverlay.layoutParams = overlay
        }
    }
    override fun onStart() {
        super.onStart(); started = true; DiagnosticLog.event("viewer.start")
        startForegroundService(Intent(this, DisplayService::class.java))
        bound = bindService(Intent(this, DisplayService::class.java), connection, Context.BIND_AUTO_CREATE)
    }
    override fun onResume() { super.onResume(); resumed = true; updates.resumed(); render() }
    override fun onPause() { resumed = false; touchSurface.disable(); super.onPause() }
    override fun onStop() {
        started = false; DiagnosticLog.event("viewer.stop")
        updates.pause()
        // onStop can precede surfaceDestroyed; finish native output release while still bound.
        service?.setSurface(this, null, waitForRelease = true)
        service?.detach(this); service = null
        if (bound) { unbindService(connection); bound = false }
        super.onStop()
    }
    override fun onDestroy() { updates.close(); super.onDestroy() }
    override fun onConfigurationChanged(configuration: Configuration) { super.onConfigurationChanged(configuration); root.post { sizeMenu(); layoutVideo() } }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1) buildMenu()
    }
    override fun surfaceCreated(holder: SurfaceHolder) { surfaceReady = true; render() }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { if (started) service?.setSurface(this, holder.surface) }
    override fun surfaceDestroyed(holder: SurfaceHolder) { surfaceReady = false; service?.setSurface(this, null, waitForRelease = true) }
}
