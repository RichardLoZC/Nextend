package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class WireRecoveryTest {
    private fun raw(out: DataOutputStream, value: ByteArray) { out.writeInt(value.size); out.write(value); out.flush() }
    private fun raw(input: DataInputStream) = ByteArray(input.readInt()).also { input.readFully(it) }
    private fun paired(writeTimeout: Long, readFinal: Boolean = false, test: (SecureChannel, ArrayBlockingQueue<ByteArray>) -> Unit) {
        val key = ByteArray(32) { 7 }; val stop = CountDownLatch(1)
        val received = ArrayBlockingQueue<ByteArray>(1)
        val executor = Executors.newSingleThreadExecutor { Thread(it, "test-peer").apply { isDaemon = true } }
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { listener ->
            val peer = executor.submit {
                Socket().use { socket ->
                    socket.receiveBufferSize = 1024; socket.soTimeout = 4000
                    socket.connect(java.net.InetSocketAddress(InetAddress.getLoopbackAddress(), listener.localPort), 2000)
                    val input = DataInputStream(socket.getInputStream()); val output = DataOutputStream(socket.getOutputStream())
                    val nonce = ByteArray(32) { 3 }; raw(output, "PDB1".toByteArray() + nonce)
                    val hello = raw(input); val salt = nonce + hello.copyOfRange(0, 32)
                    assertTrue(java.security.MessageDigest.isEqual(hello.copyOfRange(32, 64), PairCrypto.proof(key, "pad", salt)))
                    raw(output, PairCrypto.proof(key, "mac", salt))
                    if (readFinal) received.put(PairCrypto.open(raw(input), PairCrypto.derive(key, salt, "pad-to-mac"), 0))
                    stop.await(5, TimeUnit.SECONDS)
                }
            }
            listener.soTimeout = 2000
            listener.accept().use { socket ->
                socket.sendBufferSize = 1024
                val channel = SecureChannel(socket, key, writeTimeoutMillis = writeTimeout)
                try { test(channel, received) }
                finally { channel.close(); stop.countDown(); peer.get(5, TimeUnit.SECONDS); executor.shutdownNow() }
            }
        }
    }
    @Test fun stalledWriterIsClosedWithoutAnExternalReset() = paired(250) { channel, _ ->
        val workers = Executors.newFixedThreadPool(2) { Thread(it, "test-stalled-channel").apply { isDaemon = true } }
        try {
            val writer = workers.submit<Boolean> {
                // One packet exceeds the kernel's buffers; small packets can
                // trickle through window updates without hitting a write deadline.
                try { channel.send(ByteArray(8 * 1024 * 1024)); false } catch (_: Exception) { true }
            }
            val reader = workers.submit<Boolean> { try { channel.receive(); false } catch (_: Exception) { true } }
            assertTrue(writer.get(4, TimeUnit.SECONDS))
            assertTrue(reader.get(1, TimeUnit.SECONDS))
        } finally { channel.close(); workers.shutdownNow() }
    }
    @Test fun errorReportingDoesNotBlockUiOrCleanup() = paired(5000) { channel, _ ->
        val workers = Executors.newSingleThreadExecutor { Thread(it, "test-error-writer").apply { isDaemon = true } }
        try {
            val writer = workers.submit<Boolean> {
                try { repeat(100_000) { channel.send(ByteArray(1024)) }; false } catch (_: Exception) { true }
            }
            Thread.sleep(150)
            val start = System.nanoTime()
            val closed = channel.closeWithError(byteArrayOf(1) + "hdr-error".toByteArray())
            assertTrue("error callback blocked its caller", System.nanoTime() - start < 200_000_000)
            assertTrue(closed.await(1500, TimeUnit.MILLISECONDS))
            assertTrue(writer.get(1, TimeUnit.SECONDS))
        } finally { channel.close(); workers.shutdownNow() }
    }
    @Test fun healthyPeerReceivesHdrErrorBeforeClosure() = paired(5000, readFinal = true) { channel, received ->
        val error = byteArrayOf(1) + "{\"type\":\"hdr-error\",\"message\":\"unsupported\"}".toByteArray()
        val closed = channel.closeWithError(error)
        assertArrayEquals(error, received.poll(2, TimeUnit.SECONDS))
        assertTrue(closed.await(1, TimeUnit.SECONDS))
    }
    @Test fun completedWritesCancelTheirWatchdog() = paired(100) { channel, _ ->
        channel.send(byteArrayOf(1, 2, 3))
        Thread.sleep(250)
        channel.send(byteArrayOf(4, 5, 6))
    }
}
