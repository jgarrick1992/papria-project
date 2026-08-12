package com.papria.reader.core.audio

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.BookOrbitRepository
import com.papria.reader.core.local.AudioProgressRecord
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.model.AudioProgress
import java.io.File

/**
 * Foreground audiobook player backed by AndroidX Media3.
 *
 * Media3 owns the audio focus, media-button dispatch, notification and
 * lock-screen/Android Auto session.  The custom intents below are kept as the
 * app's private UI boundary, while standard controller commands operate on
 * the same ExoPlayer queue.  No BookOrbit request fields are translated here.
 */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class PapriaAudioService : MediaSessionService() {
    private val handler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var mediaSession: MediaSession? = null
    private var title = "Papria"
    private var bookId = 0L
    private var remoteFileId = 0L
    private var progressId = 0L
    private var source = "local"
    private var playbackSpeed = 1.0f
    private var playlist: List<AudioTrack> = emptyList()
    private var sleepUntil: Long? = null
    private var terminalPlaybackFailure = false
    /**
     * MediaSession remains backed by Media3. LibVLC is entered only after its
     * renderer/container failure and is never handed BookOrbit credentials.
     */
    private var libVlcFallback: LibVlcAudioFallback? = null
    private var libVlcTrackIndex: Int? = null

    private val sleep = Runnable {
        libVlcFallback?.pause() ?: player?.pause()
        saveProgress(sleepUntil = null)
    }

    private val checkpoint = object : Runnable {
        override fun run() {
            saveProgress()
            if (player != null) handler.postDelayed(this, CHECKPOINT_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Audio codec boundary: ${AudioCodecFallbackGate.selfCheck()}")
        player = ExoPlayer.Builder(this)
            .setHandleAudioBecomingNoisy(true)
            .setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_SPEECH)
                    .build(),
                true,
            )
            .build()
            .also { exo ->
                exo.addListener(object : Player.Listener {
                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        val index = exo.currentMediaItemIndex
                        playlist.getOrNull(index)?.let { track ->
                            remoteFileId = track.fileId
                            if (track.title.isNotBlank()) title = track.title
                        }
                        saveProgress()
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_ENDED && !terminalPlaybackFailure && libVlcFallback == null) saveProgress()
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        if (terminalPlaybackFailure || libVlcFallback != null) return
                        val index = exo.currentMediaItemIndex.coerceAtLeast(0)
                        val track = playlist.getOrNull(index)
                            ?: playlist.firstOrNull()
                            ?: return
                        if (AudioCodecFallbackGate.isDecoderFailure(error) && startLibVlcFallback(track, index, exo.currentPosition)) {
                            return
                        }
                        terminatePlayback(
                            message = AudioCodecFallbackGate.failureMessage(track.path, error),
                            errorCode = error.errorCodeName,
                        )
                    }
                })
            }
        mediaSession = MediaSession.Builder(this, requireNotNull(player)).build()
    }

    /** Media3 controllers (notification, lock screen, Android Auto) share this session. */
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    /** Handles Papria's existing private UI intents in addition to Media3 commands. */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> startPlayback(intent)
            ACTION_PAUSE -> libVlcFallback?.pause() ?: player?.pause()
            ACTION_RESUME -> if (!terminalPlaybackFailure) libVlcFallback?.play(playbackSpeed) ?: player?.play()
            ACTION_SEEK -> if (!terminalPlaybackFailure) {
                val position = intent.getLongExtra(EXTRA_POSITION_MS, 0L).coerceAtLeast(0L)
                libVlcFallback?.seekTo(position) ?: player?.seekTo(position)
            }
            ACTION_SET_SPEED -> if (!terminalPlaybackFailure) setSpeed(intent.getFloatExtra(EXTRA_SPEED, 1.0f))
            ACTION_NEXT -> if (!terminalPlaybackFailure) nextTrack()
            ACTION_PREVIOUS -> if (!terminalPlaybackFailure) previousTrack()
            ACTION_SLEEP_TIMER -> if (!terminalPlaybackFailure) setSleepTimer(intent.getIntExtra(EXTRA_SLEEP_MINUTES, 0))
            ACTION_STOP -> stopPlayback()
        }
        saveProgress()
        return super.onStartCommand(intent, flags, startId)
    }

    private fun startPlayback(intent: Intent) {
        val exo = player ?: return
        terminalPlaybackFailure = false
        releaseLibVlcFallback()
        exo.stop()
        exo.clearMediaItems()
        handler.removeCallbacks(checkpoint)

        bookId = intent.getLongExtra(EXTRA_BOOK_ID, 0L)
        remoteFileId = intent.getLongExtra(EXTRA_REMOTE_FILE_ID, 0L)
        progressId = intent.getLongExtra(EXTRA_PROGRESS_ID, remoteFileId)
        source = intent.getStringExtra(EXTRA_SOURCE).orEmpty().ifBlank { "local" }
        val progressScope = if (bookId > 0) bookId else progressId
        val saved = PapriaDatabase.get(this).audioProgress(progressScope)
        playbackSpeed = intent.getFloatExtra(EXTRA_SPEED, saved?.playbackSpeed ?: playbackSpeed).coerceIn(0.5f, 3.0f)
        sleepUntil = saved?.sleepUntil
        scheduleSleepTimer()

        val paths = intent.getStringArrayListExtra(EXTRA_PATHS)?.toList().orEmpty().ifEmpty {
            listOfNotNull(intent.getStringExtra(EXTRA_PATH))
        }
        if (paths.isEmpty()) return
        val ids = intent.getLongArrayExtra(EXTRA_TRACK_IDS)?.toList().orEmpty()
        val titles = intent.getStringArrayListExtra(EXTRA_TRACK_TITLES)?.toList().orEmpty()
        @Suppress("UNCHECKED_CAST")
        val headers = (intent.getSerializableExtra(EXTRA_HEADERS) as? HashMap<String, String>).orEmpty()
        playlist = paths.mapIndexed { index, path ->
            val fallbackTrackId = if (index == 0) {
                remoteFileId.takeIf { it != 0L } ?: progressId
            } else {
                0L
            }
            AudioTrack(
                path = path,
                fileId = ids.getOrNull(index) ?: fallbackTrackId,
                title = titles.getOrNull(index).orEmpty(),
                headers = headers,
            )
        }
        playlist.firstNotNullOfOrNull { track -> AudioCodecFallbackGate.localInputFailure(track.path) }?.let { message ->
            terminatePlayback(message = message, errorCode = "INPUT_REJECTED")
            return
        }
        val requestedIndex = intent.getIntExtra(EXTRA_TRACK_INDEX, 0).coerceIn(0, playlist.lastIndex)
        val restoredIndex = saved?.currentFileId?.let { savedId ->
            playlist.indexOfFirst { it.fileId == savedId }.takeIf { it >= 0 }
        } ?: requestedIndex
        val startPosition = if (saved != null && saved.currentFileId == playlist[restoredIndex].fileId) {
            (saved.positionSeconds * 1000.0).toLong().coerceAtLeast(0L)
        } else {
            intent.getLongExtra(EXTRA_POSITION_MS, 0L).coerceAtLeast(0L)
        }
        title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank {
            playlist[restoredIndex].title.ifBlank { "Papria" }
        }
        remoteFileId = playlist[restoredIndex].fileId

        val mediaSources = createMediaSources(playlist)
        if (mediaSources.isEmpty()) return
        exo.setMediaSources(mediaSources, restoredIndex, startPosition)
        exo.setPlaybackParameters(PlaybackParameters(playbackSpeed))
        exo.prepare()
        exo.playWhenReady = true
        handler.postDelayed(checkpoint, CHECKPOINT_MS)
    }

    private fun createMediaSources(tracks: List<AudioTrack>): List<MediaSource> {
        val headers = tracks.firstOrNull()?.headers.orEmpty()
        val dataSourceFactory = if (headers.isEmpty()) {
            DefaultDataSource.Factory(this)
        } else {
            DefaultDataSource.Factory(
                this,
                DefaultHttpDataSource.Factory().setDefaultRequestProperties(headers),
            )
        }
        val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
        return tracks.map { track ->
            val uri = if (URI_SCHEME.matches(track.path)) Uri.parse(track.path) else Uri.fromFile(File(track.path))
            val item = MediaItem.Builder()
                .setUri(uri)
                .setMediaId(track.fileId.toString())
                .setMediaMetadata(MediaMetadata.Builder().setTitle(track.title.ifBlank { "Papria" }).build())
                .build()
            mediaSourceFactory.createMediaSource(item)
        }
    }

    private fun previousTrack() {
        val exo = player ?: return
        val fallback = libVlcFallback
        if (fallback != null) {
            if (fallback.currentPositionMs() > PREVIOUS_RESTART_MS) {
                fallback.seekTo(0L)
            } else {
                val previousIndex = (libVlcTrackIndex ?: 0) - 1
                if (previousIndex >= 0) resumeMedia3At(previousIndex, 0L)
            }
        } else {
            if (exo.currentPosition > PREVIOUS_RESTART_MS) {
                exo.seekTo(0L)
            } else if (exo.hasPreviousMediaItem()) {
                exo.seekToPreviousMediaItem()
            }
        }
    }

    private fun nextTrack() {
        val exo = player ?: return
        val fallbackIndex = libVlcTrackIndex
        if (libVlcFallback != null && fallbackIndex != null) {
            val nextIndex = fallbackIndex + 1
            if (playlist.indices.contains(nextIndex)) resumeMedia3At(nextIndex, 0L)
        } else if (exo.hasNextMediaItem()) {
            exo.seekToNextMediaItem()
        }
    }

    private fun setSpeed(value: Float) {
        playbackSpeed = value.coerceIn(0.5f, 3.0f)
        player?.setPlaybackSpeed(playbackSpeed)
        libVlcFallback?.setSpeed(playbackSpeed)
        saveProgress()
    }

    private fun setSleepTimer(minutes: Int) {
        handler.removeCallbacks(sleep)
        sleepUntil = if (minutes > 0) System.currentTimeMillis() + minutes * 60_000L else null
        scheduleSleepTimer()
        saveProgress(sleepUntil)
    }

    private fun scheduleSleepTimer() {
        handler.removeCallbacks(sleep)
        val until = sleepUntil ?: return
        val remaining = until - System.currentTimeMillis()
        if (remaining > 0) handler.postDelayed(sleep, remaining) else sleep.run()
    }

    private fun stopPlayback() {
        saveProgress(sleepUntil = null)
        releaseLibVlcFallback()
        player?.stop()
        player?.clearMediaItems()
        playlist = emptyList()
        sleepUntil = null
        handler.removeCallbacks(sleep)
        handler.removeCallbacks(checkpoint)
        stopSelf()
    }

    /**
     * Uses the real packaged LibVLC decoder only after Media3 has reported a
     * codec/container failure. Any BookOrbit request header is rejected by the
     * policy before this method constructs a LibVLC [Media], so no bearer can
     * be copied into VLC options, a URI, Range request, or redirect.
     */
    private fun startLibVlcFallback(track: AudioTrack, trackIndex: Int, startAtMs: Long): Boolean {
        when (val route = AudioCodecFallbackGate.libVlcRoute(track.path, track.headers)) {
            is LibVlcRoute.Rejected -> {
                Log.i(TAG, "LibVLC fallback denied by authenticated-stream policy: ${route.reason}")
                return false
            }

            LibVlcRoute.Allowed -> Unit
        }
        val uri = if (URI_SCHEME.matches(track.path)) Uri.parse(track.path) else Uri.fromFile(File(track.path))
        val fallback = runCatching {
            LibVlcAudioFallback(
                this,
                object : LibVlcAudioFallback.Callbacks {
                    override fun onTimeChanged(positionMs: Long, durationMs: Long) {
                        // Checkpoints continue on the service timer. This
                        // callback intentionally carries no media URL/header.
                        if (durationMs > 0L) saveProgress()
                    }

                    override fun onEnded() {
                        val nextIndex = (libVlcTrackIndex ?: trackIndex) + 1
                        if (playlist.indices.contains(nextIndex)) {
                            resumeMedia3At(nextIndex, 0L)
                        } else {
                            saveProgress()
                            releaseLibVlcFallback()
                        }
                    }

                    override fun onError() {
                        terminatePlayback(
                            message = "LibVLC fallback 解码失败，已停止播放",
                            errorCode = "LIBVLC_DECODE_FAILED",
                        )
                    }
                },
            )
        }.getOrElse {
            // Native decoder exceptions can embed a URI, so do not attach the
            // throwable to logs where a BookOrbit bearer might later appear.
            Log.w(TAG, "LibVLC fallback could not initialise")
            return false
        }
        if (!fallback.start(uri, startAtMs, playbackSpeed)) {
            fallback.release()
            return false
        }
        releaseLibVlcFallback()
        libVlcFallback = fallback
        libVlcTrackIndex = trackIndex
        player?.pause()
        remoteFileId = track.fileId
        if (track.title.isNotBlank()) title = track.title
        Log.i(TAG, "Media3 codec failure switched to packaged LibVLC fallback")
        return true
    }

    private fun resumeMedia3At(trackIndex: Int, positionMs: Long) {
        val exo = player ?: return
        releaseLibVlcFallback()
        exo.seekTo(trackIndex, positionMs.coerceAtLeast(0L))
        exo.play()
    }

    private fun releaseLibVlcFallback() {
        libVlcFallback?.release()
        libVlcFallback = null
        libVlcTrackIndex = null
    }

    /**
     * A decoder/stream error must never leave an apparently active Media3
     * session emitting silence.  Checkpoint before clearing the queue, remove
     * lock-screen controls with the service, and publish an in-app-only
     * diagnostic without exposing the URL or authorization headers.
     */
    private fun terminatePlayback(message: String, errorCode: String) {
        if (terminalPlaybackFailure) return
        terminalPlaybackFailure = true
        saveProgress()
        handler.removeCallbacks(checkpoint)
        handler.removeCallbacks(sleep)
        releaseLibVlcFallback()
        player?.pause()
        player?.clearMediaItems()
        playlist = emptyList()
        Log.e(TAG, "Audio playback stopped: code=$errorCode; reason=$message")
        sendBroadcast(
            Intent(ACTION_PLAYBACK_ERROR)
                .setPackage(packageName)
                .putExtra(EXTRA_PLAYBACK_ERROR, message)
                .putExtra(EXTRA_PLAYBACK_ERROR_CODE, errorCode),
        )
        stopSelf()
    }

    private fun saveProgress(sleepUntil: Long? = this.sleepUntil) {
        val exo = player ?: return
        val fallback = libVlcFallback
        val activeIndex = libVlcTrackIndex ?: exo.currentMediaItemIndex
        val track = playlist.getOrNull(activeIndex) ?: return
        remoteFileId = track.fileId
        val persistedTrackId = track.fileId.takeIf { it != 0L } ?: progressId
        val duration = fallback?.durationMs()?.takeIf { it > 0L }
            ?: exo.duration.takeIf { it > 0L && it != C.TIME_UNSET }
            ?: 1L
        val position = fallback?.currentPositionMs() ?: exo.currentPosition.coerceAtLeast(0L)
        val percentage = (position.toDouble() / duration * 100.0).coerceIn(0.0, 100.0)
        val database = PapriaDatabase.get(this)
        if (source == "bookorbit" && bookId > 0 && remoteFileId > 0) {
            // Preserve the local audio checkpoint even when a persisted
            // cleartext confirmation became invalid for this endpoint.
            val client = database.serverProfile()?.let(BookOrbitClient::fromPersistedProfile)
                ?: BookOrbitClient("https://offline.invalid")
            BookOrbitRepository(this, client, database)
                .saveLocalAudioProgress(
                    bookId,
                    AudioProgress(percentage, remoteFileId, position / 1000.0),
                    playbackSpeed = playbackSpeed,
                    sleepUntil = sleepUntil,
                )
        } else if (progressId != 0L) {
            database.upsertAudioProgress(
                AudioProgressRecord(
                    progressId,
                    percentage,
                    persistedTrackId,
                    position / 1000.0,
                    System.currentTimeMillis(),
                    false,
                    playbackSpeed,
                    sleepUntil,
                ),
            )
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        saveProgress()
        // Keep the foreground session alive when the reader task is swiped;
        // the media notification/controller remains the owner of playback.
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        saveProgress(sleepUntil)
        handler.removeCallbacks(sleep)
        handler.removeCallbacks(checkpoint)
        releaseLibVlcFallback()
        mediaSession?.release()
        mediaSession = null
        player?.release()
        player = null
        super.onDestroy()
    }

    companion object {
        const val ACTION_PLAY = "com.papria.reader.audio.PLAY"
        const val ACTION_PAUSE = "com.papria.reader.audio.PAUSE"
        const val ACTION_RESUME = "com.papria.reader.audio.RESUME"
        const val ACTION_SEEK = "com.papria.reader.audio.SEEK"
        const val ACTION_STOP = "com.papria.reader.audio.STOP"
        const val ACTION_NEXT = "com.papria.reader.audio.NEXT"
        const val ACTION_PREVIOUS = "com.papria.reader.audio.PREVIOUS"
        const val ACTION_SLEEP_TIMER = "com.papria.reader.audio.SLEEP_TIMER"
        const val ACTION_SET_SPEED = "com.papria.reader.audio.SET_SPEED"
        /** Explicit app-local signal for a terminal decoder/Range failure. */
        const val ACTION_PLAYBACK_ERROR = "com.papria.reader.audio.PLAYBACK_ERROR"
        const val EXTRA_PATH = "path"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BOOK_ID = "bookId"
        const val EXTRA_REMOTE_FILE_ID = "remoteFileId"
        const val EXTRA_PROGRESS_ID = "progressId"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_SOURCE = "source"
        const val EXTRA_HEADERS = "headers"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_TRACK_IDS = "trackIds"
        const val EXTRA_TRACK_TITLES = "trackTitles"
        const val EXTRA_TRACK_INDEX = "trackIndex"
        const val EXTRA_SLEEP_MINUTES = "sleepMinutes"
        const val EXTRA_SPEED = "speed"
        const val EXTRA_PLAYBACK_ERROR = "playbackError"
        const val EXTRA_PLAYBACK_ERROR_CODE = "playbackErrorCode"
        private const val CHECKPOINT_MS = 5_000L
        private const val PREVIOUS_RESTART_MS = 5_000L
        private const val TAG = "PapriaAudio"
        private val URI_SCHEME = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://")
    }

    private data class AudioTrack(
        val path: String,
        val fileId: Long,
        val title: String,
        val headers: Map<String, String> = emptyMap(),
    )
}
