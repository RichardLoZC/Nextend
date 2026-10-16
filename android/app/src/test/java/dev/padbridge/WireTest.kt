package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class WireTest {
    private val key = ByteArray(32) { it.toByte() }
    private val salt = ByteArray(64) { (it + 32).toByte() }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    @Test fun crossPlatformGoldenVector() {
        val derived = PairCrypto.derive(key, salt, "mac-to-pad")
        assertEquals("c3d3fda910fc54539d4778b98e44fe396470b6e80c14392726f25ff008488494", derived.hex())
        val packet = PairCrypto.seal("PadBridge cross-platform test".toByteArray(), derived, 7)
        assertEquals("0000000000000007fd0af527e7afb36d57816eeb4ef21d708a7a1312fbb0170876732ec9e20925d5171cf0030cf6af4b1ce6989325", packet.hex())
        assertEquals("PadBridge cross-platform test", String(PairCrypto.open(packet, derived, 7)))
        assertEquals("4c18c74e21dea879d665b164463af0a33bb7cb659fd7bea50cc3481c8cbd260d", PairCrypto.proof(key, "pad", salt).hex())
    }
    @Test fun tamperingAndReplayRejected() {
        val derived = PairCrypto.derive(key, salt, "mac-to-pad")
        val packet = PairCrypto.seal(byteArrayOf(1, 2, 3), derived, 2)
        assertThrows(IllegalArgumentException::class.java) { PairCrypto.open(packet, derived, 3) }
        packet[packet.lastIndex] = (packet.last().toInt() xor 1).toByte()
        assertThrows(javax.crypto.AEADBadTagException::class.java) { PairCrypto.open(packet, derived, 2) }
    }
    @Test fun directionsAndSessionsHaveDifferentKeys() {
        assertFalse(PairCrypto.derive(key, salt, "mac-to-pad").contentEquals(PairCrypto.derive(key, salt, "pad-to-mac")))
        val changed = salt.clone(); changed[0] = (changed[0].toInt() xor 1).toByte()
        assertFalse(PairCrypto.derive(key, salt, "mac-to-pad").contentEquals(PairCrypto.derive(key, changed, "mac-to-pad")))
        assertFalse(PairCrypto.proof(key, "pad", salt).contentEquals(PairCrypto.proof(key, "mac", salt)))
    }
    @Test fun oversizedHandshakeRejectedBeforeAllocation() {
        val executor = Executors.newSingleThreadExecutor()
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { listener ->
            val outcome = executor.submit<Boolean> {
                listener.accept().use { socket ->
                    try { SecureChannel(socket, key); false } catch (_: IllegalArgumentException) { true }
                }
            }
            Socket(InetAddress.getLoopbackAddress(), listener.localPort).use { socket ->
                DataOutputStream(socket.getOutputStream()).apply { writeInt(Int.MAX_VALUE); flush() }
                assertTrue(outcome.get(2, TimeUnit.SECONDS))
            }
        }
        executor.shutdownNow()
    }
}
