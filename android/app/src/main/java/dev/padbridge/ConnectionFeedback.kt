package dev.padbridge

/** A recovered listener must not erase the last useful session failure. */
class ConnectionFeedback {
    private var sessionMessage: UiText? = null
    private val listenerMessages = linkedMapOf<Boolean, UiText>()
    val message: UiText? get() = sessionMessage ?: listenerMessages.values.firstOrNull()
    fun beginAttempt() { sessionMessage = null }
    fun session(active: Boolean, message: UiText?) {
        if (active) sessionMessage = null else if (message != null) sessionMessage = message
    }
    fun listener(wireless: Boolean, available: Boolean) {
        if (available) listenerMessages.remove(wireless)
        else listenerMessages[wireless] = UiText("连接接收器暂不可用，正在自动重试。", "Connection listener unavailable. Retrying automatically.")
    }
    fun clearListeners() { listenerMessages.clear() }
}
