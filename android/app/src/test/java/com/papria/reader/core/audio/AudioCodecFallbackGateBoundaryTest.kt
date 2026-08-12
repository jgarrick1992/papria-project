package com.papria.reader.core.audio

import android.os.Bundle
import androidx.media3.common.PlaybackException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCodecFallbackGateBoundaryTest {
    @Test
    fun rejectsEveryCredentialShapedRemoteQueryKeyCaseInsensitively() {
        listOf(
            "token",
            "accessToken",
            "access_token",
            "refresh-token",
            "authorization",
            "x-auth-proof",
            "signature",
            "cloudSignature",
            "key",
            "AUTHORIZATION",
            "Signature",
            "KEY",
        ).forEach { key ->
            val route = AudioCodecFallbackGate.libVlcRoute(
                "https://media.example.test/book.opus?$key=secret",
                emptyMap(),
            )

            assertTrue("$key must not reach LibVLC", route is LibVlcRoute.Rejected)
            assertEquals(
                "含凭据查询参数的远端地址不会交给 LibVLC",
                (route as LibVlcRoute.Rejected).reason,
            )
        }
    }

    @Test
    fun allowsOnlyBenignRemoteQueriesAndIgnoresCredentialWordsOutsideKeyNames() {
        val allowedPaths = listOf(
            "https://media.example.test/book.opus",
            "https://media.example.test/book.opus?",
            "https://media.example.test/book.opus?chapter=token&quality=high",
            "https://media.example.test/book.opus?monkey=value&keyboard=value",
            "https://media.example.test/book.opus#access_token=fragment-only",
            "custom+audio://host/stream?chapter=1",
        )

        allowedPaths.forEach { path ->
            assertEquals("benign route rejected: $path", LibVlcRoute.Allowed, AudioCodecFallbackGate.libVlcRoute(path, emptyMap()))
        }
    }

    @Test
    fun anyHeaderDisablesFallbackEvenWhenItsNameOrValueIsBlank() {
        val headerCases = listOf(
            mapOf("Authorization" to "Bearer secret"),
            mapOf("Cookie" to "refresh=secret"),
            mapOf("Range" to "bytes=0-"),
            mapOf("X-Trace" to "public"),
            mapOf("" to ""),
        )

        headerCases.forEach { headers ->
            val route = AudioCodecFallbackGate.libVlcRoute("https://media.example.test/book.flac", headers)
            assertTrue("headers must reject fallback: $headers", route is LibVlcRoute.Rejected)
            assertEquals("带认证头的 BookOrbit Range 流不会交给 LibVLC", (route as LibVlcRoute.Rejected).reason)
        }
    }

    @Test
    fun localExtensionValidationIgnoresCaseAndUrlSuffixes() {
        assertEquals(null, AudioCodecFallbackGate.localInputFailure("/private/books/CHAPTER.FLAC?part=1#top"))
        assertEquals(
            "不支持的本地音频格式：.wav",
            AudioCodecFallbackGate.localInputFailure("/private/books/chapter.wav"),
        )
        assertEquals(
            "本地音频缺少可识别的格式扩展名",
            AudioCodecFallbackGate.localInputFailure("/private/books/chapter"),
        )
    }

    @Test
    fun localInputUsesTheExactSupportedExtensionSet() {
        val supported = listOf("m4b", "m4a", "mp3", "opus", "ogg", "flac")
        supported.forEach { extension ->
            assertEquals(null, AudioCodecFallbackGate.localInputFailure("/private/books/chapter.${extension.uppercase()}"))
        }

        val invalid = mapOf(
            "" to "本地音频缺少可识别的格式扩展名",
            "/" to "本地音频缺少可识别的格式扩展名",
            "/private/books/." to "本地音频缺少可识别的格式扩展名",
            "/private/books/chapter" to "本地音频缺少可识别的格式扩展名",
            "/private/books/chapter.wav" to "不支持的本地音频格式：.wav",
            "/private/books/chapter.mp3.exe" to "不支持的本地音频格式：.exe",
            "/private/books/chapter.mp3." to "本地音频缺少可识别的格式扩展名",
        )
        invalid.forEach { (path, reason) ->
            assertEquals("local path mismatch: $path", reason, AudioCodecFallbackGate.localInputFailure(path))
        }
    }

    @Test
    fun decoderFailureClassificationUsesTheExactMedia3CodeSet() {
        val decoderCodes = listOf(
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
            PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        )
        decoderCodes.forEach { code ->
            assertTrue("decoder code must trigger fallback: $code", AudioCodecFallbackGate.isDecoderFailure(error(code)))
        }

        listOf(
            Int.MIN_VALUE,
            PlaybackException.ERROR_CODE_UNSPECIFIED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED,
            PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
            Int.MAX_VALUE,
        ).forEach { code ->
            assertFalse("non-decoder code must not trigger fallback: $code", AudioCodecFallbackGate.isDecoderFailure(error(code)))
        }
    }

    @Test
    fun terminalFailureMessagesClassifyDecoderContainerNetworkAndUnknownErrors() {
        assertEquals(
            "OPUS 的编码不受当前设备解码器支持，已停止播放",
            AudioCodecFallbackGate.failureMessage("/books/CHAPTER.OpUs?part=1", error(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED)),
        )
        assertEquals(
            "FLAC 音频容器损坏，已停止播放",
            AudioCodecFallbackGate.failureMessage("/books/chapter.flac", error(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED)),
        )
        listOf(
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
            PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
            PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
        ).forEach { code ->
            assertEquals(
                "音频 Range 流请求失败，已停止播放；请检查网络和登录状态后重试",
                AudioCodecFallbackGate.failureMessage("https://secret.example/serve?chapter=1", error(code)),
            )
        }

        val unknown = error(Int.MAX_VALUE)
        val message = AudioCodecFallbackGate.failureMessage("https://secret.example/serve?token=must-not-leak", unknown)
        assertEquals("音频播放失败（${unknown.errorCodeName}），已停止播放", message)
        assertFalse(message.contains("secret.example"))
        assertFalse(message.contains("must-not-leak"))
    }

    @Test
    fun selfCheckIsStableAndContainsNoRuntimeMediaData() {
        assertEquals(
            "primary=Media3; libvlcFallback=packaged-local-or-headerless; authenticatedRange=Media3-only",
            AudioCodecFallbackGate.selfCheck(),
        )
    }

    private fun error(code: Int): PlaybackException = TestPlaybackException(code)

    private class TestPlaybackException(code: Int) :
        PlaybackException("test", null, code, Bundle.EMPTY, 0L)
}
