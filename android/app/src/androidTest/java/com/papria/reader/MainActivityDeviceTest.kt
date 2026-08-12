package com.papria.reader

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

/** Smoke-tests the installed launcher activity and Compose application shell. */
@RunWith(AndroidJUnit4::class)
class MainActivityDeviceTest {
    @Test
    fun launcherActivityStartsFromThePackagedApk() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.adoptShellPermissionIdentity()
            try {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            } finally {
                instrumentation.uiAutomation.dropShellPermissionIdentity()
            }
        }
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        assertNotNull("the packaged app must expose a launcher activity", intent)

        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        context.startActivity(requireNotNull(intent))
        val activity = monitor.waitForActivityWithTimeout(15_000)
        instrumentation.removeMonitor(monitor)
        assertNotNull("the launcher intent must create MainActivity", activity)
        try {
            assertEquals(MainActivity::class.java.name, requireNotNull(activity).javaClass.name)
        } finally {
            instrumentation.runOnMainSync { requireNotNull(activity).finishAndRemoveTask() }
        }
    }
}
