package dev.padbridge

import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration

class TouchSurface(private val view: View) : View.OnTouchListener {
    var enabled = false
        private set
    private var mode = TouchMode(false, 0, 0, 0)
    private var sender: TouchSender? = null
    private var gesture: TouchGesture? = null
    private var size: Pair<Int, Int>? = null
    private val configuration = ViewConfiguration.get(view.context)
    private val taps = TouchTapHistory(ViewConfiguration.getDoubleTapTimeout().toLong(), configuration.scaledDoubleTapSlop.toFloat())
    fun configure(value: TouchMode, endpoint: TouchSender?) {
        cancel(); mode = value; sender = endpoint; enabled = value.enabled && endpoint != null
    }
    fun cancel() { gesture?.cancel(); gesture = null; size = null; taps.clear() }
    fun disable() { cancel(); enabled = false; sender = null }
    override fun onTouch(v: View, event: MotionEvent): Boolean {
        if (!enabled) return false
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) { cancel(); return true }
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            val point = TouchPoint(event.getPointerId(0), event.getX(0), event.getY(0))
            val tapDrag = mode.trackpad && taps.consume(point, event.eventTime)
            cancel()
            val epoch = mode.epoch; val endpoint = sender
            size = view.width to view.height
            gesture = TouchGesture(TouchViewport(view.width, view.height),
                configuration.scaledTouchSlop.toFloat(),
                { command -> endpoint?.offer(epoch, command) }, mode.trackpad, tapDrag,
                { point, time -> if (mode.trackpad) taps.remember(point, time) })
        }
        if (size != (view.width to view.height)) { cancel(); return true }
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> TouchGesture.Action.DOWN
            MotionEvent.ACTION_POINTER_DOWN -> TouchGesture.Action.POINTER_DOWN
            MotionEvent.ACTION_MOVE -> TouchGesture.Action.MOVE
            MotionEvent.ACTION_POINTER_UP -> TouchGesture.Action.POINTER_UP
            MotionEvent.ACTION_UP -> TouchGesture.Action.UP
            MotionEvent.ACTION_CANCEL -> TouchGesture.Action.CANCEL
            else -> return true
        }
        // Android may cancel only the palm/stylus pointer on POINTER_UP.
        if (event.flags and MotionEvent.FLAG_CANCELED != 0) { cancel(); return true }
        gesture?.accept(action, (0 until event.pointerCount).map { TouchPoint(event.getPointerId(it), event.getX(it), event.getY(it)) },
            event.getPointerId(event.actionIndex), event.eventTime)
        return true
    }
}
