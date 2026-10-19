package dev.padbridge

/** USB and Wi-Fi authenticate independently, but only one can own the decoder. */
class SessionLease {
    private var owner: Any? = null
    @Synchronized fun isAvailable(): Boolean = owner == null
    @Synchronized fun acquire(candidate: Any): Boolean {
        if (owner != null) return false
        owner = candidate
        return true
    }
    @Synchronized fun release(candidate: Any) {
        if (owner === candidate) owner = null
    }
}
