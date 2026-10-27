package dev.padbridge

import android.app.AlertDialog
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ProgressBar
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection

/** Foreground checks only. Network work never owns the display session or an Activity after close. */
internal class AppUpdates(private val activity: MainActivity, private val streaming: () -> Boolean) {
    companion object { const val BASE = "https://linkbio.gz.cn/wp-content/uploads/apps/nextend/" }
    private data class Release(val build: Long, val version: String, val path: String, val size: Long, val hash: String, val minSdk: Int, val notes: String)
    private val prefs = activity.getSharedPreferences("updates", 0)
    private val executor = Executors.newSingleThreadExecutor()
    private val timeouts = Executors.newSingleThreadScheduledExecutor()
    private val generation = AtomicInteger()
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var closed = false
    private var busy = false
    private var dialog: AlertDialog? = null
    private var pending: Pair<File, Release>? = null
    private fun current() = activity.packageManager.getPackageInfo(activity.packageName, 0)
    private fun live(token: Int) = !closed && token == generation.get()
    private fun ui(token: Int, block: () -> Unit) = activity.runOnUiThread { if (live(token) && !activity.isFinishing && !activity.isDestroyed) block() }
    private fun present(builder: AlertDialog.Builder) {
        dismiss()
        if (!closed && !streaming() && !activity.isFinishing && !activity.isDestroyed) dialog = builder.create().also { it.show() }
    }
    private fun error(message: String) { present(AlertDialog.Builder(activity).setTitle(tr("应用更新", "App updates")).setMessage(message).setPositiveButton(tr("知道了", "OK"), null)) }
    fun show() {
        if (busy) return
        val automatic = CheckBox(activity).apply { text = tr("自动检查更新（每 6 小时一次）", "Check automatically (every 6 hours)"); isChecked = prefs.getBoolean("automatic", true) }
        automatic.setOnCheckedChangeListener { _, checked -> prefs.edit().putBoolean("automatic", checked).apply() }
        val box = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 16, 32, 16); addView(automatic) }
        present(AlertDialog.Builder(activity).setTitle("Nextend ${current().versionName}").setMessage(tr("从 NAS 获取更新，安装前会保留配对和设置。", "Get updates from the NAS. Pairing and settings are retained."))
            .setView(box).setPositiveButton(tr("检查更新", "Check for updates")) { _, _ -> check(true) }.setNegativeButton(tr("关闭", "Close"), null))
    }
    fun maybeCheck() {
        if (closed || busy || dialog?.isShowing == true || streaming() || !prefs.getBoolean("automatic", true)) return
        val age = System.currentTimeMillis() - prefs.getLong("lastAttempt", 0)
        if (age in 0 until 6L * 3600 * 1000) return
        check(false)
    }
    private fun check(manual: Boolean) {
        if (busy || streaming()) return
        busy = true; val token = generation.incrementAndGet()
        prefs.edit().putLong("lastAttempt", System.currentTimeMillis()).apply()
        if (manual) showProgress(token, tr("检查更新…", "Checking for updates…"))
        executor.execute {
            try {
                val raw = fetch("updates/manifest.json", token) { input, length ->
                    require(length <= UpdatePolicy.MAX_MANIFEST) { "更新清单过大" }
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(4096)
                    while (true) {
                        if (!live(token)) throw IOException("已取消")
                        val n = input.read(buffer); if (n < 0) break
                        require(output.size() + n <= UpdatePolicy.MAX_MANIFEST) { "更新清单过大" }
                        output.write(buffer, 0, n)
                    }
                    output.toByteArray()
                }
                val envelope = JSONObject(raw.toString(Charsets.UTF_8))
                val payload = UpdatePolicy.verifyPayload(envelope.getString("algorithm"), envelope.getString("payload"), envelope.getString("signature"), activity.assets.open("update-public-key.der").use { it.readBytes() })
                val manifest = JSONObject(payload.toString(Charsets.UTF_8))
                require(manifest.getInt("schema") == 1 && manifest.getString("application") == activity.packageName && manifest.getString("channel") == "stable") { "更新不属于此应用" }
                val p = manifest.getJSONObject("platforms").getJSONObject("android")
                val next = Release(p.getLong("build"), p.getString("version"), p.getString("path"), p.getLong("size"), p.getString("sha256"), p.getInt("minSdk"), manifest.optString("notes"))
                UpdatePolicy.validate(next.build, next.version, next.path, next.size, next.hash, next.minSdk, Build.VERSION.SDK_INT)
                require(next.notes.length <= 4000) { "更新说明过长" }
                require(next.build >= prefs.getLong("highestBuild", 0)) { "更新源版本已回退，请稍后重试" }
                ui(token) {
                    busy = false; dismiss()
                    prefs.edit().putLong("highestBuild", next.build).apply()
                    if (next.build > current().longVersionCode) {
                        if (manual) offer(next) else android.widget.Toast.makeText(activity, tr("Nextend 有新版本，可在“应用更新”下载", "A Nextend update is available in App updates"), android.widget.Toast.LENGTH_LONG).show()
                    } else if (manual) error(tr("已是最新版本 ${current().versionName}", "You're up to date: ${current().versionName}"))
                }
            } catch (e: Exception) { ui(token) { busy = false; dismiss(); if (manual) error(tr("检查失败：${e.message ?: "请检查网络后重试"}", "Update check failed. Please check your network and retry.")) } }
        }
    }
    private fun offer(next: Release) {
        present(AlertDialog.Builder(activity).setTitle(tr("发现 ${next.version}", "Version ${next.version} available"))
            .setMessage("${"%.1f".format(next.size / 1_000_000.0)} MB\n\n${next.notes}")
            .setPositiveButton(tr("下载更新", "Download update")) { _, _ -> download(next) }.setNegativeButton(tr("稍后", "Later"), null))
    }
    private fun download(next: Release) {
        if (busy || streaming()) return
        busy = true; val token = generation.incrementAndGet()
        val bar = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100 }
        showProgress(token, tr("下载并验证 ${next.version}", "Downloading and verifying ${next.version}"), bar)
        executor.execute {
            val dir = File(activity.cacheDir, "updates").apply { mkdirs() }
            val part = File(dir, "${UUID.randomUUID()}.part")
            val apk = File(dir, "Nextend-${next.build}-${next.hash}.apk")
            try {
                require(next.build > current().longVersionCode) { "当前版本已更新" }
                var cached = false
                if (apk.exists()) try { verify(apk, next); cached = true } catch (_: Exception) { apk.delete() }
                if (!cached) {
                    require(dir.usableSpace > next.size * 2 + 16 * 1024 * 1024) { "剩余空间不足" }
                    fetch(next.path, token) { input, length ->
                        require(length == -1L || length == next.size) { "安装包大小与清单不符" }
                        var lastPercent = -1
                        part.outputStream().use { out -> UpdatePolicy.copyVerified(input, out, next.size, next.hash) { count ->
                            if (!live(token)) throw IOException("已取消")
                            val percent = (count * 100 / next.size).toInt()
                            if (percent != lastPercent) { lastPercent = percent; ui(token) { bar.progress = percent } }
                        } }
                    }
                    verify(part, next)
                    if (!live(token)) throw IOException("已取消")
                    Files.move(part.toPath(), apk.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                }
                ui(token) { busy = false; dismiss(); if (!streaming()) ready(apk, next) }
            } catch (e: Exception) { ui(token) { busy = false; dismiss(); error(tr("更新未完成：${e.message ?: "请重试"}。当前版本仍可使用。", "Update failed. The current version is still available; please retry.")) } }
            finally { part.delete() }
        }
    }
    private fun verify(file: File, release: Release) {
        require(file.length() == release.size) { "安装包大小不匹配" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val b = ByteArray(65536); while (true) { val n = input.read(b); if (n < 0) break; digest.update(b, 0, n) } }
        require(UpdatePolicy.hex(digest.digest()) == release.hash) { "安装包哈希不匹配" }
        val pm = activity.packageManager
        val archive = pm.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: throw IOException("无法读取安装包")
        val installed = pm.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        fun signers(info: android.content.pm.PackageInfo) = info.signingInfo?.apkContentsSigners?.map { UpdatePolicy.hex(it.toByteArray()) }?.toSet()
        require(archive.packageName == installed.packageName && archive.longVersionCode == release.build && archive.versionName == release.version &&
            archive.applicationInfo?.minSdkVersion == release.minSdk && signers(installed)?.isNotEmpty() == true && signers(archive) == signers(installed)) { "安装包身份、版本或安装签名不匹配" }
    }
    private fun ready(file: File, release: Release) {
        if (streaming()) return
        val allowed = activity.packageManager.canRequestPackageInstalls()
        present(AlertDialog.Builder(activity).setTitle(tr("更新已准备好", "Update ready"))
            .setMessage(tr(if (allowed) "已验证安装包。下一步请在系统窗口确认更新。" else "首次更新需要允许 Nextend 安装应用。授权后返回，点击安装。", if (allowed) "Package verified. Confirm the update in the system installer." else "Allow Nextend to install apps, then return and tap Install."))
            .setPositiveButton(tr(if (allowed) "安装更新" else "允许安装", if (allowed) "Install update" else "Allow installation")) { _, _ ->
                if (streaming()) return@setPositiveButton
                if (!activity.packageManager.canRequestPackageInstalls()) {
                    pending = file to release
                    try { activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))) }
                    catch (_: Exception) { pending = null; error(tr("无法打开安装权限设置", "Could not open installation settings")) }
                } else install(file, release)
            }.setNegativeButton(tr("稍后", "Later"), null))
    }
    private fun install(file: File, release: Release) {
        if (busy || streaming()) return
        busy = true; val token = generation.incrementAndGet(); showProgress(token, tr("准备安装…", "Preparing installation…"))
        executor.execute {
            try {
                verify(file, release); require(release.build > current().longVersionCode) { "当前版本已更新" }
                ui(token) {
                    busy = false; dismiss(); if (streaming()) return@ui
                    val uri = Uri.parse("content://${activity.packageName}.updates/${file.name}")
                    try { activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri("Nextend update", uri) }) }
                    catch (_: Exception) { error(tr("无法打开系统安装器，请检查安装权限", "Could not open the system installer. Check installation permission.")) }
                }
            } catch (_: Exception) { ui(token) { busy = false; dismiss(); error(tr("安装校验失败，请重新检查更新", "Verification failed. Check for updates again.")) } }
        }
    }
    private fun <T> fetch(path: String, token: Int, read: (java.io.InputStream, Long) -> T): T {
        if (!live(token)) throw IOException("已取消")
        val c = URL(BASE + path).openConnection() as HttpsURLConnection
        connection = c
        val seconds = if (path.endsWith("manifest.json")) 30L else 300L
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        val timeout = timeouts.schedule({ c.disconnect() }, seconds, TimeUnit.SECONDS)
        try {
            if (!live(token)) throw IOException("已取消")
            c.connectTimeout = 10000; c.readTimeout = 20000; c.instanceFollowRedirects = false; c.useCaches = false
            c.setRequestProperty("Accept-Encoding", "identity"); c.setRequestProperty("Cache-Control", "no-cache")
            c.setRequestProperty("User-Agent", "Nextend/${current().versionName}")
            if (c.responseCode != 200) throw IOException("NAS 服务暂不可用（${c.responseCode}）")
            return c.inputStream.use { stream ->
                val bounded = object : java.io.FilterInputStream(stream) {
                    private fun guard() { if (!live(token) || System.nanoTime() > deadline) throw IOException("更新已取消或超时") }
                    override fun read(): Int { guard(); return super.read().also { guard() } }
                    override fun read(b: ByteArray, off: Int, len: Int): Int { guard(); return super.read(b, off, len).also { guard() } }
                }
                read(bounded, c.contentLengthLong)
            }
        } finally { timeout.cancel(false); c.disconnect(); if (connection === c) connection = null }
    }
    private fun showProgress(token: Int, title: String, view: android.view.View? = null) {
        dismiss()
        dialog = AlertDialog.Builder(activity).setTitle(title).setView(view).setNegativeButton(tr("取消", "Cancel")) { _, _ -> cancel() }.create().also {
            it.setOnCancelListener { if (live(token)) cancel() }; it.show()
        }
    }
    private fun dismiss() { dialog?.dismiss(); dialog = null }
    fun resumed() { pending?.let { pending = null; if (!streaming()) ready(it.first, it.second) } }
    fun pause() { if (busy || dialog != null) cancel() }
    private fun cancel() { generation.incrementAndGet(); connection?.disconnect(); busy = false; dismiss() }
    fun close() { closed = true; cancel(); pending = null; executor.shutdownNow(); timeouts.shutdownNow() }
}
