package dev.padbridge

import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object PairCrypto {
    private const val CONTEXT = "PadBridge/v1/"
    fun random(count: Int) = ByteArray(count).also { SecureRandom().nextBytes(it) }
    fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(data)
    }
    fun proof(key: ByteArray, role: String, salt: ByteArray) = hmac(key, (CONTEXT + role).toByteArray() + salt)
    fun derive(key: ByteArray, salt: ByteArray, direction: String): ByteArray =
        hmac(hmac(salt, key), (CONTEXT + direction).toByteArray() + byteArrayOf(1))
    fun seal(body: ByteArray, key: ByteArray, sequence: Long): ByteArray {
        val aad = ByteBuffer.allocate(8).putLong(sequence).array()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ByteArray(4) + aad))
        cipher.updateAAD(aad)
        return aad + cipher.doFinal(body)
    }
    fun open(packet: ByteArray, key: ByteArray, sequence: Long): ByteArray {
        require(packet.size >= 25 && ByteBuffer.wrap(packet).long == sequence) { "Invalid encrypted frame sequence" }
        val aad = packet.copyOfRange(0, 8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ByteArray(4) + aad))
        cipher.updateAAD(aad)
        return cipher.doFinal(packet, 8, packet.size - 8)
    }
}

class SecureChannel(private val socket: Socket, key: ByteArray, private val requestClient: Boolean = false,
                    private val writeTimeoutMillis: Long = 5000) : AutoCloseable {
    private val input = DataInputStream(socket.getInputStream())
    private val output = DataOutputStream(socket.getOutputStream())
    private val sendKey: ByteArray
    private val receiveKey: ByteArray
    private var sendSequence = 0L
    private var receiveSequence = 0L
    private var handshakeDeadlineNS: Long? = System.nanoTime() + 5_000_000_000L
    private val closed = AtomicBoolean(false)
    private val ending = AtomicBoolean(false)
    private val closedSignal = CountDownLatch(1)
    init {
        require(key.size == 32)
        socket.tcpNoDelay = true
        socket.soTimeout = 5000
        if (requestClient) {
            val nonce = PairCrypto.random(32)
            writeRaw("PDR1".toByteArray() + nonce)
            val reply = readRaw(64); require(reply.size == 64)
            val salt = nonce + reply.copyOfRange(0, 32)
            require(MessageDigest.isEqual(reply.copyOfRange(32, 64), PairCrypto.proof(key, "request-mac", salt)))
            writeRaw(PairCrypto.proof(key, "request-pad", salt))
            sendKey = PairCrypto.derive(key, salt, "request-pad-to-mac")
            receiveKey = PairCrypto.derive(key, salt, "request-mac-to-pad")
        } else {
            val hello = readRaw(36)
            require(hello.size == 36 && hello.copyOfRange(0, 4).contentEquals("PDB1".toByteArray())) { "Protocol version mismatch" }
            val nonce = PairCrypto.random(32)
            val salt = hello.copyOfRange(4, 36) + nonce
            writeRaw(nonce + PairCrypto.proof(key, "pad", salt))
            require(MessageDigest.isEqual(readRaw(32), PairCrypto.proof(key, "mac", salt))) { "Pairing authentication failed" }
            sendKey = PairCrypto.derive(key, salt, "pad-to-mac")
            receiveKey = PairCrypto.derive(key, salt, "mac-to-pad")
        }
        handshakeDeadlineNS = null
        socket.soTimeout = 8000
    }
    private fun readRaw(maximum: Int = MAX_PACKET): ByteArray {
        val deadline = handshakeDeadlineNS ?: (System.nanoTime() + 8_000_000_000L)
        val length = ByteBuffer.wrap(readExactly(4, deadline)).int
        require(length in 1..maximum) { "Packet length exceeds limit" }
        return readExactly(length, deadline)
    }
    private fun readExactly(length: Int, deadline: Long): ByteArray {
        val data = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) throw java.net.SocketTimeoutException("Packet deadline expired")
            socket.soTimeout = (remaining / 1_000_000L).coerceIn(1, 8000).toInt()
            val count = input.read(data, offset, length - offset)
            if (count < 0) throw java.io.EOFException("Mac disconnected")
            offset += count
        }
        return data
    }
    private fun writeRaw(body: ByteArray) {
        require(body.size in 1..MAX_PACKET)
        check(!closed.get()) { "Connection closed" }
        val pending = AtomicBoolean(true)
        // SO_TIMEOUT only bounds reads. Closing from another thread also wakes
        // a blocked writer and every sender waiting on the send monitor.
        val deadline = watchdog.schedule({ if (pending.compareAndSet(true, false)) close() }, writeTimeoutMillis, TimeUnit.MILLISECONDS)
        try { output.writeInt(body.size); output.write(body); output.flush() }
        finally { pending.set(false); deadline.cancel(false) }
    }
    @Synchronized fun send(body: ByteArray) {
        check(sendSequence < Long.MAX_VALUE)
        writeRaw(PairCrypto.seal(body, sendKey, sendSequence)); sendSequence++
    }
    fun receive(): ByteArray {
        check(receiveSequence < Long.MAX_VALUE)
        val body = PairCrypto.open(readRaw(if (requestClient) 4096 else MAX_PACKET), receiveKey, receiveSequence); receiveSequence++
        return body
    }
    /** Decoder errors may preserve HDR fallback, but never block the UI/codec
     * thread or delay socket closure indefinitely while reporting the error. */
    fun closeWithError(body: ByteArray): CountDownLatch {
        if (closed.get() || !ending.compareAndSet(false, true)) return closedSignal
        val deadline = watchdog.schedule({ close() }, 250, TimeUnit.MILLISECONDS)
        Thread({
            try { send(body) } catch (_: Exception) { /* Best effort before closing. */ }
            finally { close(); deadline.cancel(false) }
        }, "Nextend-error-close").apply { isDaemon = true; start() }
        return closedSignal
    }
    override fun close() {
        if (closed.compareAndSet(false, true)) {
            try { runCatching { socket.close() } } finally { closedSignal.countDown() }
        }
    }
    companion object {
        const val MAX_PACKET = 16 * 1024 * 1024
        private val watchdog = ScheduledThreadPoolExecutor(1) { action ->
            Thread(action, "Nextend-write-deadline").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}
