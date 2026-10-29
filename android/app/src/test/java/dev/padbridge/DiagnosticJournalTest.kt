package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DiagnosticJournalTest {
    @Test fun rotationConcurrentLoadAndExportAllowlist() {
        val root = Files.createTempDirectory("diagnostics-test").toFile()
        val journal = DiagnosticJournal(root, limit = 4096)
        try {
            val workers = Executors.newFixedThreadPool(8)
            repeat(2000) { n -> workers.submit { journal.event("load", details = mapOf("n" to n, "message" to "x".repeat(200))) } }
            workers.shutdown(); assertTrue(workers.awaitTermination(10, TimeUnit.SECONDS))
            assertTrue(journal.flush())
            File(root, "pairing.key").writeText("never-export")
            journal.event("last-record")
            val snapshot = journal.snapshot()
            assertTrue(snapshot.isNotEmpty()); assertTrue(snapshot.size <= 5)
            assertFalse(snapshot.containsKey("pairing.key"))
            assertTrue(snapshot.values.all { it.size <= 4096 })
            assertTrue(snapshot.values.any { it.toString(Charsets.UTF_8).contains("last-record") })
            snapshot.values.forEach { bytes -> bytes.toString(Charsets.UTF_8).lineSequence().filter { it.isNotEmpty() }.forEach {
                assertTrue(it.startsWith("{") && it.endsWith("}"))
            } }
        } finally { journal.close(); root.deleteRecursively() }
    }
    @Test fun privacyAndUnicodeEscaping() {
        val root = Files.createTempDirectory("diagnostics-privacy").toFile()
        val journal = DiagnosticJournal(root)
        try {
            journal.event("privacy", details = mapOf("password" to "do-not-export", "message" to "quote \" newline\n用户 192.168.2.42 /Users/private/file token=do-not-export device 'ABCDEF0123456789'", "number" to Double.NaN))
            val text = journal.snapshot().values.joinToString("") { it.toString(Charsets.UTF_8) }
            assertFalse(text.contains("do-not-export")); assertFalse(text.contains("ABCDEF0123456789")); assertFalse(text.contains("192.168.2.42")); assertFalse(text.contains("/Users/private"))
            assertTrue(text.contains("用户")); assertTrue(text.contains("\\u000a")); assertTrue(text.contains("\\\""))
            assertTrue(text.contains("\"number\":null"))
        } finally { journal.close(); root.deleteRecursively() }
    }
    @Test fun readOnlyFailureIsReportedAndPartialTailIsRepaired() {
        val root = Files.createTempDirectory("diagnostics-tail").toFile()
        val journal = DiagnosticJournal(root, limit = 4096)
        try {
            journal.event("first"); assertTrue(journal.flush())
            val file = File(root, "events.jsonl")
            assertTrue(file.setReadOnly())
            journal.event("unwritable"); assertTrue(journal.flush())
            assertTrue(file.setWritable(true, true))
            file.writeText("{\"event\":\"padding\",\"message\":\"" + "x".repeat(3900) + "\"}\n{\"unfinished")
            journal.event("recovered", details = mapOf("message" to "short ".repeat(100))); val snapshot = journal.snapshot()
            val health = snapshot.getValue("storage-status.json").toString(Charsets.UTF_8)
            assertTrue(health.contains("\"writeFailures\":1"))
            val lines = snapshot.values.joinToString("") { it.toString(Charsets.UTF_8) }
            assertFalse(lines.contains("unfinished")); assertTrue(lines.contains("recovered"))
            assertTrue(snapshot.getValue("events.1.jsonl").toString(Charsets.UTF_8).contains("padding"))
        } finally { journal.close(); root.deleteRecursively() }
    }
    @Test fun failedStorageDoesNotEscapeButExportFails() {
        val parent = Files.createTempDirectory("diagnostics-storage").toFile()
        val unusable = File(parent, "file").apply { writeText("not a directory") }
        val journal = DiagnosticJournal(unusable)
        try {
            journal.event("storage-failure")
            assertTrue(journal.flush())
            try { journal.snapshot(); fail("Export must report unavailable storage") } catch (_: IllegalStateException) {}
        } finally { journal.close(); parent.deleteRecursively() }
    }
}
