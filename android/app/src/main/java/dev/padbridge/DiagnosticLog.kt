package dev.padbridge

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class NextendApplication : Application() {
    override fun onCreate() { super.onCreate(); DiagnosticLog.initialize(this) }
}

object DiagnosticLog {
    @Volatile private var journal: DiagnosticJournal? = null
    private val exporting = AtomicBoolean()
    @Synchronized fun initialize(context: Context) {
        if (journal != null) return
        journal = DiagnosticJournal(File(context.filesDir, "diagnostics"))
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        event("app.launch", details = mapOf("version" to info.versionName, "build" to info.longVersionCode,
            "os" to Build.VERSION.RELEASE, "api" to Build.VERSION.SDK_INT, "model" to Build.MODEL))
        runCatching {
            context.getSystemService(ActivityManager::class.java).getHistoricalProcessExitReasons(context.packageName, 0, 3).forEach {
                event("app.previous_exit", details = mapOf("time" to it.timestamp, "reason" to it.reason,
                    "status" to it.status, "description" to it.description))
            }
        }
    }
    fun event(event: String, session: String? = null, details: Map<String, Any?> = emptyMap()) {
        journal?.event(event, session, details)
    }
    fun export(context: Context, uri: Uri, completion: (Boolean) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        if (!exporting.compareAndSet(false, true)) { main.post { completion(false) }; return }
        val app = context.applicationContext
        event("diagnostics.export")
        Thread({
            val result = runCatching {
                val snapshot = checkNotNull(journal).snapshot()
                val stream = app.contentResolver.openOutputStream(uri, "wt") ?: error("Output unavailable")
                ZipOutputStream(stream).use { zip ->
                    fun entry(name: String, bytes: ByteArray) {
                        zip.putNextEntry(ZipEntry("Nextend-diagnostics/$name")); zip.write(bytes); zip.closeEntry()
                    }
                    entry("README.txt", ("Nextend diagnostic log, schema 1. Timestamps are UTC.\n" +
                        "Session IDs match both updated clients. Retains up to 4 MiB per device.\n" +
                        "No screen images, video, touch coordinates, pairing keys or automatic uploads.\n" +
                        "storage-status.json reports dropped events and write failures for this process.\n" +
                        "Some error text is redacted. Older app sessions may have no logs.\n").toByteArray())
                    snapshot.forEach { (name, bytes) -> entry(name, bytes) }
                }
            }.isSuccess
            exporting.set(false)
            main.post { completion(result) }
        }, "Nextend-diagnostic-export").apply { isDaemon = true; start() }
    }
}
