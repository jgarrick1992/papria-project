package com.papria.reader.core.audio

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer

/**
 * The packaged LibVLC decoder for formats that Media3 cannot open.
 *
 * LibVLC is intentionally given only a local file URI or an unauthenticated
 * remote URI. BookOrbit's Authorization header remains inside Media3 because
 * this library has no redirect-scoped header API that can be proven not to
 * forward a bearer to another origin. This class never logs the URI.
 */
internal class LibVlcAudioFallback(
    context: Context,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        fun onTimeChanged(positionMs: Long, durationMs: Long)
        fun onEnded()
        fun onError()
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val libVlc = LibVLC(
        context.applicationContext,
        arrayListOf(
            "--no-video",
            "--no-metadata-network-access",
            "--no-sub-autodetect-file",
        ),
    )
    private val player = MediaPlayer(libVlc)
    private var released = false

    init {
        player.setEventListener { event ->
            if (released) return@setEventListener
            when (event.type) {
                MediaPlayer.Event.TimeChanged,
                MediaPlayer.Event.LengthChanged -> mainHandler.post {
                    if (!released) callbacks.onTimeChanged(player.time.coerceAtLeast(0L), player.length.coerceAtLeast(0L))
                }

                MediaPlayer.Event.EndReached -> mainHandler.post {
                    if (!released) callbacks.onEnded()
                }

                MediaPlayer.Event.EncounteredError -> mainHandler.post {
                    if (!released) callbacks.onError()
                }
            }
        }
    }

    fun start(uri: Uri, startAtMs: Long, playbackSpeed: Float): Boolean = runCatching {
        val media = Media(libVlc, uri)
        media.setHWDecoderEnabled(false, false)
        player.setMedia(media)
        media.release()
        player.play()
        player.setRate(playbackSpeed.coerceIn(0.5f, 3.0f))
        if (startAtMs > 0) player.time = startAtMs
        true
    }.getOrDefault(false)

    fun play(playbackSpeed: Float) {
        if (released) return
        player.setRate(playbackSpeed.coerceIn(0.5f, 3.0f))
        player.play()
    }

    fun pause() {
        if (!released) player.pause()
    }

    fun seekTo(positionMs: Long) {
        if (!released) player.time = positionMs.coerceAtLeast(0L)
    }

    fun setSpeed(playbackSpeed: Float) {
        if (!released) player.setRate(playbackSpeed.coerceIn(0.5f, 3.0f))
    }

    fun currentPositionMs(): Long = if (released) 0L else player.time.coerceAtLeast(0L)

    fun durationMs(): Long = if (released) 0L else player.length.coerceAtLeast(0L)

    fun isPlaying(): Boolean = !released && player.isPlaying

    fun release() {
        if (released) return
        released = true
        player.setEventListener(null)
        runCatching { player.stop() }
        player.release()
        libVlc.release()
    }
}
