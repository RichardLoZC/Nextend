package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.util.Base64

class UpdatePolicyTest {
    private fun reject(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) {} }
    @Test fun signedPayloadRejectsModificationAndWrongKey() {
        val generator = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
        val key = generator.generateKeyPair(); val payload = "real release".toByteArray()
        val sign = Signature.getInstance("SHA256withRSA").apply { initSign(key.private); update(payload) }.sign()
        fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)
        assertArrayEquals(payload, UpdatePolicy.verifyPayload("RS256", b64(payload), b64(sign), key.public.encoded))
        reject { UpdatePolicy.verifyPayload("none", b64(payload), b64(sign), key.public.encoded) }
        reject { UpdatePolicy.verifyPayload("RS256", b64("other release".toByteArray()), b64(sign), key.public.encoded) }
        reject { UpdatePolicy.verifyPayload("RS256", b64(payload), b64(sign), generator.generateKeyPair().public.encoded) }
    }
    @Test fun rejectsExternalOrAmbiguousPathsAndUnsupportedVersions() {
        val hash = "a".repeat(64)
        UpdatePolicy.validate(12, "0.8.0", "updates/Nextend-Android-12.apk", 100, hash, 30, 36)
        for (path in listOf("https://evil.test/a.apk", "../other.apk", "updates/Nextend-Android-11.apk", "updates/Nextend-Android-12.apk?x=1")) reject { UpdatePolicy.validate(12, "0.8.0", path, 100, hash, 30, 36) }
        reject { UpdatePolicy.validate(12, "0.8.0", "updates/Nextend-Android-12.apk", UpdatePolicy.MAX_APK + 1, hash, 30, 36) }
        reject { UpdatePolicy.validate(12, "0.8.0", "updates/Nextend-Android-12.apk", 100, hash, 37, 36) }
    }
    @Test fun streamRejectsTruncationExcessAndHashMismatch() {
        val bytes = ByteArray(1024) { it.toByte() }
        val hash = UpdatePolicy.hex(MessageDigest.getInstance("SHA-256").digest(bytes))
        val out = ByteArrayOutputStream()
        UpdatePolicy.copyVerified(ByteArrayInputStream(bytes), out, bytes.size.toLong(), hash) {}
        assertArrayEquals(bytes, out.toByteArray())
        reject { UpdatePolicy.copyVerified(ByteArrayInputStream(bytes.copyOf(1000)), ByteArrayOutputStream(), 1024, hash) {} }
        reject { UpdatePolicy.copyVerified(ByteArrayInputStream(bytes), ByteArrayOutputStream(), 1000, hash) {} }
        reject { UpdatePolicy.copyVerified(ByteArrayInputStream(bytes), ByteArrayOutputStream(), 1024, "0".repeat(64)) {} }
    }
    @Test fun cancellationStopsCopy() {
        try { UpdatePolicy.copyVerified(ByteArrayInputStream(ByteArray(100000)), ByteArrayOutputStream(), 100000, "0".repeat(64)) { throw java.io.IOException("cancelled") }; fail() }
        catch (e: java.io.IOException) { assertEquals("cancelled", e.message) }
    }
}
