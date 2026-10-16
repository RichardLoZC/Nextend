package dev.padbridge

import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
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

class SecureChannel(private val socket: Socket, key: ByteArray) : AutoCloseable {
    private val input = DataInputStream(socket.getInputStream())
    private val output = DataOutputStream(socket.getOutputStream())
    private val sendKey: ByteArray
    private val receiveKey: ByteArray
    private var sendSequence = 0L
    private var receiveSequence = 0L
    private var handshakeDeadlineNS: Long? = System.nanoTime() + 5_000_000_000L
    init {
        require(key.size == 32)
        socket.tcpNoDelay = true
        socket.soTimeout = 5000
        val hello = readRaw(36)
        require(hello.size == 36 && hello.copyOfRange(0, 4).contentEquals("PDB1".toByteArray())) { "Protocol version mismatch" }
        val nonce = PairCrypto.random(32)
        val salt = hello.copyOfRange(4, 36) + nonce
        writeRaw(nonce + PairCrypto.proof(key, "pad", salt))
        require(MessageDigest.isEqual(readRaw(32), PairCrypto.proof(key, "mac", salt))) { "Pairing authentication failed" }
        sendKey = PairCrypto.derive(key, salt, "pad-to-mac")
        receiveKey = PairCrypto.derive(key, salt, "mac-to-pad")
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
        output.writeInt(body.size); output.write(body); output.flush()
    }
    @Synchronized fun send(body: ByteArray) {
        check(sendSequence < Long.MAX_VALUE)
        writeRaw(PairCrypto.seal(body, sendKey, sendSequence)); sendSequence++
    }
    fun receive(): ByteArray {
        check(receiveSequence < Long.MAX_VALUE)
        val body = PairCrypto.open(readRaw(), receiveKey, receiveSequence); receiveSequence++
        return body
    }
    override fun close() { runCatching { socket.close() } }
    companion object { const val MAX_PACKET = 16 * 1024 * 1024 }
}
