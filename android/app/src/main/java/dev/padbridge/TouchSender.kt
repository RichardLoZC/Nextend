package dev.padbridge

import org.json.JSONObject
import java.util.ArrayDeque

/** One bounded writer per authenticated session. UI gestures never write sockets.
 * Mode epochs reject events queued before an off/on transition or reconnect. */
class TouchSender(private val width: Int, private val height: Int,
                  private val send: (JSONObject) -> Unit, private val fail: () -> Unit) : AutoCloseable {
    private data class Entry(val epoch: Int, val command: TouchCommand? = null, val enabled: Boolean = false)
    private val lock = Object()
    private val queue = ArrayDeque<Entry>()
    private var running = true
    private var enabled = false
    private var epoch = 0
    private var held: TouchCommand? = null
    private val worker = Thread({ writeLoop() }, "Nextend-touch").apply { start() }
    fun setMode(value: JSONObject): TouchMode = synchronized(lock) {
        val next = value.get("epoch")
        require(next is Number && next.toDouble() == next.toInt().toDouble() && next.toInt() > epoch && next.toInt() > 0)
        val active = value.get("enabled"); require(active is Boolean)
        require(value.optString("mode", "direct") in listOf("direct", "trackpad"))
        epoch = next.toInt(); enabled = active; held = null; queue.clear()
        queue.addLast(Entry(epoch, enabled = enabled)); lock.notifyAll()
        TouchMode(enabled, epoch, width, height, value.optString("mode", "direct") == "trackpad")
    }
    fun offer(expectedEpoch: Int, command: TouchCommand): Boolean {
        var overflow = false
        synchronized(lock) {
            if (!running || !enabled || expectedEpoch != epoch) return false
            // Coalesce only consecutive motion, never DOWN/UP/CANCEL boundaries.
            if (command.phase in listOf("move", "hover") && queue.peekLast()?.command?.phase == command.phase) {
                val prior = queue.removeLast().command!!
                val combined = command.copy(dx = (prior.dx + command.dx).coerceIn(-1.0, 1.0), dy = (prior.dy + command.dy).coerceIn(-1.0, 1.0))
                queue.addLast(Entry(epoch, combined))
                if (command.phase == "move") held = command.copy(phase = "move", dx = 0.0, dy = 0.0)
                lock.notifyAll(); return true
            }
            if (queue.size >= 64) { enabled = false; held = null; queue.clear(); overflow = true }
            else {
                queue.addLast(Entry(epoch, command))
                held = when (command.phase) {
                    "down", "move" -> command.copy(phase = "move", dx = 0.0, dy = 0.0)
                    "up", "cancel" -> null
                    else -> held
                }
                lock.notifyAll()
            }
        }
        if (overflow) fail()
        return !overflow
    }
    private fun writeLoop() {
        try {
            while (true) {
                val entry = synchronized(lock) {
                    if (running && queue.isEmpty()) lock.wait(500)
                    if (!running) return
                    if (queue.isNotEmpty()) queue.removeFirst()
                    else if (enabled && held != null) Entry(epoch, held) else null
                } ?: continue
                val command = entry.command
                val value = JSONObject().put("epoch", entry.epoch)
                if (command == null) value.put("type", "touch-state").put("enabled", entry.enabled)
                else {
                    value.put("type", "touch").put("phase", command.phase)
                    if (command.phase != "cancel") value.put("x", command.x).put("y", command.y)
                    if (command.phase in listOf("scroll", "move", "hover")) value.put("dx", command.dx).put("dy", command.dy)
                }
                send(value)
            }
        } catch (_: Exception) { fail() }
    }
    override fun close() { synchronized(lock) { running = false; enabled = false; held = null; queue.clear(); lock.notifyAll() } }
}
