package dev.padbridge

import android.content.Context
import java.util.Locale

object Language {
    @Volatile var english = !Locale.getDefault().language.startsWith("zh")
        private set
    fun load(context: Context) {
        val saved = context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString("language", null)
        english = saved?.let { it == "en" } ?: !Locale.getDefault().language.startsWith("zh")
    }
    fun select(context: Context, useEnglish: Boolean) {
        english = useEnglish
        context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putString("language", if (useEnglish) "en" else "zh").apply()
    }
}
data class UiText(val zh: String, val en: String) { val text: String get() = if (Language.english) en else zh }
fun tr(zh: String, en: String) = if (Language.english) en else zh

/** Actual MediaCodec frame-rendered callbacks per elapsed second, not display Hz. */
data class RenderStats(val fps: Double, val decodeFps: Double, val displayHz: Float, val dropped: Long, val thermal: Int)
