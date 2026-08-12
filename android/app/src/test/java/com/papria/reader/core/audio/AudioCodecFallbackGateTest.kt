package com.papria.reader.core.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCodecFallbackGateTest {
    @Test
    fun allowsLocalAndHeaderlessRemoteInputsForThePackagedDecoder() {
        assertEquals(
            LibVlcRoute.Allowed,
            AudioCodecFallbackGate.libVlcRoute("/files/book.opus", emptyMap()),
        )
        assertEquals(
            LibVlcRoute.Allowed,
            AudioCodecFallbackGate.libVlcRoute("https://media.example.test/book.flac", emptyMap()),
        )
    }

    @Test
    fun rejectsBookOrbitBearerBeforeLibVlcCanConstructAMediaUrl() {
        val route = AudioCodecFallbackGate.libVlcRoute(
            "https://books.example.test/api/v1/books/files/9/serve",
            mapOf("Authorization" to "Bearer secret-is-never-forwarded"),
        )

        assertTrue(route is LibVlcRoute.Rejected)
        assertEquals("带认证头的 BookOrbit Range 流不会交给 LibVLC", (route as LibVlcRoute.Rejected).reason)
    }

    @Test
    fun rejectsCredentialLikeQueryBeforeRedirectsCanReachLibVlc() {
        val route = AudioCodecFallbackGate.libVlcRoute(
            "https://media.example.test/book.ogg?access_token=opaque",
            emptyMap(),
        )

        assertTrue(route is LibVlcRoute.Rejected)
        assertEquals("含凭据查询参数的远端地址不会交给 LibVLC", (route as LibVlcRoute.Rejected).reason)
    }
}
