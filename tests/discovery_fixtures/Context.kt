package android.content
import android.net.nsd.NsdManager
class Context(private val manager: NsdManager) {
 fun <T> getSystemService(cls: Class<T>): T = cls.cast(manager)
}
