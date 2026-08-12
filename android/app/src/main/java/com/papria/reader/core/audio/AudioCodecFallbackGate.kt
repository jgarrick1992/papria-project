package com.papria.reader.core.audio

import androidx.media3.common.PlaybackException
import java.util.Locale

/**
 * Decoder and credential policy shared by Media3 and LibVLC. LibVLC is a real
 * second decoder in this target, but it deliberately never receives a
 * BookOrbit request header. LibVLC's public Android API does not offer a
 * redirect-scoped Authorization contract, so handing it a bearer would make a
 * cross-origin redirect impossible to audit safely.
 *
 * This object has no networking or playback side effects. It is deliberately
 * small so JVM tests can prove that neither a bearer nor a credential-shaped
 * query ever reaches the secondary decoder.
 */
internal object AudioCodecFallbackGate {
    private val supportedFileExtensions = setOf("m4b", "m4a", "mp3", "opus", "ogg", "flac")

    /**
     * BookOrbit's authenticated `/serve` URL has no filename extension, so
     * remote URLs remain eligible for Media3's real decoder probe.  A local
     * file outside the product's declared audio set is rejected up front.
     */
    fun localInputFailure(path: String): String? {
        if (REMOTE_URL.containsMatchIn(path)) return null
        val extension = extensionOf(path) ?: return "本地音频缺少可识别的格式扩展名"
        return if (extension in supportedFileExtensions) null else "不支持的本地音频格式：.$extension"
    }

    /** A VLC route is intentionally narrower than Media3's authenticated one. */
    fun libVlcRoute(path: String, headers: Map<String, String>): LibVlcRoute {
        localInputFailure(path)?.let { return LibVlcRoute.Rejected(it) }
        if (headers.isNotEmpty()) {
            return LibVlcRoute.Rejected("带认证头的 BookOrbit Range 流不会交给 LibVLC")
        }
        if (REMOTE_URL.containsMatchIn(path) && hasCredentialLikeQuery(path)) {
            return LibVlcRoute.Rejected("含凭据查询参数的远端地址不会交给 LibVLC")
        }
        return LibVlcRoute.Allowed
    }

    fun isDecoderFailure(error: PlaybackException): Boolean = error.errorCode in DECODER_FAILURE_CODES

    /** Returns a user-facing terminal reason without logging sensitive media data. */
    fun failureMessage(path: String, error: PlaybackException): String {
        val format = extensionOf(path)?.uppercase(Locale.ROOT) ?: "该音频"
        return when (error.errorCode) {
            in DECODER_FAILURE_CODES -> "$format 的编码不受当前设备解码器支持，已停止播放"

            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED ->
                "$format 音频容器损坏，已停止播放"

            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
            PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
            PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE ->
                "音频 Range 流请求失败，已停止播放；请检查网络和登录状态后重试"

            else ->
                "音频播放失败（${error.errorCodeName}），已停止播放"
        }
    }

    /** A stable production diagnostic; it intentionally contains no media metadata. */
    fun selfCheck(): String = "primary=Media3; libvlcFallback=packaged-local-or-headerless; authenticatedRange=Media3-only"

    private fun extensionOf(path: String): String? {
        val fileName = path.substringBefore('?').substringBefore('#').substringAfterLast('/')
        return fileName.substringAfterLast('.', missingDelimiterValue = "")
            .lowercase(Locale.ROOT)
            .takeIf { it.isNotEmpty() }
    }

    private fun hasCredentialLikeQuery(path: String): Boolean {
        val query = path.substringAfter('?', missingDelimiterValue = "").substringBefore('#')
        if (query.isBlank()) return false
        return query.split('&').any { field ->
            val name = field.substringBefore('=').lowercase(Locale.ROOT)
            name.contains("token") || name.contains("auth") || name.contains("signature") || name == "key"
        }
    }

    private val REMOTE_URL = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://")
    private val DECODER_FAILURE_CODES = setOf(
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
    )
}

internal sealed interface LibVlcRoute {
    object Allowed : LibVlcRoute
    data class Rejected(val reason: String) : LibVlcRoute
}
