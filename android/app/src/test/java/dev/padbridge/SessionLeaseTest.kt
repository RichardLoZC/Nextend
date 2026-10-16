package dev.padbridge

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SessionLeaseTest {
    @Test fun anotherTransportCannotStealOrReleaseTheActiveDecoder() {
        val lease = SessionLease(); val usb = Any(); val wifi = Any()
        assertTrue(lease.acquire(usb))
        assertFalse(lease.acquire(wifi))
        lease.release(wifi)
        assertFalse(lease.acquire(wifi))
        lease.release(usb)
        assertTrue(lease.acquire(wifi))
        lease.release(usb) // Late cleanup from the previous session is harmless.
        assertFalse(lease.acquire(usb))
        lease.release(wifi)
        assertTrue(lease.acquire(usb))
    }
    @Test fun simultaneousAuthenticatedConnectionsHaveOnlyOneWinner() {
        val lease = SessionLease(); val start = CountDownLatch(1); val done = CountDownLatch(2)
        val winners = AtomicInteger()
        val tokens = listOf(Any(), Any())
        tokens.forEach { token -> Thread {
            start.await()
            if (lease.acquire(token)) winners.incrementAndGet()
            done.countDown()
        }.start() }
        start.countDown()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertEquals(1, winners.get())
        tokens.forEach { lease.release(it) }
        assertTrue(lease.acquire(Any()))
    }
}
