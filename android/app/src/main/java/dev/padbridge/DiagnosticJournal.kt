package dev.padbridge

import java.io.File
import java.time.Instant
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

/** Bounded asynchronous storage. No disk operations on a transport, codec or UI caller. */
class DiagnosticJournal(private val directory: File, private val limit: Int = 1024 * 1024, private val retained: Int = 4) {
    private val disk = Any()
    private val dropped = AtomicInteger()
    private val totalDropped = AtomicInteger()
    private val writeFailures = AtomicInteger()
    private val lastWriteError = java.util.concurrent.atomic.AtomicReference("")
    private val writer = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(256),
        { action -> Thread(action, "Nextend-diagnostics").apply { isDaemon = true } },
        { _, _ -> dropped.incrementAndGet(); totalDropped.incrementAndGet() })
    init { require(limit >= 4096 && retained in 2..8) }

    fun event(event: String, session: String? = null, details: Map<String, Any?> = emptyMap()) {
        val row = linkedMapOf<String, Any?>("schema" to 1, "platform" to "Android",
            "timeUTC" to Instant.now().toString(), "uptimeSeconds" to System.nanoTime() / 1e9,
            "event" to DiagnosticPrivacy.text(event), "details" to DiagnosticPrivacy.fields(details))
        session?.takeIf { it.matches(Regex("[a-fA-F0-9-]{36}")) }?.let { row["session"] = it.uppercase() }
        writer.execute {
            val lost = dropped.getAndSet(0)
            if (lost > 0) row["droppedLogEvents"] = lost
            val bytes = (json(row) + "\n").toByteArray(Charsets.UTF_8)
            runCatching { synchronized(disk) { append(bytes) } }.onFailure {
                writeFailures.incrementAndGet(); lastWriteError.set(it.javaClass.simpleName)
            }
        }
    }
    fun flush(timeoutMillis: Long = 3000): Boolean {
        val done = CountDownLatch(1)
        writer.execute { done.countDown() }
        return done.await(timeoutMillis, TimeUnit.MILLISECONDS)
    }
    /** Background caller only. Snapshot is bounded and cannot race with rotation. */
    fun snapshot(): Map<String, ByteArray> {
        check(flush()) { "Diagnostic storage is busy. Try again." }
        return synchronized(disk) {
            check(directory.isDirectory) { "Diagnostic storage is unavailable" }
            (0 until retained).mapNotNull { index ->
                val file = File(directory, filename(index))
                if (!file.isFile) null else {
                    check(file.length() <= limit) { "Diagnostic file exceeds its limit" }
                    file.name to file.readBytes()
                }
            }.toMap() + ("storage-status.json" to (json(mapOf("writeFailures" to writeFailures.get(),
                "lastWriteError" to lastWriteError.get(), "droppedLogEvents" to totalDropped.get(),
                "scope" to "current-process")) + "\n").toByteArray(Charsets.UTF_8))
        }
    }
    fun close() { writer.shutdown(); writer.awaitTermination(3, TimeUnit.SECONDS) }
    private fun filename(index: Int) = if (index == 0) "events.jsonl" else "events.$index.jsonl"
    private fun append(bytes: ByteArray) {
        check(bytes.size <= limit) { "Diagnostic record exceeds its limit" }
        check(directory.isDirectory || directory.mkdirs()) { "Could not create diagnostic directory" }
        val active = File(directory, filename(0))
        // Repair before rotation, otherwise a full file could archive its partial tail.
        if (active.isFile && active.length() > 0) {
            java.io.RandomAccessFile(active, "rw").use { file ->
                file.seek(file.length() - 1)
                if (file.read() != 10) {
                    val existing = active.readBytes()
                    file.setLength((existing.indexOfLast { it == 10.toByte() } + 1).toLong())
                }
            }
        }
        if (active.length() + bytes.size > limit) {
            val oldest = File(directory, filename(retained - 1))
            check(!oldest.exists() || oldest.delete())
            for (index in retained - 2 downTo 0) {
                val old = File(directory, filename(index))
                check(!old.exists() || old.renameTo(File(directory, filename(index + 1))))
            }
        }
        java.io.RandomAccessFile(active, "rw").use { file ->
            val length = file.length()
            file.seek(length)
            try { file.write(bytes) } catch (error: java.io.IOException) {
                runCatching { file.setLength(length) }; throw error
            }
        }
    }
    private fun json(value: Any?): String = when (value) {
        null -> "null"
        is String -> "\"" + value.flatMap { c -> when(c) {
            '"' -> "\\\"".toList()
            '\\' -> "\\\\".toList()
            else -> if (c < ' ') "\\u%04x".format(c.code).toList() else listOf(c)
        } }.joinToString("") + "\""
        is Boolean -> value.toString()
        is Number -> if (value.toDouble().isFinite()) value.toString() else "null"
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { json(it.key.toString()) + ":" + json(it.value) }
        else -> "null"
    }
}
object DiagnosticPrivacy {
    private val patterns = listOf(
        Regex("""(?i)(?:device|serial(?:number|no)?)\s*[:=]?\s*["'][^"']+["']""") to "<device>",
        Regex("(?i)(?:pairing[._ -]?key|password|secret|token|cookie)\\s*[:=]\\s*[^\\s,;]+") to "<redacted>",
        Regex("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b") to "<ip>",
        Regex("(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f:%._-]*") to "<address>",
        Regex("/Users/[^/\\s]+") to "/Users/<user>",
        Regex("\\b[A-Za-z0-9+/_=-]{32,}\\b") to "<identifier>"
    )
    fun text(value: String): String = patterns.fold(value.take(1024)) { result, (pattern, replacement) -> pattern.replace(result, replacement) }
    fun fields(values: Map<String, Any?>): Map<String, Any?> = values.entries.sortedBy { it.key }.take(24)
        .filterNot { item -> listOf("password", "secret", "token", "cookie", "serial", "ssid", "address", "host", "path", "key").any { item.key.lowercase().contains(it) } }
        .associate { item -> item.key.take(64) to when(val value = item.value) {
            is String -> text(value)
            is Number, is Boolean -> value
            else -> null
        } }
}
