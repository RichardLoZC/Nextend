package dev.padbridge

import java.io.InputStream
import java.io.OutputStream
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** Platform-independent trust and resource bounds used before an APK reaches the installer. */
internal object UpdatePolicy {
    const val MAX_MANIFEST = 64 * 1024
    const val MAX_APK = 64L * 1024 * 1024
    fun verifyPayload(algorithm: String, encoded: String, signature: String, key: ByteArray): ByteArray {
        require(algorithm == "RS256" && encoded.length <= MAX_MANIFEST && signature.length <= 2048) { "更新签名格式无效" }
        val payload = Base64.getDecoder().decode(encoded)
        val verifier = Signature.getInstance("SHA256withRSA")
        verifier.initVerify(KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(key)))
        verifier.update(payload)
        require(verifier.verify(Base64.getDecoder().decode(signature))) { "更新签名校验失败" }
        return payload
    }
    fun validate(build: Long, version: String, path: String, size: Long, sha256: String, minSdk: Int, deviceSdk: Int) {
        require(build in 1..2_100_000_000 && version.matches(Regex("[0-9]+\\.[0-9]+\\.[0-9]+"))) { "更新版本无效" }
        require(path == "updates/Nextend-Android-$build.apk") { "更新文件路径无效" }
        require(size in 1..MAX_APK && sha256.matches(Regex("[a-f0-9]{64}"))) { "更新文件信息无效" }
        require(minSdk in 1..deviceSdk) { "此更新不适用于当前 Android 版本" }
    }
    fun copyVerified(input: InputStream, output: OutputStream, size: Long, expected: String, progress: (Long) -> Unit) {
        require(size in 1..MAX_APK)
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024); var count = 0L
        while (true) {
            val n = input.read(buffer); if (n < 0) break
            count += n; require(count <= size) { "安装包超出预期大小" }
            digest.update(buffer, 0, n); output.write(buffer, 0, n); progress(count)
        }
        require(count == size && hex(digest.digest()) == expected) { "安装包下载不完整或校验失败" }
    }
    fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
