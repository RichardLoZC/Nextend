import android.content.Context
import android.net.nsd.*
import android.os.Looper
import dev.padbridge.PadConnectRequest

fun client(manager: NsdManager) = PadConnectRequest(Context(manager), { ByteArray(32) }, { false }) { _, _, _ -> false }
fun hosts(c: PadConnectRequest) = c.javaClass.getDeclaredField("hosts").apply { isAccessible = true }.get(c) as Map<*, *>
fun main() {
    val discovery = NsdManager().apply { failDiscover = true }
    val a = client(discovery); a.start(); Looper.advance()
    check(discovery.starts == 1)
    discovery.failDiscover = false; Looper.advance(1000)
    check(discovery.starts == 2)
    a.close(); Looper.advance(); Looper.advance(60_000); check(discovery.starts == 2)
    println("PASS discovery failure retries and close cancels retries")

    val resolve = NsdManager()
    val b = client(resolve); b.start(); Looper.advance()
    resolve.listener.onServiceFound(NsdServiceInfo()); Looper.advance(); check(resolve.resolves == 1)
    resolve.failResolve = false; Looper.advance(500)
    check(resolve.resolves == 2 && hosts(b).size == 1)
    b.refreshDiscovery(); Looper.advance(); check(hosts(b).size == 1) // Slow discovery must not erase a usable cached Mac.
    b.refreshDiscovery(clearHosts = true); Looper.advance(); check(hosts(b).isEmpty())
    b.close(); Looper.advance()
    println("PASS resolve retry, manual cache retention, network-change invalidation")

    val serial = NsdManager().apply { deferResolve = true }
    val c = client(serial); c.start(); Looper.advance()
    serial.listener.onServiceFound(NsdServiceInfo("one")); serial.listener.onServiceFound(NsdServiceInfo("two")); Looper.advance()
    check(serial.resolves == 1)
    val first = serial.waiting.removeAt(0); first.second.onServiceResolved(first.first); Looper.advance()
    check(serial.resolves == 2 && hosts(c).size == 1)
    val second = serial.waiting.removeAt(0)
    serial.listener.onServiceLost(second.first); second.second.onServiceResolved(second.first); Looper.advance()
    check(hosts(c).size == 1)
    val oldListener = serial.listener
    c.refreshDiscovery(clearHosts = true); Looper.advance()
    oldListener.onServiceFound(NsdServiceInfo("stale")); first.second.onServiceResolved(first.first); Looper.advance()
    check(hosts(c).isEmpty() && serial.resolves == 2)
    c.close(); Looper.advance()
    println("PASS serial resolution, service lost during resolution, stale callbacks ignored")

    val missingCallback = NsdManager().apply { deferResolve = true }
    val d = client(missingCallback); d.start(); Looper.advance()
    missingCallback.listener.onServiceFound(NsdServiceInfo()); Looper.advance()
    check(missingCallback.resolves == 1)
    missingCallback.deferResolve = false; missingCallback.failResolve = false
    Looper.advance(6500)
    check(missingCallback.resolves == 2 && hosts(d).size == 1)
    d.close(); Looper.advance()
    println("PASS missing resolve callback has a bounded retry")
}
