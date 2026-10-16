package dev.padbridge

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import java.util.Locale
import kotlin.math.ceil

/** A stationary transparent view draws the badge; dragging never moves or relays out the video overlay. */
class FpsOverlay(context: Context) : View(context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    var enabledByUser = prefs.getBoolean("fps.enabled", false)
        private set
    var sizeSp = prefs.getInt("fps.size", 20).coerceIn(12, 64)
        private set
    var textColorValue = prefs.getInt("fps.color", Color.WHITE)
        private set
    var fontIndex = prefs.getInt("fps.font", 1).coerceIn(0, 2)
        private set
    private val density = resources.displayMetrics.density
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = density }
    private val badge = RectF()
    private var position = OverlayPosition(prefs.getFloat("fps.x", .03f), prefs.getFloat("fps.y", .03f))
    private var badgeWidth = 0f; private var badgeHeight = 0f
    private var rateText = "— fps"
    private var latestText = rateText
    private var gesture: OverlayDrag? = null
    private var activePointer = MotionEvent.INVALID_POINTER_ID
    private var hoveringBadge = false

    init {
        visibility = GONE
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        isClickable = true; isFocusable = true
        applyStyle(); showRate(null)
    }
    fun attach(parent: FrameLayout) { parent.addView(this, FrameLayout.LayoutParams(-1, -1)) }
    fun showRate(rate: Double?) {
        latestText = if (rate != null && rate.isFinite()) String.format(Locale.ROOT, "%.1f fps", rate.coerceAtLeast(0.0)) else "— fps"
        // Keep geometry and text stable under the finger; apply the latest sample when released.
        if (gesture == null) applyRate()
    }
    private fun applyRate() {
        rateText = latestText
        contentDescription = rateText + tr("，拖动调整位置，点按打开菜单", ", drag to move, tap for controls")
        measureBadge(); place(); invalidate()
    }
    fun setEnabledByUser(value: Boolean) { enabledByUser = value; prefs.edit().putBoolean("fps.enabled", value).apply() }
    fun setSize(value: Int) { sizeSp = value.coerceIn(12, 64); prefs.edit().putInt("fps.size", sizeSp).apply(); applyStyle() }
    fun setColor(value: Int) { textColorValue = value; prefs.edit().putInt("fps.color", value).apply(); applyStyle() }
    fun setFont(value: Int) { fontIndex = value.coerceIn(0, 2); prefs.edit().putInt("fps.font", fontIndex).apply(); applyStyle() }
    private fun applyStyle() {
        textPaint.textSize = sizeSp * resources.displayMetrics.scaledDensity
        textPaint.color = textColorValue
        textPaint.typeface = when (fontIndex) { 0 -> Typeface.create("sans-serif", Typeface.BOLD); 2 -> Typeface.create("serif", Typeface.BOLD); else -> Typeface.create("monospace", Typeface.BOLD) }
        val luminance = .2126 * Color.red(textColorValue) + .7152 * Color.green(textColorValue) + .0722 * Color.blue(textColorValue)
        backgroundPaint.color = if (luminance < 110) 0xDCFFFFFF.toInt() else 0xB0000000.toInt()
        edgePaint.color = if (luminance < 110) 0x50000000 else 0x80FFFFFF.toInt()
        measureBadge(); place(); invalidate()
    }
    private fun measureBadge() {
        badgeWidth = ceil(maxOf(textPaint.measureText(rateText), textPaint.measureText("000.0 fps")) + 16 * density)
        val metrics = textPaint.fontMetrics
        badgeHeight = ceil(metrics.descent - metrics.ascent + 8 * density)
    }
    fun updateVisibility(streaming: Boolean) {
        visibility = if (streaming && enabledByUser) VISIBLE else GONE
        if (visibility != VISIBLE) finishGesture(false)
        if (!streaming) showRate(null)
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { super.onSizeChanged(w, h, oldw, oldh); place() }
    private fun place() {
        if (gesture != null) moveBadge(badge.left, badge.top)
        else {
            val point = position.pixels(width, height, ceil(badgeWidth).toInt(), ceil(badgeHeight).toInt())
            moveBadge(point.first, point.second)
        }
    }
    private fun moveBadge(left: Float, top: Float) {
        val x = left.coerceIn(0f, (width - badgeWidth).coerceAtLeast(0f))
        val y = top.coerceIn(0f, (height - badgeHeight).coerceAtLeast(0f))
        badge.set(x, y, x + badgeWidth, y + badgeHeight)
        invalidate()
    }
    private fun savePosition() {
        position = OverlayPosition.fromPixels(badge.left, badge.top, width, height, ceil(badgeWidth).toInt(), ceil(badgeHeight).toInt())
        prefs.edit().putFloat("fps.x", position.x).putFloat("fps.y", position.y).apply()
    }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawRoundRect(badge, 7 * density, 7 * density, backgroundPaint)
        if (gesture?.dragged == true) canvas.drawRoundRect(badge, 7 * density, 7 * density, edgePaint)
        canvas.drawText(rateText, badge.left + 8 * density, badge.top + 4 * density - textPaint.fontMetrics.ascent, textPaint)
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (!badge.contains(event.x, event.y)) return false
                activePointer = event.getPointerId(0)
                gesture = OverlayDrag(event.x, event.y, badge.left, badge.top, ViewConfiguration.get(context).scaledTouchSlop.toFloat(), badgeHeight + 20 * density)
                parent.requestDisallowInterceptTouchEvent(true)
                return true
            }
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                val drag = gesture ?: return false
                val index = event.findPointerIndex(activePointer)
                if (index < 0) { finishGesture(false); return true }
                drag.move(event.getX(index), event.getY(index), (height - badgeHeight).coerceAtLeast(0f))?.let { moveBadge(it.first, it.second) }
                if (event.actionMasked == MotionEvent.ACTION_UP) finishGesture(true)
            }
            MotionEvent.ACTION_POINTER_UP -> if (event.getPointerId(event.actionIndex) == activePointer) finishGesture(false)
            MotionEvent.ACTION_CANCEL -> finishGesture(false)
        }
        return gesture != null || event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL
    }
    private fun finishGesture(allowClick: Boolean) {
        val drag = gesture ?: return
        if (drag.dragged) savePosition()
        gesture = null; activePointer = MotionEvent.INVALID_POINTER_ID
        parent?.requestDisallowInterceptTouchEvent(false)
        applyRate()
        if (allowClick && !drag.dragged) performClick()
    }
    override fun performClick(): Boolean { super.performClick(); return true }
    override fun dispatchHoverEvent(event: MotionEvent): Boolean {
        val inside = badge.contains(event.x, event.y)
        if (!inside && hoveringBadge) {
            val exit = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_HOVER_EXIT }
            super.dispatchHoverEvent(exit); exit.recycle()
        }
        hoveringBadge = inside && event.actionMasked != MotionEvent.ACTION_HOVER_EXIT
        return if (inside) super.dispatchHoverEvent(event) else false
    }
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        val bounds = Rect(); badge.roundOut(bounds); info.setBoundsInParent(bounds)
        val origin = IntArray(2); getLocationOnScreen(origin)
        info.setBoundsInScreen(Rect(bounds).apply { offset(origin[0], origin[1]) })
        if (android.os.Build.VERSION.SDK_INT >= 35) {
            getLocationInWindow(origin)
            info.setBoundsInWindow(Rect(bounds).apply { offset(origin[0], origin[1]) })
        }
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020001, tr("移到左上角", "Move to top left")))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020002, tr("移到右上角", "Move to top right")))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020003, tr("移到左下角", "Move to bottom left")))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020004, tr("移到右下角", "Move to bottom right")))
    }
    override fun performAccessibilityAction(action: Int, arguments: android.os.Bundle?): Boolean {
        val corner = when (action) { 0x01020001 -> OverlayPosition(0f, 0f); 0x01020002 -> OverlayPosition(1f, 0f); 0x01020003 -> OverlayPosition(0f, 1f); 0x01020004 -> OverlayPosition(1f, 1f); else -> null }
        if (corner != null) { finishGesture(false); position = corner; place(); savePosition(); return true }
        return super.performAccessibilityAction(action, arguments)
    }
}
