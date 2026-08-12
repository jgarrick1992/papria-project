package com.papria.reader.core.bookorbit

import android.os.Build
import android.security.NetworkSecurityPolicy

/**
 * The Android platform's cleartext capability check.
 *
 * This is intentionally separate from [CleartextHttpConfirmation]. The latter
 * records the user's exact host-and-port acknowledgement, whereas Android's
 * network security configuration is static and cannot be mutated from that
 * acknowledgement at runtime. BookOrbitClient remains the per-request
 * authorization boundary and must pass both checks before opening LAN HTTP.
 */
fun interface CleartextTransportPolicy {
    fun isPermitted(host: String): Boolean
}

/** Reads the platform capability packaged with the installed application. */
object AndroidCleartextTransportPolicy : CleartextTransportPolicy {
    override fun isPermitted(host: String): Boolean {
        if (host.isBlank()) return false
        val policy = NetworkSecurityPolicy.getInstance()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            policy.isCleartextTrafficPermitted(host)
        } else {
            policy.isCleartextTrafficPermitted
        }
    }
}
