package dev.padbridge

import android.content.Context
import android.graphics.*
import android.graphics.drawable.Drawable
import android.view.View

object GlassColors {
    val ink = Color.rgb(21, 47, 42)
    val muted = Color.rgb(73, 104, 94)
    val accent = Color.rgb(26, 100, 87)
    val mint = Color.rgb(177, 225, 214)
}

// The video remains a SurfaceView. These quiet gradients approximate the visual
// language; they do not read or blur video buffers, nor claim Apple's refraction.
class GlassPanelDrawable(private val density: Float, private val dark: Boolean = false, private val radius: Float = 28f) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var drawableAlpha = 255
    override fun draw(canvas: Canvas) {
        val rect = RectF(bounds).apply { inset(density, density) }
        // Paint color alpha also modulates a shader. Reset it every pass,
        // otherwise the previous border's alpha fades the next background.
        paint.alpha = drawableAlpha
        paint.shader = LinearGradient(rect.left, rect.top, rect.right, rect.bottom,
            if (dark) intArrayOf(0xF0276659.toInt(), 0xF017443D.toInt()) else intArrayOf(0xF4FFFFFF.toInt(), 0xE6E5F1EB.toInt(), 0xEED5EAE4.toInt()), null, Shader.TileMode.CLAMP)
        paint.style = Paint.Style.FILL; canvas.drawRoundRect(rect, radius*density, radius*density, paint)
        paint.shader = null; paint.style = Paint.Style.STROKE; paint.strokeWidth = density
        paint.color = if (dark) 0x55FFFFFF else 0xE6FFFFFF.toInt(); paint.alpha = paint.alpha * drawableAlpha / 255
        canvas.drawRoundRect(rect, radius*density, radius*density, paint)
        paint.color = if (dark) 0x22FFFFFF else 0x7AFFFFFF; paint.alpha = paint.alpha * drawableAlpha / 255; paint.strokeWidth = density*1.2f
        canvas.drawLine(rect.left+radius*density, rect.top+density, rect.right-radius*density, rect.top+density, paint)
    }
    override fun setAlpha(alpha: Int) { drawableAlpha = alpha.coerceIn(0,255); invalidateSelf() }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter; invalidateSelf() }
    @Deprecated("Deprecated in Java") override fun getOpacity() = PixelFormat.TRANSLUCENT
}

class GlassBackdrop(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun isOpaque() = true
    override fun onDraw(canvas: Canvas) {
        paint.alpha = 255; paint.style = Paint.Style.FILL
        paint.shader = LinearGradient(0f, height.toFloat(), width.toFloat(), 0f,
            intArrayOf(Color.rgb(219,238,229), Color.rgb(155,197,187), Color.rgb(212,231,231)), null, Shader.TileMode.CLAMP)
        canvas.drawRect(0f,0f,width.toFloat(),height.toFloat(),paint)
        paint.shader = null; paint.color = 0x4AFFFFFF
        val wave = Path().apply {
            moveTo(-100f,height*.36f)
            cubicTo(width*.33f,height*1.4f,width*.66f,-height*.3f,width+100f,height*.6f)
            lineTo(width+100f,height+100f); lineTo(-100f,height+100f); close()
        }
        canvas.drawPath(wave,paint)
        paint.style = Paint.Style.STROKE; paint.strokeWidth = resources.displayMetrics.density; paint.color = 0x80FFFFFF.toInt()
        canvas.drawPath(wave,paint); paint.style = Paint.Style.FILL
    }
}

class BridgeIllustration(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun onDraw(canvas: Canvas) {
        val scale = minOf(width/400f,height/180f)
        canvas.save(); canvas.translate((width-400f*scale)/2f,(height-180f*scale)/2f); canvas.scale(scale,scale)
        fun pane(rect: RectF, light: Boolean) {
            paint.style = Paint.Style.FILL; paint.alpha = 255
            paint.shader = LinearGradient(rect.left,rect.top,rect.right,rect.bottom,
                if(light) intArrayOf(0xFFB2E3D1.toInt(),0xFFE6F7EF.toInt()) else intArrayOf(0xFF1D7466.toInt(),0xFF15464B.toInt()),null,Shader.TileMode.CLAMP)
            canvas.drawRoundRect(rect,14f,14f,paint); paint.shader=null
            paint.style=Paint.Style.STROKE;paint.color=Color.WHITE;paint.strokeWidth=2f;canvas.drawRoundRect(rect,14f,14f,paint)
            paint.style=Paint.Style.FILL
        }
        pane(RectF(20f,10f,247f,142f),false)
        paint.color=0xDDFFFFFF.toInt();canvas.drawRoundRect(RectF(3f,144f,264f,153f),4f,4f,paint)
        pane(RectF(218f,64f,380f,173f),true)
        paint.color=0x5544584E;canvas.drawCircle(298f,71f,1.5f,paint)
        canvas.restore()
    }
}
