package com.papria.reader.core.bookorbit

import android.security.NetworkSecurityPolicy
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Verifies the installed package exposes the LAN HTTP capability guarded by BookOrbitClient. */
@RunWith(AndroidJUnit4::class)
class BookOrbitTransportDeviceTest {
    @Test
    fun packagedNetworkPolicyAllowsTheClientGuardedLocalhostCapability() {
        assertTrue(NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted("localhost"))
        assertTrue(AndroidCleartextTransportPolicy.isPermitted("localhost"))
    }
}
