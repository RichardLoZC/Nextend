package android.os

// Deterministic looper for compiling the actual discovery adapter on the JVM.
class Looper {
    companion object {
        private val instance = Looper()
        fun getMainLooper() = instance
        private data class Entry(val owner: Handler, val task: Runnable, val at: Long, val order: Int)
        private val queue = mutableListOf<Entry>()
        private var now = 0L
        private var next = 0
        internal fun post(owner: Handler, task: Runnable, delay: Long) { queue.add(Entry(owner, task, now + delay, next++)) }
        internal fun remove(owner: Handler, task: Runnable?) { queue.removeAll { it.owner === owner && (task == null || it.task === task) } }
        fun advance(ms: Long = 0) {
            val until = now + ms; var count = 0
            while (true) {
                val entry = queue.filter { it.at <= until }.minWithOrNull(compareBy<Entry> { it.at }.thenBy { it.order }) ?: break
                queue.remove(entry); now = entry.at; entry.task.run()
                check(++count < 1000) { "Unbounded discovery retry" }
            }
            now = until
        }
    }
}
class Handler(looper: Looper) {
    fun post(task: Runnable): Boolean { Looper.post(this, task, 0); return true }
    fun postDelayed(task: Runnable, delay: Long): Boolean { Looper.post(this, task, delay); return true }
    fun removeCallbacks(task: Runnable) { Looper.remove(this, task) }
    fun removeCallbacksAndMessages(token: Any?) { Looper.remove(this, null) }
}
