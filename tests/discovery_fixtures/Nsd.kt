package android.net.nsd
import java.net.InetAddress
class NsdServiceInfo(val serviceName:String="Nextend",val serviceType:String="_nextend._tcp.",val port:Int=49372,val host:InetAddress=InetAddress.getByName("127.0.0.2"))
class NsdManager {
 interface DiscoveryListener { fun onDiscoveryStarted(type:String);fun onDiscoveryStopped(type:String);fun onStartDiscoveryFailed(type:String,code:Int);fun onStopDiscoveryFailed(type:String,code:Int);fun onServiceLost(info:NsdServiceInfo);fun onServiceFound(info:NsdServiceInfo) }
 interface ResolveListener { fun onResolveFailed(info:NsdServiceInfo,code:Int);fun onServiceResolved(info:NsdServiceInfo) }
 var starts=0;var resolves=0;var failDiscover=false;var failResolve=true
 var deferResolve=false
 val waiting=mutableListOf<Pair<NsdServiceInfo,ResolveListener>>()
 lateinit var listener:DiscoveryListener
 fun discoverServices(type:String,protocol:Int,callback:DiscoveryListener) {starts++;listener=callback;if(failDiscover) callback.onStartDiscoveryFailed(type,0) else callback.onDiscoveryStarted(type)}
 fun resolveService(info:NsdServiceInfo,callback:ResolveListener) {resolves++;if(deferResolve) waiting.add(info to callback) else if(failResolve)callback.onResolveFailed(info,0) else callback.onServiceResolved(info)}
 fun stopServiceDiscovery(listener:DiscoveryListener) {}
 companion object { const val PROTOCOL_DNS_SD=1 }
}
