package com.papria.reader.core.reader

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.papria.reader.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Proves the installed APK loads the mandatory UniFFI shared library rather
 * than only compiling or packaging its generated binding.
 */
@RunWith(AndroidJUnit4::class)
class FormatCoreDeviceTest {
    @Test
    fun packagedNativeCoreLoadsAndDetectsEpub() {
        assertTrue("format-core must be enabled in every Android variant", BuildConfig.NATIVE_FORMAT_CORE)
        val detected = FormatCoreRuntime.detectFormat(
            filename = "device-fixture.epub",
            header = byteArrayOf(0x50, 0x4B, 0x03, 0x04),
        )
        assertEquals("EPUB", detected)
    }
}
