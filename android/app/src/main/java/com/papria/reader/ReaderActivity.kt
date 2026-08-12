package com.papria.reader

import android.content.Context
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.os.Build
import android.text.Html
import android.os.Bundle
import android.os.ParcelFileDescriptor
import com.papria.reader.BuildConfig
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Color as ComposeColor
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Settings
import androidx.core.content.ContextCompat
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.distinctUntilChanged
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.key
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.local.AudioProgressRecord
import com.papria.reader.core.local.ReadingProgressRecord
import com.papria.reader.core.reader.ComicArchive
import com.papria.reader.core.reader.EpubBook
import com.papria.reader.core.reader.EpubCfiResolution
import com.papria.reader.core.reader.InternalEpubConverter
import com.papria.reader.core.reader.FormatCoreRuntime
import com.papria.reader.core.reader.ReadiumProgressHost
import com.papria.reader.core.reader.PdfFitMode
import com.papria.reader.core.reader.PdfPresentationState
import com.papria.reader.core.reader.PdfPresentationStore
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.BookOrbitRepository
import com.papria.reader.core.audio.PapriaAudioService
import com.papria.reader.core.model.FileProgress
import com.papria.reader.core.display.DisplayMode
import com.papria.reader.core.display.CoverCache
import com.papria.reader.core.sync.BookOrbitSyncWorker
import com.papria.reader.ui.PapriaTheme
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.ceil

/** Dependency-free reader for formats rendered by Android SDK APIs. */
class ReaderActivity : FragmentActivity(), ReadiumProgressHost {
    private var fileId: Long = -1
    private var progressId: Long = -1
    private var bookId: Long = 0
    private var path: String = ""
    private var title: String = "Papria Reader"
    private var format: String = ""
    private var remoteAudio: Boolean = false
    private var audioHeaders: Map<String, String> = emptyMap()
    private var remotePaths: List<String> = emptyList()
    private var remoteTrackIds: LongArray = longArrayOf()
    private var remoteTrackTitles: List<String> = emptyList()
    private var remoteTrackIndex: Int = 0
    private var audioDurationMs: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        fileId = intent.getLongExtra(EXTRA_FILE_ID, -1)
        progressId = intent.getLongExtra(EXTRA_PROGRESS_ID, fileId)
        bookId = intent.getLongExtra(EXTRA_BOOK_ID, 0)
        path = intent.getStringExtra(EXTRA_PATH).orEmpty()
        title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { "Papria Reader" }
        format = intent.getStringExtra(EXTRA_FORMAT).orEmpty()
        remoteAudio = intent.getBooleanExtra(EXTRA_REMOTE_AUDIO, false)
        @Suppress("UNCHECKED_CAST")
        audioHeaders = (intent.getSerializableExtra(EXTRA_HEADERS) as? HashMap<String, String>).orEmpty()
        remotePaths = intent.getStringArrayListExtra(EXTRA_PATHS)?.toList().orEmpty()
        remoteTrackIds = intent.getLongArrayExtra(EXTRA_TRACK_IDS) ?: longArrayOf()
        remoteTrackTitles = intent.getStringArrayListExtra(EXTRA_TRACK_TITLES)?.toList().orEmpty()
        remoteTrackIndex = intent.getIntExtra(EXTRA_TRACK_INDEX, 0)
        audioDurationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L).takeIf { it > 0L }
        val mode = getSharedPreferences("display", MODE_PRIVATE).getString("mode", com.papria.reader.core.display.DisplayMode.NORMAL.name)
            ?.let { runCatching { com.papria.reader.core.display.DisplayMode.valueOf(it) }.getOrDefault(com.papria.reader.core.display.DisplayMode.NORMAL) }
            ?: com.papria.reader.core.display.DisplayMode.NORMAL
        val database = PapriaDatabase.get(this)
        val initial = database.readingProgress(progressId)
        val initialAudio = database.audioProgress(if (bookId > 0) bookId else progressId)
        setContent {
            PapriaTheme(mode) {
                ReaderScreen(title, path, format, remoteAudio, audioHeaders, remotePaths, remoteTrackIds, remoteTrackTitles, remoteTrackIndex, audioDurationMs, fileId, bookId, progressId, initial, initialAudio, mode, ::saveProgress) {
                    withContext(Dispatchers.IO) {
                        val current = PapriaDatabase.get(this@ReaderActivity)
                        val profile = current.serverProfile()
                        if (profile != null && (fileId > 0 || bookId > 0)) {
                            val secure = com.papria.reader.core.security.SecureSessionStore(this@ReaderActivity)
                            val client = BookOrbitClient.fromPersistedProfile(profile)
                                ?: return@withContext current.readingProgress(fileId) to current.audioProgress(if (bookId > 0) bookId else progressId)
                            client.setSession(secure.decrypt(profile.accessToken), secure.decrypt(profile.refreshCookie))
                            val repository = BookOrbitRepository(this@ReaderActivity, client, current)
                            runCatching {
                                if (fileId > 0) repository.pullFileProgress(fileId)
                                if (bookId > 0) repository.pullAudioProgress(bookId)
                            }
                        }
                        current.readingProgress(progressId) to current.audioProgress(if (bookId > 0) bookId else progressId)
                    }
                }
            }
        }
    }

    override fun onStop() {
        // Progress is written synchronously to Room by the reader controls.
        // Queue the network upload when the reader leaves the foreground so
        // backgrounding/returning to the library does not wait for a timer.
        if (fileId > 0 || bookId > 0) BookOrbitSyncWorker.enqueue(this)
        super.onStop()
    }

    private fun saveProgress(progress: ReaderProgress) {
        if (progressId == 0L) return
        // AudioProgress is owned by Media3's foreground service. Do not emit a
        // document-progress outbox row for the same track: BookOrbit exposes
        // a separate audiobook endpoint with currentFileId/positionSeconds.
        if (format.lowercase() in AUDIO_FORMATS) return
        val database = PapriaDatabase.get(this)
        val previous = database.readingProgress(progressId)
        val value = FileProgress(
            percentage = progress.percentage.coerceIn(0.0, 100.0),
            cfi = progress.cfi,
            pageNumber = progress.pageNumber,
            positionSeconds = progress.positionSeconds,
            koboLocationSource = progress.koboLocationSource ?: previous?.koboLocationSource,
            koboLocationType = progress.koboLocationType ?: previous?.koboLocationType,
            koboLocationValue = progress.koboLocationValue ?: previous?.koboLocationValue,
            koboContentSourceProgressPercent = progress.koboContentSourceProgressPercent ?: previous?.koboContentSourceProgressPercent,
            koreaderProgress = progress.koreaderProgress ?: previous?.koreaderProgress,
        )
        if (fileId > 0) {
            // Saving the local snapshot must work while offline. The repository
            // method only touches SQLite/outbox; the worker performs networking.
            val profile = database.serverProfile()
            if (profile == null) {
                database.upsertReadingProgress(ReadingProgressRecord(fileId, value.percentage, value.cfi, value.pageNumber, value.positionSeconds, System.currentTimeMillis(), null, false, true, value.koboLocationSource, value.koboLocationType, value.koboLocationValue, value.koboContentSourceProgressPercent, value.koreaderProgress))
            } else {
                // A stale/invalid HTTP confirmation must disable remote work,
                // not make the current local reading position disappear.
                val client = BookOrbitClient.fromPersistedProfile(profile)
                    ?: BookOrbitClient("https://offline.invalid")
                BookOrbitRepository(this, client, database).saveLocalProgress(fileId, value)
            }
        } else {
            val now = System.currentTimeMillis()
            database.upsertReadingProgress(ReadingProgressRecord(progressId, value.percentage, value.cfi, value.pageNumber, value.positionSeconds, now, null, false, true))
        }
    }

    override fun saveReadiumProgress(progress: ReaderProgress) {
        saveProgress(progress)
    }

    companion object {
        const val EXTRA_FILE_ID = "fileId"
        const val EXTRA_PROGRESS_ID = "progressId"
        const val EXTRA_BOOK_ID = "bookId"
        const val EXTRA_PATH = "path"
        const val EXTRA_TITLE = "title"
        const val EXTRA_FORMAT = "format"
        const val EXTRA_REMOTE_AUDIO = "remoteAudio"
        const val EXTRA_HEADERS = "headers"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_TRACK_IDS = "trackIds"
        const val EXTRA_TRACK_TITLES = "trackTitles"
        const val EXTRA_TRACK_INDEX = "trackIndex"
        const val EXTRA_DURATION_MS = "durationMs"
        private val AUDIO_FORMATS = setOf("mp3", "m4a", "m4b", "ogg", "opus", "flac")
    }
}

data class ReaderProgress(
    val percentage: Double,
    val pageNumber: Int? = null,
    val positionSeconds: Double? = null,
    val cfi: String? = null,
    /** These fields come from BookOrbit and must survive a local page change. */
    val koboLocationSource: String? = null,
    val koboLocationType: String? = null,
    val koboLocationValue: String? = null,
    val koboContentSourceProgressPercent: Double? = null,
    val koreaderProgress: String? = null,
)

@Composable
private fun ReaderScreen(title: String, path: String, formatOverride: String, remoteAudio: Boolean, audioHeaders: Map<String, String>, remotePaths: List<String>, remoteTrackIds: LongArray, remoteTrackTitles: List<String>, remoteTrackIndex: Int, audioDurationMs: Long?, fileId: Long, bookId: Long, progressId: Long, initial: ReadingProgressRecord?, initialAudio: AudioProgressRecord?, displayMode: DisplayMode, onProgress: (ReaderProgress) -> Unit, pullRemote: suspend () -> Pair<ReadingProgressRecord?, AudioProgressRecord?>) {
    var currentProgress by remember(path, progressId) { mutableStateOf(initial) }
    var currentAudio by remember(path, bookId) { mutableStateOf(initialAudio) }
    // A child reader keeps its own chapter/page state.  Bump this token after
    // the remote pull so the first server snapshot is applied to that state
    // instead of only updating the label shown by the parent composable.
    var remoteProgressToken by remember(path, progressId, bookId) { mutableStateOf(0) }
    val persistProgress: (ReaderProgress) -> Unit = { next ->
        // Reader widgets only change their own locator. Merge that change with
        // the last server snapshot so Kobo/KOReader metadata is never erased
        // by a page-turn upload that does not know about those fields.
        val previous = currentProgress
        val merged = next.copy(
            koboLocationSource = next.koboLocationSource ?: previous?.koboLocationSource,
            koboLocationType = next.koboLocationType ?: previous?.koboLocationType,
            koboLocationValue = next.koboLocationValue ?: previous?.koboLocationValue,
            koboContentSourceProgressPercent = next.koboContentSourceProgressPercent ?: previous?.koboContentSourceProgressPercent,
            koreaderProgress = next.koreaderProgress ?: previous?.koreaderProgress,
        )
        currentProgress = ReadingProgressRecord(
            fileId = progressId,
            percentage = merged.percentage,
            cfi = merged.cfi,
            pageNumber = merged.pageNumber,
            positionSeconds = merged.positionSeconds,
            localUpdatedAt = System.currentTimeMillis(),
            remoteUpdatedAt = previous?.remoteUpdatedAt,
            dirty = fileId > 0,
            localOnly = fileId <= 0,
            koboLocationSource = merged.koboLocationSource,
            koboLocationType = merged.koboLocationType,
            koboLocationValue = merged.koboLocationValue,
            koboContentSourceProgressPercent = merged.koboContentSourceProgressPercent,
            koreaderProgress = merged.koreaderProgress,
        )
        onProgress(merged)
    }
    LaunchedEffect(fileId, bookId, progressId) {
        val (remoteProgress, remoteAudio) = pullRemote()
        currentProgress = remoteProgress ?: currentProgress
        currentAudio = remoteAudio ?: currentAudio
        remoteProgressToken++
    }
    val extension = formatOverride.ifBlank { File(path).extension }.lowercase()
    val convertedPath = remember(path, extension) {
        if (extension in setOf("mobi", "azw", "azw3", "fb2")) {
            val source = File(path)
            // Every app variant ships the shared core. A rejected conversion
            // stays unreadable; no platform PalmDOC/FB2 fallback is allowed.
            FormatCoreRuntime.convertToInternalEpubFile(source, extension)?.absolutePath ?: path
        } else path
    }
    val palette = readerPalette(displayMode)
    Column(Modifier.fillMaxSize().background(palette.canvas)) {
        // Recreate only once after a remote pull.  Local page turns update the
        // existing child state normally, while a server chapter/page or PDF/
        // comic page is guaranteed to become the visible initial state.
        key(remoteProgressToken) {
            when {
                extension == "pdf" -> PdfReader(title, path, progressId, currentProgress, displayMode, persistProgress)
                extension == "epub" || extension == "kepub" -> EpubReader(title, path, currentProgress, displayMode, persistProgress)
                extension == "cbz" || extension == "cbr" || extension == "cb7" -> ComicReader(title, path, currentProgress, displayMode, persistProgress)
                extension in setOf("mobi", "azw", "azw3", "fb2") -> EpubReader(title, convertedPath, currentProgress, displayMode, persistProgress)
                extension in setOf("mp3", "m4a", "m4b", "ogg", "opus", "flac") -> AudioReader(path, title, remoteAudio, fileId, bookId, progressId, audioDurationMs, currentAudio, audioHeaders, remotePaths, remoteTrackIds, remoteTrackTitles, remoteTrackIndex, displayMode, persistProgress)
                else -> TextReader(title, path, currentProgress, displayMode, persistProgress)
            }
        }
    }
}

@Composable
private fun ColumnScope.EpubReader(title: String, path: String, initial: ReadingProgressRecord?, displayMode: DisplayMode, onProgress: (ReaderProgress) -> Unit) {
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    val context = androidx.compose.ui.platform.LocalContext.current
    var retryGeneration by remember(path) { mutableStateOf(0) }
    val load = remember(path, retryGeneration) {
        runCatching {
            val source = File(path)
            require(source.isFile) { "文件不存在或已被移除" }
            EpubBook.open(source).also { require(it.chapters.isNotEmpty()) { "书籍中没有可读章节" } }
        }
    }
    val book = load.getOrNull()
    var fontSize by remember(path, displayMode) { mutableStateOf(if (eink) 21 else 19) }
    // 19sp × 1.75 and 21px × 1.65 both produce a 33–35 unit reading rhythm.
    var lineSpacing by remember(path, displayMode) { mutableStateOf(14) }
    var paragraphSpacing by remember(path) { mutableStateOf(0) }
    var margin by remember(path, displayMode) { mutableStateOf(if (eink) 24 else 16) }
    var raisedPaper by remember(path) { mutableStateOf(false) }
    // The default must be a system serif face in both profiles. The normal
    // profile may switch faces from its display settings panel; E03 stays on
    // the fixed high-readability serif baseline.
    var fontChoice by remember(path, displayMode) { mutableStateOf(0) }
    var showToc by remember(path) { mutableStateOf(false) }
    var showSettings by remember(path) { mutableStateOf(false) }
    var showControls by remember(path, displayMode) { mutableStateOf(true) }
    if (book == null) {
        ReaderFailureScreen(
            title = title,
            path = path,
            format = "EPUB",
            reason = load.exceptionOrNull()?.message ?: "文件可能已移动、受 DRM 保护或格式损坏。",
            displayMode = displayMode,
            onBack = { (context as? Activity)?.finish() },
            onRetry = { retryGeneration++ },
        )
        return
    }
    val cfiResolution = remember(path, initial?.cfi) { book.resolveCfi(initial?.cfi) }
    val locator = remember(path, initial?.cfi, initial?.percentage, initial?.pageNumber, fontSize, lineSpacing, paragraphSpacing, margin) {
        initialEpubLocation(book, initial, cfiResolution, fontSize, lineSpacing, paragraphSpacing, margin)
    }
    var chapter by remember(path, initial?.cfi, initial?.percentage, initial?.pageNumber) { mutableStateOf(locator.first) }
    var page by remember(path, initial?.cfi, initial?.percentage, initial?.pageNumber) { mutableStateOf(locator.second) }
    val pages = remember(book, chapter, fontSize, lineSpacing, paragraphSpacing, margin) {
        book.pages(chapter, fontSize, lineSpacing, paragraphSpacing, margin)
    }
    val safePage = page.coerceIn(0, (pages.size - 1).coerceAtLeast(0))
    if (safePage != page) page = safePage
    fun reflow(
        nextFontSize: Int = fontSize,
        nextLineSpacing: Int = lineSpacing,
        nextParagraphSpacing: Int = paragraphSpacing,
        nextMargin: Int = margin,
    ) {
        val offset = book.offsetForPage(chapter, page, fontSize, lineSpacing, paragraphSpacing, margin)
        fontSize = nextFontSize
        lineSpacing = nextLineSpacing
        paragraphSpacing = nextParagraphSpacing
        margin = nextMargin
        page = book.pageForOffset(chapter, offset, nextFontSize, nextLineSpacing, nextParagraphSpacing, nextMargin)
    }
    fun savePageProgress() {
        val total = book.chapters.indices.sumOf { index -> book.pages(index, fontSize, lineSpacing, paragraphSpacing, margin).size }.coerceAtLeast(1)
        val before = (0 until chapter).sumOf { index -> book.pages(index, fontSize, lineSpacing, paragraphSpacing, margin).size }
        onProgress(ReaderProgress((before + page + 1).toDouble() / total * 100, pageNumber = page + 1, cfi = book.cfiForPage(chapter, page, fontSize, lineSpacing, paragraphSpacing, margin)))
    }
    fun previousPage() {
        if (page > 0) {
            page--
        } else if (chapter > 0) {
            val previousChapter = chapter - 1
            val previousPages = book.pages(previousChapter, fontSize, lineSpacing, paragraphSpacing, margin)
            chapter = previousChapter
            page = (previousPages.size - 1).coerceAtLeast(0)
        }
        savePageProgress()
    }
    fun nextPage() {
        if (page + 1 < pages.size) {
            page++
        } else if (chapter + 1 < book.chapters.size) {
            chapter++
            page = 0
        }
        savePageProgress()
    }
    val totalPages = book.chapters.indices.sumOf { index ->
        book.pages(index, fontSize, lineSpacing, paragraphSpacing, margin).size
    }.coerceAtLeast(1)
    val pagesBefore = (0 until chapter).sumOf { index ->
        book.pages(index, fontSize, lineSpacing, paragraphSpacing, margin).size
    }
    val displayedPage = pagesBefore + page + 1
    val controlsEnabled = eink || showControls
    val currentChapter = book.chapters[chapter].title.ifBlank { "第 ${chapter + 1} 章" }

    Box(Modifier.fillMaxSize().background(if (raisedPaper && !eink) palette.raised else palette.canvas)) {
        Column(Modifier.fillMaxSize()) {
            ReaderTopBar(
                title = title,
                eink = eink,
                controlsVisible = controlsEnabled,
                tocEnabled = book.tableOfContents.isNotEmpty(),
                onBack = { (context as? Activity)?.finish() },
                onToc = { showToc = !showToc; showSettings = false },
                onDisplaySettings = { if (!eink) { showSettings = !showSettings; showToc = false } },
            )
            Box(
                Modifier.weight(1f).fillMaxWidth()
                    .background(if (raisedPaper && !eink) palette.raised else palette.canvas)
                    .pointerInput(chapter, page, pages.size, showControls, eink) {
                        detectTapGestures { position ->
                            if (!eink && position.x in size.width * 0.33f..size.width * 0.67f) {
                                showControls = !showControls
                                showToc = false
                                showSettings = false
                            } else if (position.x < size.width / 2f) {
                                previousPage()
                            } else {
                                nextPage()
                            }
                        }
                    },
            ) {
                Column(
                    Modifier.fillMaxSize().padding(
                        horizontal = if (eink) einkLength(margin.toFloat()) else margin.dp,
                        vertical = if (eink) einkLength(24f) else 32.dp,
                    ),
                ) {
                    Text(
                        currentChapter,
                        color = palette.primary,
                        style = TextStyle(
                            fontSize = if (eink) einkPixels(22f) else 20.sp,
                            lineHeight = if (eink) einkPixels(30f) else 28.sp,
                            fontWeight = if (eink) FontWeight.Bold else FontWeight.Medium,
                        ),
                    )
                    Spacer(Modifier.height(if (eink) einkLength(22f) else 28.dp))
                    Text(
                        pages.getOrNull(page) ?: "此页没有可读文字",
                        color = palette.primary,
                        style = TextStyle(
                            fontSize = readerBodyFontSize(fontSize, eink),
                            lineHeight = readerBodyLineHeight(fontSize, lineSpacing + paragraphSpacing, eink),
                            fontFamily = readerFont(fontChoice),
                            letterSpacing = 0.sp,
                        ),
                    )
                    if (cfiResolution is EpubCfiResolution.Unresolved) {
                        Spacer(Modifier.height(16.dp))
                        Text(
                            "已按阅读进度恢复位置：${cfiResolution.reason}",
                            color = palette.secondary,
                            style = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
                        )
                    }
                }
            }
            ReaderBottomBar(
                chapter = currentChapter,
                page = displayedPage,
                totalPages = totalPages,
                eink = eink,
                controlsVisible = controlsEnabled,
                previousEnabled = displayedPage > 1,
                nextEnabled = displayedPage < totalPages,
                onPrevious = ::previousPage,
                onNext = ::nextPage,
                onDisplaySettings = { if (!eink) { showSettings = !showSettings; showToc = false } },
            )
        }
        if (showToc && controlsEnabled) {
            ReaderOverlayPanel(
                title = "目录",
                eink = eink,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = if (eink) 48.dp else 64.dp),
            ) {
                book.tableOfContents.take(16).forEach { item ->
                    val target = book.pageIndexForHref(item.href, fontSize, lineSpacing, paragraphSpacing, margin)
                    Text(
                        "${"  ".repeat(item.depth.coerceIn(0, 4))}${item.title}",
                        Modifier.fillMaxWidth().clickable(enabled = target != null) {
                            if (target != null) {
                                chapter = target.first
                                page = target.second
                                showToc = false
                                savePageProgress()
                            }
                        }.padding(vertical = 10.dp),
                        color = palette.primary,
                        style = TextStyle(fontSize = if (eink) 17.sp else 16.sp, lineHeight = 24.sp),
                    )
                }
            }
        }
        if (showSettings && !eink && controlsEnabled) {
            ReaderDisplaySettings(
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
                fontChoice = fontChoice,
                raisedPaper = raisedPaper,
                onFontSmaller = { reflow(nextFontSize = (fontSize - 1).coerceAtLeast(14)) },
                onFontLarger = { reflow(nextFontSize = (fontSize + 1).coerceAtMost(30)) },
                onLineSpacingSmaller = { reflow(nextLineSpacing = (lineSpacing - 1).coerceAtLeast(8)) },
                onLineSpacingLarger = { reflow(nextLineSpacing = (lineSpacing + 1).coerceAtMost(20)) },
                onMarginSmaller = { reflow(nextMargin = (margin - 2).coerceAtLeast(8)) },
                onMarginLarger = { reflow(nextMargin = (margin + 2).coerceAtMost(32)) },
                onFontChange = { fontChoice = (fontChoice + 1) % 3 },
                onPaperChange = { raisedPaper = !raisedPaper },
            )
        }
    }
}

/** Resolve a standard EPUB CFI before rendering the first page. */
private fun initialEpubLocation(
    book: EpubBook,
    initial: ReadingProgressRecord?,
    cfiResolution: EpubCfiResolution,
    fontSize: Int,
    lineSpacing: Int,
    paragraphSpacing: Int,
    margin: Int,
): Pair<Int, Int> {
    if (cfiResolution is EpubCfiResolution.Resolved) {
        val pageCount = book.pages(cfiResolution.chapterIndex, fontSize, lineSpacing, paragraphSpacing, margin).size
        val page = book.pageForOffset(cfiResolution.chapterIndex, cfiResolution.textOffset, fontSize, lineSpacing, paragraphSpacing, margin)
        return cfiResolution.chapterIndex to page.coerceIn(0, (pageCount - 1).coerceAtLeast(0))
    }
    // A progress snapshot from another reader may have only percentage. Map
    // that global value to our deterministic chapter/page list.
    val pages = book.chapters.indices.map { index -> book.pages(index, fontSize, lineSpacing, paragraphSpacing, margin).size }
    val target = (((initial?.percentage ?: 0.0).coerceIn(0.0, 100.0) / 100.0) * pages.sum().coerceAtLeast(1)).toInt().coerceAtMost((pages.sum() - 1).coerceAtLeast(0))
    var remaining = target
    pages.forEachIndexed { index, count ->
        if (remaining < count) return index to remaining
        remaining -= count
    }
    val fallbackChapter = 0
    val fallbackPage = ((initial?.pageNumber ?: 1) - 1).coerceAtLeast(0)
    return fallbackChapter to fallbackPage
}

@Composable
private fun ColumnScope.TextReader(title: String, path: String, initial: ReadingProgressRecord?, displayMode: DisplayMode, onProgress: (ReaderProgress) -> Unit) {
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    val context = androidx.compose.ui.platform.LocalContext.current
    var retryGeneration by remember(path) { mutableStateOf(0) }
    val textLoad = remember(path, retryGeneration) {
        runCatching { readTextForReader(File(path)) }
    }
    val preview = textLoad.getOrNull()
    if (preview == null) {
        ReaderFailureScreen(
            title = title,
            path = path,
            format = File(path).extension.uppercase().ifBlank { "文本" },
            reason = textLoad.exceptionOrNull()?.message ?: "无法读取此文件。",
            displayMode = displayMode,
            onBack = { (context as? Activity)?.finish() },
            onRetry = { retryGeneration++ },
        )
        return
    }
    var percentage by remember(path) { mutableStateOf(initial?.percentage ?: 0.0) }
    var fontSize by remember(path, displayMode) { mutableStateOf(if (eink) 21 else 19) }
    var lineSpacing by remember(path, displayMode) { mutableStateOf(14) }
    var margin by remember(path, displayMode) { mutableStateOf(if (eink) 24 else 16) }
    // Normal text and water-ink pagination both begin with the required
    // system serif face. Normal mode can still switch faces from settings.
    var fontChoice by remember(path, displayMode) { mutableStateOf(0) }
    var raisedPaper by remember(path) { mutableStateOf(false) }
    var showSettings by remember(path) { mutableStateOf(false) }
    var showControls by remember(path, displayMode) { mutableStateOf(true) }
    val pages = remember(preview, fontSize, lineSpacing, margin, displayMode) {
        readerPages(preview, fontSize, lineSpacing, margin, eink)
    }
    var page by remember(path, pages.size, initial?.pageNumber, initial?.percentage) {
        val restored = initial?.pageNumber?.minus(1)
            ?: ((initial?.percentage ?: 0.0) / 100.0 * pages.size).toInt()
        mutableStateOf(restored.coerceIn(0, (pages.size - 1).coerceAtLeast(0)))
    }
    val safePage = page.coerceIn(0, (pages.size - 1).coerceAtLeast(0))
    if (safePage != page) page = safePage
    fun persistPage() {
        percentage = (page + 1).toDouble() / pages.size.coerceAtLeast(1) * 100.0
        onProgress(ReaderProgress(percentage = percentage, pageNumber = page + 1))
    }
    fun previousPage() {
        if (page > 0) {
            page--
            persistPage()
        }
    }
    fun nextPage() {
        if (page < pages.lastIndex) {
            page++
            persistPage()
        }
    }
    val controlsEnabled = eink || showControls
    Box(Modifier.fillMaxSize().background(if (raisedPaper && !eink) palette.raised else palette.canvas)) {
        Column(Modifier.fillMaxSize()) {
            ReaderTopBar(
                title = title,
                eink = eink,
                controlsVisible = controlsEnabled,
                tocEnabled = false,
                onBack = { (context as? Activity)?.finish() },
                onToc = {},
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
            Box(
                Modifier.weight(1f).fillMaxWidth()
                    .background(if (raisedPaper && !eink) palette.raised else palette.canvas)
                    .pointerInput(page, pages.size, showControls, eink) {
                        detectTapGestures { position ->
                            if (!eink && position.x in size.width * 0.33f..size.width * 0.67f) {
                                showControls = !showControls
                                showSettings = false
                            } else if (position.x < size.width / 2f) {
                                previousPage()
                            } else {
                                nextPage()
                            }
                        }
                    },
            ) {
                Column(
                    Modifier.fillMaxSize().padding(
                        horizontal = if (eink) einkLength(margin.toFloat()) else margin.dp,
                        vertical = if (eink) einkLength(24f) else 32.dp,
                    ),
                ) {
                    Text(
                        "正文",
                        color = palette.primary,
                        style = TextStyle(
                            fontSize = if (eink) einkPixels(22f) else 20.sp,
                            lineHeight = if (eink) einkPixels(30f) else 28.sp,
                            fontWeight = if (eink) FontWeight.Bold else FontWeight.Medium,
                        ),
                    )
                    Spacer(Modifier.height(if (eink) einkLength(22f) else 28.dp))
                    Text(
                        pages.getOrNull(page) ?: "没有可读内容",
                        color = palette.primary,
                        style = TextStyle(
                            fontSize = readerBodyFontSize(fontSize, eink),
                            lineHeight = readerBodyLineHeight(fontSize, lineSpacing, eink),
                            fontFamily = readerFont(fontChoice),
                            letterSpacing = 0.sp,
                        ),
                    )
                }
            }
            ReaderBottomBar(
                chapter = "正文",
                page = page + 1,
                totalPages = pages.size.coerceAtLeast(1),
                eink = eink,
                controlsVisible = controlsEnabled,
                previousEnabled = page > 0,
                nextEnabled = page < pages.lastIndex,
                onPrevious = ::previousPage,
                onNext = ::nextPage,
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
        }
        if (showSettings && !eink && controlsEnabled) {
            ReaderDisplaySettings(
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
                fontChoice = fontChoice,
                raisedPaper = raisedPaper,
                onFontSmaller = { fontSize = (fontSize - 1).coerceAtLeast(14) },
                onFontLarger = { fontSize = (fontSize + 1).coerceAtMost(30) },
                onLineSpacingSmaller = { lineSpacing = (lineSpacing - 1).coerceAtLeast(8) },
                onLineSpacingLarger = { lineSpacing = (lineSpacing + 1).coerceAtMost(20) },
                onMarginSmaller = { margin = (margin - 2).coerceAtLeast(8) },
                onMarginLarger = { margin = (margin + 2).coerceAtMost(32) },
                onFontChange = { fontChoice = (fontChoice + 1) % 3 },
                onPaperChange = { raisedPaper = !raisedPaper },
            )
        }
    }
}

private fun readerPages(text: String, fontSize: Int, lineSpacing: Int, margin: Int, eink: Boolean): List<String> {
    // Fixed, deterministic page budgets make the e-ink profile genuinely paged
    // and give normal text files stable page/percentage progress as well.
    val baseBudget = if (eink) 1320 else 1160
    val sizeAdjustment = (fontSize - if (eink) 21 else 19) * 34
    val lineAdjustment = (lineSpacing - 14) * 18
    val marginAdjustment = (margin - if (eink) 24 else 16) * 10
    val budget = (baseBudget - sizeAdjustment - lineAdjustment - marginAdjustment).coerceIn(480, 1800)
    return text.chunked(budget).ifEmpty { listOf("没有可读内容") }
}

/**
 * E-ink artwork is specified in physical pixels, unlike Android's normal
 * reader typography which is specified in scalable sp. Compose accepts text
 * as sp and layout as dp, so explicitly divide by the active density (and
 * font scale for text) to retain the requested raster size. Guarding the
 * denominator also keeps previews and unusual accessibility configurations
 * from producing non-finite layout values.
 */
@Composable
private fun einkLength(px: Float): Dp = with(LocalDensity.current) {
    val safePx = px.takeIf { it.isFinite() && it >= 0f } ?: 0f
    (safePx / density.coerceAtLeast(0.001f)).dp
}

@Composable
private fun einkPixels(px: Float): TextUnit = with(LocalDensity.current) {
    val safePx = px.takeIf { it.isFinite() && it >= 0f } ?: 0f
    (safePx / (density * fontScale).coerceAtLeast(0.001f)).sp
}

@Composable
private fun readerBodyFontSize(fontSize: Int, eink: Boolean) =
    if (eink) einkPixels(fontSize.toFloat()) else fontSize.sp

@Composable
private fun readerBodyLineHeight(fontSize: Int, lineSpacing: Int, eink: Boolean) =
    if (eink) {
        einkPixels(fontSize * 1.65f + (lineSpacing - 14))
    } else {
        (fontSize * 1.75f + (lineSpacing - 14)).sp
    }

private fun readerFont(choice: Int): FontFamily = when (choice % 3) {
    0 -> FontFamily.Serif
    2 -> FontFamily.Monospace
    else -> FontFamily.SansSerif
}

private fun fontLabel(choice: Int): String = when (choice % 3) {
    0 -> "字体：衬线"
    2 -> "字体：等宽"
    else -> "字体：无衬线"
}

private data class ReaderPalette(
    val canvas: ComposeColor,
    val raised: ComposeColor,
    val primary: ComposeColor,
    val secondary: ComposeColor,
    val disabled: ComposeColor,
    val line: ComposeColor,
    val action: ComposeColor,
    val success: ComposeColor,
    val warning: ComposeColor,
)

private fun readerPalette(displayMode: DisplayMode): ReaderPalette = if (displayMode == DisplayMode.EINK) {
    ReaderPalette(
        canvas = ComposeColor(0xFFFFFFFF),
        raised = ComposeColor(0xFFFFFFFF),
        primary = ComposeColor(0xFF000000),
        secondary = ComposeColor(0xFF292929),
        disabled = ComposeColor(0xFF757575),
        line = ComposeColor(0xFFD5D5D5),
        action = ComposeColor(0xFF000000),
        success = ComposeColor(0xFF000000),
        warning = ComposeColor(0xFF000000),
    )
} else {
    ReaderPalette(
        canvas = ComposeColor(0xFFF7F2E8),
        raised = ComposeColor(0xFFFFFCF6),
        primary = ComposeColor(0xFF20221F),
        secondary = ComposeColor(0xFF6F6C63),
        disabled = ComposeColor(0xFF9B978D),
        line = ComposeColor(0xFFD8D0C3),
        action = ComposeColor(0xFFB74632),
        success = ComposeColor(0xFF2D7168),
        warning = ComposeColor(0xFF9C661A),
    )
}

@Composable
private fun readerChromeAlpha(controlsVisible: Boolean, eink: Boolean): Float = if (eink) {
    1f
} else {
    animateFloatAsState(
        targetValue = if (controlsVisible) 1f else 0f,
        animationSpec = tween(durationMillis = 180),
        label = "readerControls",
    ).value
}

@Composable
private fun ReaderTopBar(
    title: String,
    eink: Boolean,
    controlsVisible: Boolean,
    tocEnabled: Boolean,
    onBack: () -> Unit,
    onToc: () -> Unit,
    onDisplaySettings: () -> Unit,
) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    val alpha = readerChromeAlpha(controlsVisible, eink)
    val enabled = controlsVisible || eink
    val ruleWidth = if (eink) einkLength(1f) else 1.dp
    Row(
        Modifier.fillMaxWidth()
            .height(if (eink) einkLength(48f) else 64.dp)
            .background(palette.raised)
            .border(width = ruleWidth, color = palette.line)
            .graphicsLayer { this.alpha = alpha }
            .padding(horizontal = if (eink) einkLength(8f) else 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ReaderHeaderButton(
            label = "返回",
            normalIcon = Icons.AutoMirrored.Rounded.ArrowBack,
            einkText = "←",
            enabled = enabled,
            eink = eink,
            onClick = onBack,
        )
        Text(
            title,
            Modifier.weight(1f).padding(horizontal = 8.dp),
            color = palette.primary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(
                fontSize = if (eink) einkPixels(22f) else 24.sp,
                lineHeight = if (eink) einkPixels(30f) else 32.sp,
                fontWeight = if (eink) FontWeight.Bold else FontWeight.SemiBold,
            ),
        )
        if (!eink) {
            ReaderHeaderButton(
                label = "目录",
                normalIcon = Icons.Rounded.Menu,
                einkText = "目录",
                enabled = enabled && tocEnabled,
                eink = false,
                onClick = onToc,
            )
            ReaderHeaderButton(
                label = "显示设置",
                normalIcon = Icons.Rounded.Settings,
                einkText = "显示设置",
                enabled = enabled,
                eink = false,
                onClick = onDisplaySettings,
            )
        }
    }
}

@Composable
private fun ReaderHeaderButton(
    label: String,
    normalIcon: ImageVector,
    einkText: String,
    enabled: Boolean,
    eink: Boolean,
    onClick: () -> Unit,
) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(if (eink) einkLength(48f) else 48.dp)
            .semantics { contentDescription = label },
    ) {
        if (eink) {
            Text(
                einkText,
                color = if (enabled) palette.primary else palette.disabled,
                textAlign = TextAlign.Center,
                style = TextStyle(
                    fontSize = if (einkText == "目录") einkPixels(16f) else einkPixels(30f),
                    lineHeight = einkPixels(32f),
                    fontWeight = if (einkText == "目录") FontWeight.Medium else FontWeight.Normal,
                ),
            )
        } else {
            Icon(
                imageVector = normalIcon,
                contentDescription = null,
                tint = if (enabled) palette.primary else palette.disabled,
                modifier = Modifier.size(28.dp),
            )
        }
    }
}

@Composable
private fun ReaderBottomBar(
    chapter: String,
    page: Int,
    totalPages: Int,
    eink: Boolean,
    controlsVisible: Boolean,
    previousEnabled: Boolean,
    nextEnabled: Boolean,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onDisplaySettings: () -> Unit,
) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    val alpha = readerChromeAlpha(controlsVisible, eink)
    val enabled = controlsVisible || eink
    val progress = page.toFloat() / totalPages.coerceAtLeast(1)
    val ruleWidth = if (eink) einkLength(1f) else 1.dp
    Column(
        Modifier.fillMaxWidth()
            .height(if (eink) einkLength(164f) else 132.dp)
            .background(palette.raised)
            .border(width = ruleWidth, color = palette.line)
            .graphicsLayer { this.alpha = alpha }
            .padding(
                horizontal = if (eink) einkLength(16f) else 20.dp,
                vertical = if (eink) einkLength(8f) else 10.dp,
            ),
    ) {
        if (eink) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "$page / $totalPages",
                    Modifier.weight(1f),
                    color = palette.primary,
                    textAlign = TextAlign.Center,
                    style = TextStyle(fontSize = einkPixels(18f), lineHeight = einkPixels(24f), fontWeight = FontWeight.Medium),
                )
                Text(
                    "${(progress * 100).toInt()}%",
                    color = palette.primary,
                    style = TextStyle(fontSize = einkPixels(18f), lineHeight = einkPixels(24f), fontWeight = FontWeight.Medium),
                )
            }
            Spacer(Modifier.height(einkLength(12f)))
            ReaderProgressTrack(progress = progress, eink = true, modifier = Modifier.fillMaxWidth().height(einkLength(10f)))
            Spacer(Modifier.height(einkLength(12f)))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                val previousPageEnabled = previousEnabled && enabled
                val nextPageEnabled = nextEnabled && enabled
                OutlinedButton(
                    onClick = onPrevious,
                    enabled = previousPageEnabled,
                    modifier = Modifier.weight(1f).height(einkLength(56f)),
                    border = BorderStroke(ruleWidth, if (previousPageEnabled) palette.primary else palette.disabled),
                    shape = RectangleShape,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = palette.primary,
                        disabledContentColor = palette.disabled,
                    ),
                ) { Text("←  上一页", style = TextStyle(fontSize = einkPixels(18f), fontWeight = FontWeight.Medium)) }
                OutlinedButton(
                    onClick = onNext,
                    enabled = nextPageEnabled,
                    modifier = Modifier.weight(1f).height(einkLength(56f)),
                    border = BorderStroke(ruleWidth, if (nextPageEnabled) palette.primary else palette.disabled),
                    shape = RectangleShape,
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = palette.primary,
                        disabledContentColor = palette.disabled,
                    ),
                ) { Text("下一页  →", style = TextStyle(fontSize = einkPixels(18f), fontWeight = FontWeight.Medium)) }
            }
        } else {
            Text(
                chapter,
                color = palette.secondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium),
            )
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                ReaderHeaderButton(
                    label = "上一页",
                    normalIcon = Icons.AutoMirrored.Rounded.ArrowBack,
                    einkText = "←",
                    enabled = previousEnabled && enabled,
                    eink = false,
                    onClick = onPrevious,
                )
                ReaderProgressTrack(progress = progress, eink = false, modifier = Modifier.weight(1f).height(5.dp))
                ReaderHeaderButton(
                    label = "下一页",
                    normalIcon = Icons.AutoMirrored.Rounded.ArrowForward,
                    einkText = "→",
                    enabled = nextEnabled && enabled,
                    eink = false,
                    onClick = onNext,
                )
                ReaderHeaderButton(
                    label = "显示设置",
                    normalIcon = Icons.Rounded.Settings,
                    einkText = "显示设置",
                    enabled = enabled,
                    eink = false,
                    onClick = onDisplaySettings,
                )
            }
            Text(
                "${(progress * 100).toInt()}% · $page / $totalPages",
                Modifier.fillMaxWidth(),
                color = palette.action,
                textAlign = TextAlign.Center,
                style = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
            )
        }
    }
}

/** A stable, actionable error state for every document renderer. */
@Composable
private fun ColumnScope.ReaderFailureScreen(
    title: String,
    path: String,
    format: String,
    reason: String,
    displayMode: DisplayMode,
    onBack: () -> Unit,
    onRetry: () -> Unit,
) {
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    ReaderTopBar(
        title = title,
        eink = eink,
        controlsVisible = true,
        tocEnabled = false,
        onBack = onBack,
        onToc = {},
        onDisplaySettings = {},
    )
    Column(
        Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            "$format 无法打开",
            color = palette.primary,
            style = TextStyle(fontSize = if (eink) einkPixels(22f) else 20.sp, lineHeight = if (eink) einkPixels(30f) else 28.sp, fontWeight = FontWeight.SemiBold),
        )
        Text(
            "文件：${File(path).name.ifBlank { path }}",
            color = palette.secondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            style = TextStyle(fontSize = if (eink) einkPixels(17f) else 16.sp, lineHeight = if (eink) einkPixels(25f) else 24.sp),
        )
        Text(
            "原因：${reason.ifBlank { "文件可能已移动、损坏或不受支持。" }}",
            color = palette.primary,
            style = TextStyle(fontSize = if (eink) einkPixels(17f) else 16.sp, lineHeight = if (eink) einkPixels(25f) else 24.sp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = onBack,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = if (eink) RectangleShape else RoundedCornerShape(6.dp),
                border = BorderStroke(1.dp, palette.primary),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
            ) { Text("返回") }
            Button(
                onClick = onRetry,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = if (eink) RectangleShape else RoundedCornerShape(6.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = palette.action,
                    contentColor = if (eink) ComposeColor.White else palette.raised,
                ),
            ) { Text("重试") }
        }
    }
}

@Composable
private fun ReaderProgressTrack(progress: Float, eink: Boolean, modifier: Modifier = Modifier) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    Box(modifier.background(if (eink) ComposeColor(0xFFD5D5D5) else palette.line)) {
        Box(
            Modifier.fillMaxHeight()
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .background(if (eink) ComposeColor.Black else palette.action),
        )
    }
}

@Composable
private fun ReaderOverlayPanel(title: String, eink: Boolean, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    val shape = if (eink) RectangleShape else RoundedCornerShape(6.dp)
    Column(
        modifier.fillMaxWidth().heightIn(max = 360.dp)
            .background(palette.raised, shape)
            .border(1.dp, palette.line, shape)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        Text(title, color = palette.primary, style = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold))
        Spacer(Modifier.height(8.dp))
        content()
    }
}

@Composable
private fun ReaderDisplaySettings(
    modifier: Modifier = Modifier,
    fontChoice: Int,
    raisedPaper: Boolean,
    onFontSmaller: () -> Unit,
    onFontLarger: () -> Unit,
    onLineSpacingSmaller: () -> Unit,
    onLineSpacingLarger: () -> Unit,
    onMarginSmaller: () -> Unit,
    onMarginLarger: () -> Unit,
    onFontChange: () -> Unit,
    onPaperChange: () -> Unit,
) {
    val palette = readerPalette(DisplayMode.NORMAL)
    val shape = RoundedCornerShape(6.dp)
    Column(
        modifier.width(272.dp).background(palette.raised, shape)
            .border(1.dp, palette.line, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("显示设置", color = palette.primary, style = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold))
        ReaderSettingsRow("字号", "−", onFontSmaller, "+", onFontLarger)
        ReaderSettingsRow("行距", "−", onLineSpacingSmaller, "+", onLineSpacingLarger)
        ReaderSettingsRow("边距", "−", onMarginSmaller, "+", onMarginLarger)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = onFontChange,
                modifier = Modifier.weight(1f).height(48.dp),
                border = BorderStroke(1.dp, palette.line),
                shape = shape,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
            ) { Text(fontLabel(fontChoice), maxLines = 1, overflow = TextOverflow.Ellipsis) }
            OutlinedButton(
                onClick = onPaperChange,
                modifier = Modifier.weight(1f).height(48.dp),
                border = BorderStroke(1.dp, palette.line),
                shape = shape,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
            ) { Text(if (raisedPaper) "纸张画布" else "浅色画布") }
        }
    }
}

@Composable
private fun ReaderSettingsRow(label: String, first: String, onFirst: () -> Unit, second: String, onSecond: () -> Unit) {
    val palette = readerPalette(DisplayMode.NORMAL)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), color = palette.secondary, style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp))
        OutlinedButton(
            onClick = onFirst,
            modifier = Modifier.size(48.dp).semantics { contentDescription = "减小$label" },
            border = BorderStroke(1.dp, palette.line),
            shape = RoundedCornerShape(6.dp),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
        ) { Text(first, style = TextStyle(fontSize = 20.sp)) }
        Spacer(Modifier.width(8.dp))
        OutlinedButton(
            onClick = onSecond,
            modifier = Modifier.size(48.dp).semantics { contentDescription = "增大$label" },
            border = BorderStroke(1.dp, palette.line),
            shape = RoundedCornerShape(6.dp),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
        ) { Text(second, style = TextStyle(fontSize = 20.sp)) }
    }
}

/** Settings shared by PDF and comic readers; normal mode exposes this from the reader chrome. */
@Composable
private fun ReaderPresentationSettings(
    modifier: Modifier = Modifier,
    title: String,
    fitWidth: Boolean,
    continuous: Boolean,
    directionLabel: String? = null,
    onResetZoom: () -> Unit,
    onToggleFit: () -> Unit,
    onToggleContinuous: () -> Unit,
    onToggleDirection: (() -> Unit)? = null,
) {
    val palette = readerPalette(DisplayMode.NORMAL)
    val shape = RoundedCornerShape(6.dp)
    Column(
        modifier.width(272.dp).background(palette.raised, shape)
            .border(1.dp, palette.line, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, color = palette.primary, style = TextStyle(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold))
        OutlinedButton(
            onClick = onResetZoom,
            modifier = Modifier.fillMaxWidth().height(48.dp).semantics { contentDescription = "重置缩放" },
            border = BorderStroke(1.dp, palette.line),
            shape = shape,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
        ) { Text("重置缩放") }
        OutlinedButton(
            onClick = onToggleFit,
            modifier = Modifier.fillMaxWidth().height(48.dp).semantics { contentDescription = if (fitWidth) "切换为适合页面" else "切换为适合宽度" },
            border = BorderStroke(1.dp, palette.line),
            shape = shape,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
        ) { Text(if (fitWidth) "适合页面" else "适合宽度") }
        OutlinedButton(
            onClick = onToggleContinuous,
            modifier = Modifier.fillMaxWidth().height(48.dp).semantics { contentDescription = if (continuous) "切换为单页阅读" else "切换为连续滚动" },
            border = BorderStroke(1.dp, palette.line),
            shape = shape,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
        ) { Text(if (continuous) "单页阅读" else "连续滚动") }
        if (directionLabel != null && onToggleDirection != null) {
            OutlinedButton(
                onClick = onToggleDirection,
                modifier = Modifier.fillMaxWidth().height(48.dp).semantics { contentDescription = "切换阅读方向：$directionLabel" },
                border = BorderStroke(1.dp, palette.line),
                shape = shape,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
            ) { Text(directionLabel) }
        }
    }
}

@Composable
private fun ReaderInlineFailure(
    path: String,
    format: String,
    reason: String,
    displayMode: DisplayMode,
    onBack: () -> Unit,
    onRetry: () -> Unit,
) {
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("$format 无法显示", color = palette.primary, style = TextStyle(fontSize = if (eink) einkPixels(22f) else 20.sp, fontWeight = FontWeight.SemiBold))
        Spacer(Modifier.height(12.dp))
        Text("文件：${File(path).name.ifBlank { path }}", color = palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
        Text("原因：$reason", color = palette.primary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(16.dp))
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedButton(
                onClick = onBack,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = if (eink) RectangleShape else RoundedCornerShape(6.dp),
                border = BorderStroke(1.dp, palette.primary),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.primary),
            ) { Text("返回书库") }
            Button(
                onClick = onRetry,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = if (eink) RectangleShape else RoundedCornerShape(6.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = palette.action,
                    contentColor = if (eink) ComposeColor.White else palette.raised,
                ),
            ) { Text("重试") }
        }
    }
}

@Composable
private fun ColumnScope.PdfReader(
    title: String,
    path: String,
    progressId: Long,
    initial: ReadingProgressRecord?,
    displayMode: DisplayMode,
    onProgress: (ReaderProgress) -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    var retryGeneration by remember(path) { mutableStateOf(0) }
    val pdfLoad = remember(path, retryGeneration) { inspectPdf(File(path)) }
    val count = pdfLoad.pageCount
    if (count <= 0) {
        ReaderFailureScreen(
            title = title,
            path = path,
            format = "PDF",
            reason = pdfLoad.reason ?: "PDF 没有可读页面。",
            displayMode = displayMode,
            onBack = { (context as? Activity)?.finish() },
            onRetry = { retryGeneration++ },
        )
        return
    }

    val presentationStore = remember(context, progressId) {
        PdfPresentationStore(context.getSharedPreferences("reader.pdf.presentation", Context.MODE_PRIVATE))
    }
    val savedPresentation = remember(path, progressId) { presentationStore.load(progressId) }
    val initialPage = initial?.pageNumber?.minus(1)
        ?: (((initial?.percentage ?: 0.0).coerceIn(0.0, 100.0) / 100.0) * count).toInt()
    var page by remember(path, count, initial?.pageNumber, initial?.percentage) {
        mutableStateOf(initialPage.coerceIn(0, count - 1))
    }
    // This changes in-reader navigation only. We continue to save the actual
    // PDF page number so BookOrbit's existing progress contract is unchanged.
    var reverse by remember(path) { mutableStateOf(false) }
    var scale by remember(path, progressId) { mutableStateOf(savedPresentation.zoom) }
    var offsetX by remember(path) { mutableStateOf(0f) }
    var offsetY by remember(path) { mutableStateOf(0f) }
    var continuous by remember(path, displayMode) { mutableStateOf(false) }
    var showSettings by remember(path, displayMode) { mutableStateOf(false) }
    var showControls by remember(path, displayMode) { mutableStateOf(true) }
    val continuousMode = continuous && !eink
    var fitMode by remember(path, progressId) { mutableStateOf(savedPresentation.fitMode) }
    val fitWidth = fitMode == PdfFitMode.WIDTH
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val displayedPdfPages = remember(count, reverse) {
        if (reverse) (count - 1 downTo 0).toList() else (0 until count).toList()
    }

    fun savePresentation() {
        presentationStore.save(progressId, PdfPresentationState(zoom = scale, fitMode = fitMode))
    }
    fun saveProgress() {
        onProgress(ReaderProgress((page + 1).toDouble() / count * 100, page + 1))
        savePresentation()
    }
    fun resetZoom() {
        scale = 1f
        offsetX = 0f
        offsetY = 0f
        fitMode = PdfFitMode.PAGE
        savePresentation()
    }
    fun toggleDoubleTapZoom() {
        if (scale > 1.01f) {
            resetZoom()
        } else {
            scale = 2f
            offsetX = 0f
            offsetY = 0f
            savePresentation()
        }
    }
    fun previousPage() {
        val target = if (reverse) page + 1 else page - 1
        if (target in 0 until count) {
            page = target
            resetZoom()
            saveProgress()
        }
    }
    fun nextPage() {
        val target = if (reverse) page - 1 else page + 1
        if (target in 0 until count) {
            page = target
            resetZoom()
            saveProgress()
        }
    }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(PdfPresentationState.MIN_ZOOM, PdfPresentationState.MAX_ZOOM)
        offsetX += panChange.x
        offsetY += panChange.y
        savePresentation()
    }
    LaunchedEffect(continuousMode, listState, displayedPdfPages) {
        if (continuousMode) {
            listState.scrollToItem(displayedPdfPages.indexOf(page).coerceAtLeast(0))
            snapshotFlow { listState.firstVisibleItemIndex }
                .distinctUntilChanged()
                .collect { visible ->
                    page = displayedPdfPages.getOrNull(visible) ?: page
                    saveProgress()
                }
        }
    }
    val controlsEnabled = eink || showControls

    Box(Modifier.fillMaxSize().background(palette.canvas)) {
        Column(Modifier.fillMaxSize()) {
            ReaderTopBar(
                title = title,
                eink = eink,
                controlsVisible = controlsEnabled,
                tocEnabled = false,
                onBack = { (context as? Activity)?.finish() },
                onToc = {},
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
            Box(
                Modifier.weight(1f).fillMaxWidth().background(palette.canvas)
                    .pointerInput(page, count, showControls, eink, continuousMode) {
                        detectTapGestures(
                            onDoubleTap = { if (!eink && !continuousMode) toggleDoubleTapZoom() },
                            onTap = { position ->
                                if (!eink && position.x in size.width * 0.33f..size.width * 0.67f) {
                                    showControls = !showControls
                                    showSettings = false
                                } else if (!continuousMode && position.x < size.width / 2f) {
                                    previousPage()
                                } else if (!continuousMode) {
                                    nextPage()
                                }
                            },
                        )
                    },
            ) {
                if (continuousMode) {
                    LazyColumn(Modifier.fillMaxSize(), state = listState) {
                        items(displayedPdfPages) { pdfPage ->
                            val image = remember(path, pdfPage, retryGeneration) { renderPdfPage(path, pdfPage) }
                            if (image != null) {
                                Image(
                                    image.asImageBitmap(),
                                    contentDescription = "PDF 第 ${pdfPage + 1} 页",
                                    contentScale = if (fitWidth) ContentScale.FillWidth else ContentScale.Fit,
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                )
                            }
                        }
                    }
                } else {
                    val bitmap = remember(path, page, retryGeneration) { renderPdfPage(path, page) }
                    if (bitmap != null) {
                        Image(
                            bitmap.asImageBitmap(),
                            contentDescription = "PDF 第 ${page + 1} 页；双击缩放，双指缩放并拖动平移",
                            contentScale = if (fitWidth) ContentScale.FillWidth else ContentScale.Fit,
                            modifier = Modifier.fillMaxSize().transformable(transformState)
                                .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offsetX, translationY = offsetY),
                        )
                    } else {
                        ReaderInlineFailure(
                            path = path,
                            format = "PDF",
                            reason = "第 ${page + 1} 页无法渲染。",
                            displayMode = displayMode,
                            onBack = { (context as? Activity)?.finish() },
                            onRetry = { retryGeneration++ },
                        )
                    }
                }
            }
            ReaderBottomBar(
                chapter = if (continuousMode) "PDF 连续滚动 · 第 ${page + 1} 页" else "PDF · 第 ${page + 1} 页",
                page = page + 1,
                totalPages = count,
                eink = eink,
                controlsVisible = controlsEnabled,
                previousEnabled = if (reverse) page + 1 < count else page > 0,
                nextEnabled = if (reverse) page > 0 else page + 1 < count,
                onPrevious = ::previousPage,
                onNext = ::nextPage,
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
        }
        if (showSettings && !eink && controlsEnabled) {
            ReaderPresentationSettings(
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
                title = "PDF 显示设置",
                fitWidth = fitWidth,
                continuous = continuous,
                directionLabel = if (reverse) "从左到右" else "从右到左",
                onResetZoom = ::resetZoom,
                onToggleFit = {
                    fitMode = if (fitWidth) PdfFitMode.PAGE else PdfFitMode.WIDTH
                    scale = 1f
                    offsetX = 0f
                    offsetY = 0f
                    savePresentation()
                },
                onToggleContinuous = { continuous = !continuous; showSettings = false },
                onToggleDirection = { reverse = !reverse; resetZoom() },
            )
        }
    }
}

@Composable
private fun ColumnScope.ComicReader(
    title: String,
    path: String,
    initial: ReadingProgressRecord?,
    displayMode: DisplayMode,
    onProgress: (ReaderProgress) -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    var retryGeneration by remember(path) { mutableStateOf(0) }
    val comicLoad = remember(path, retryGeneration) { inspectComic(File(path)) }
    val entries = comicLoad.entries
    if (entries.isEmpty()) {
        ReaderFailureScreen(
            title = title,
            path = path,
            format = "漫画",
            reason = comicLoad.reason ?: "漫画中没有可读图像。",
            displayMode = displayMode,
            onBack = { (context as? Activity)?.finish() },
            onRetry = { retryGeneration++ },
        )
        return
    }

    val initialPage = initial?.pageNumber?.minus(1)
        ?: (((initial?.percentage ?: 0.0).coerceIn(0.0, 100.0) / 100.0) * entries.size).toInt()
    var page by remember(path, entries.size, initial?.pageNumber, initial?.percentage) {
        mutableStateOf(initialPage.coerceIn(0, entries.lastIndex))
    }
    var reverse by remember(path) { mutableStateOf(false) }
    var scale by remember(path) { mutableStateOf(1f) }
    var offsetX by remember(path) { mutableStateOf(0f) }
    var offsetY by remember(path) { mutableStateOf(0f) }
    // Width fitting is the required default for single-page comics.
    var fitWidth by remember(path) { mutableStateOf(true) }
    var continuous by remember(path, displayMode) { mutableStateOf(false) }
    var showSettings by remember(path, displayMode) { mutableStateOf(false) }
    var showControls by remember(path, displayMode) { mutableStateOf(true) }
    val continuousMode = continuous && !eink
    val listState = androidx.compose.foundation.lazy.rememberLazyListState(page)
    fun saveProgress() = onProgress(ReaderProgress((page + 1).toDouble() / entries.size * 100, page + 1))
    fun resetZoom() { scale = 1f; offsetX = 0f; offsetY = 0f }
    fun previousPage() {
        if (page > 0) { page--; resetZoom(); saveProgress() }
    }
    fun nextPage() {
        if (page < entries.lastIndex) { page++; resetZoom(); saveProgress() }
    }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(1f, 5f)
        offsetX += panChange.x
        offsetY += panChange.y
    }
    LaunchedEffect(continuousMode, listState, entries.size) {
        if (continuousMode) {
            snapshotFlow { listState.firstVisibleItemIndex }
                .distinctUntilChanged()
                .collect { visible ->
                    page = visible.coerceIn(0, entries.lastIndex)
                    saveProgress()
                }
        }
    }
    val controlsEnabled = eink || showControls
    fun entryAt(displayPage: Int): ComicArchive.Entry? {
        val archivePage = if (reverse) entries.lastIndex - displayPage else displayPage
        return entries.getOrNull(archivePage)
    }

    Box(Modifier.fillMaxSize().background(palette.canvas)) {
        Column(Modifier.fillMaxSize()) {
            ReaderTopBar(
                title = title,
                eink = eink,
                controlsVisible = controlsEnabled,
                tocEnabled = false,
                onBack = { (context as? Activity)?.finish() },
                onToc = {},
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
            Box(
                Modifier.weight(1f).fillMaxWidth().background(palette.canvas)
                    .pointerInput(page, entries.size, showControls, eink, continuousMode) {
                        detectTapGestures { position ->
                            if (!eink && position.x in size.width * 0.33f..size.width * 0.67f) {
                                showControls = !showControls
                                showSettings = false
                            } else if (!continuousMode && position.x < size.width / 2f) {
                                previousPage()
                            } else if (!continuousMode) {
                                nextPage()
                            }
                        }
                    },
            ) {
                if (continuousMode) {
                    LazyColumn(Modifier.fillMaxSize(), state = listState) {
                        items(entries.indices.toList()) { displayPage ->
                            val bitmap = remember(path, displayPage, reverse, retryGeneration) {
                                decodeComicPage(File(path), entryAt(displayPage))
                            }
                            if (bitmap != null) {
                                Image(
                                    bitmap.asImageBitmap(),
                                    contentDescription = "漫画第 ${displayPage + 1} 页",
                                    contentScale = if (fitWidth) ContentScale.FillWidth else ContentScale.Fit,
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                )
                            }
                        }
                    }
                } else {
                    val bitmap = remember(path, page, reverse, retryGeneration) { decodeComicPage(File(path), entryAt(page)) }
                    if (bitmap != null) {
                        Image(
                            bitmap.asImageBitmap(),
                            contentDescription = "漫画第 ${page + 1} 页；可双指缩放并拖动平移",
                            contentScale = if (fitWidth) ContentScale.FillWidth else ContentScale.Fit,
                            modifier = Modifier.fillMaxSize().transformable(transformState)
                                .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offsetX, translationY = offsetY),
                        )
                    } else {
                        ReaderInlineFailure(
                            path = path,
                            format = "漫画",
                            reason = "第 ${page + 1} 页无法解析。",
                            displayMode = displayMode,
                            onBack = { (context as? Activity)?.finish() },
                            onRetry = { retryGeneration++ },
                        )
                    }
                }
            }
            ReaderBottomBar(
                chapter = if (continuousMode) "漫画连续滚动 · 第 ${page + 1} 页" else "漫画 · 第 ${page + 1} 页",
                page = page + 1,
                totalPages = entries.size,
                eink = eink,
                controlsVisible = controlsEnabled,
                previousEnabled = page > 0,
                nextEnabled = page < entries.lastIndex,
                onPrevious = ::previousPage,
                onNext = ::nextPage,
                onDisplaySettings = { if (!eink) showSettings = !showSettings },
            )
        }
        if (showSettings && !eink && controlsEnabled) {
            ReaderPresentationSettings(
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
                title = "漫画显示设置",
                fitWidth = fitWidth,
                continuous = continuous,
                directionLabel = if (reverse) "从左到右" else "从右到左",
                onResetZoom = ::resetZoom,
                onToggleFit = { fitWidth = !fitWidth; resetZoom() },
                onToggleContinuous = { continuous = !continuous; showSettings = false },
                onToggleDirection = { reverse = !reverse; resetZoom() },
            )
        }
    }
}

@Composable
private fun ColumnScope.AudioReader(path: String, title: String, remoteAudio: Boolean, fileId: Long, bookId: Long, progressId: Long, durationHintMs: Long?, initial: AudioProgressRecord?, headers: Map<String, String>, remotePaths: List<String>, remoteTrackIds: LongArray, remoteTrackTitles: List<String>, remoteTrackIndex: Int, displayMode: DisplayMode, onProgress: (ReaderProgress) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val eink = displayMode == DisplayMode.EINK
    val palette = readerPalette(displayMode)
    var playing by remember(path) { mutableStateOf(true) }
    var controller by remember(path) { mutableStateOf<MediaController?>(null) }
    val playbackSpeeds = remember { listOf(0.8f, 1.0f, 1.25f, 1.5f, 2.0f) }
    var speed by remember(path, initial?.playbackSpeed) {
        val saved = initial?.playbackSpeed ?: 1.0f
        mutableStateOf(playbackSpeeds.minBy { abs(it - saved) })
    }
    var positionMs by remember(path, initial?.currentFileId, initial?.positionSeconds) { mutableStateOf(((initial?.positionSeconds ?: 0.0) * 1000).toInt().coerceAtLeast(0)) }
    var sleepLabel by remember(path, initial?.sleepUntil) { mutableStateOf("关闭") }
    var speedExpanded by remember(path) { mutableStateOf(false) }
    var sleepExpanded by remember(path) { mutableStateOf(false) }
    var playbackFailure by remember(path) { mutableStateOf<String?>(null) }
    var playbackNotice by remember(path) { mutableStateOf<String?>(null) }
    val remoteSource = remoteAudio || path.startsWith("http://") || path.startsWith("https://")
    val cachedAudio = !remoteSource || File(path).isFile
    val offlineReason = if (remoteSource && !cachedAudio && !hasActiveNetwork(context)) {
        "离线：该音频尚未缓存，无法播放。"
    } else {
        null
    }
    val tracks = remember(path, bookId, remotePaths, remoteTrackIds.toList()) {
        if (remotePaths.isNotEmpty()) emptyList() else {
            val database = PapriaDatabase.get(context)
            database.localPublications().filter { candidate ->
                val sameBook = bookId > 0L && candidate.remoteBookId == bookId
                sameBook && candidate.format.lowercase() in setOf("mp3", "m4a", "m4b", "ogg", "opus", "flac") && !candidate.localPath.isNullOrBlank()
            }.sortedWith(compareBy({ it.remoteFileId ?: it.progressFileId }, { it.title.lowercase() }))
        }
    }
    var durationMs by remember(path, headers, durationHintMs) {
        mutableStateOf(
            durationHintMs ?: runCatching {
                val retriever = MediaMetadataRetriever()
                try {
                    // MediaMetadataRetriever has no authenticated-header overload
                    // on the API levels supported by Papria. Media3 receives the
                    // actual headers and supersedes this best-effort duration.
                    retriever.setDataSource(path)
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 1L
                } finally {
                    retriever.release()
                }
            }.getOrDefault(1).coerceAtLeast(1),
        )
    }
    val coverBitmap = remember(context.cacheDir, bookId, eink) {
        if (bookId <= 0) {
            null
        } else {
            val cached = CoverCache.cached(context, bookId)
            // E-ink audio pages must never decode the colour source. Prefer
            // the greyscale variant generated alongside the normal cover;
            // binary is a safe fallback for caches created before greyscale
            // generation was available.
            val coverFile = if (eink) cached?.gray ?: cached?.binary else cached?.color
            coverFile?.let { BitmapFactory.decodeFile(it.absolutePath) }
        }
    }
    DisposableEffect(context, path) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                playbackFailure = intent?.getStringExtra(PapriaAudioService.EXTRA_PLAYBACK_ERROR)
                    ?.ifBlank { "音频解码或资源读取失败，已停止播放。" }
                    ?: "音频解码或资源读取失败，已停止播放。"
                playing = false
            }
        }
        val filter = IntentFilter(PapriaAudioService.ACTION_PLAYBACK_ERROR)
        ContextCompat.registerReceiver(
            context,
            receiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        onDispose { runCatching { context.unregisterReceiver(receiver) } }
    }
    DisposableEffect(path, initial?.currentFileId, initial?.positionSeconds, offlineReason) {
        if (offlineReason != null) return@DisposableEffect onDispose { }
        val intent = Intent(context, PapriaAudioService::class.java).apply {
            action = PapriaAudioService.ACTION_PLAY
            putExtra(PapriaAudioService.EXTRA_PATH, path)
            putExtra(PapriaAudioService.EXTRA_TITLE, title)
            putExtra(PapriaAudioService.EXTRA_BOOK_ID, bookId)
            putExtra(PapriaAudioService.EXTRA_REMOTE_FILE_ID, fileId.coerceAtLeast(0))
            putExtra(PapriaAudioService.EXTRA_PROGRESS_ID, progressId)
            putExtra(PapriaAudioService.EXTRA_POSITION_MS, positionMs.toLong())
            putExtra(PapriaAudioService.EXTRA_SPEED, speed)
            putExtra(PapriaAudioService.EXTRA_SOURCE, if (fileId > 0 && bookId > 0) "bookorbit" else "local")
            if (headers.isNotEmpty()) putExtra(PapriaAudioService.EXTRA_HEADERS, HashMap(headers))
            if (remotePaths.size > 1) {
                putStringArrayListExtra(PapriaAudioService.EXTRA_PATHS, ArrayList(remotePaths))
                putExtra(PapriaAudioService.EXTRA_TRACK_IDS, remoteTrackIds)
                putStringArrayListExtra(PapriaAudioService.EXTRA_TRACK_TITLES, ArrayList(remoteTrackTitles))
                putExtra(PapriaAudioService.EXTRA_TRACK_INDEX, remoteTrackIndex.coerceIn(0, remotePaths.lastIndex))
            } else if (tracks.size > 1) {
                putStringArrayListExtra(PapriaAudioService.EXTRA_PATHS, ArrayList(tracks.mapNotNull { it.localPath }))
                putExtra(PapriaAudioService.EXTRA_TRACK_IDS, tracks.map { it.remoteFileId ?: it.progressFileId }.toLongArray())
                putStringArrayListExtra(PapriaAudioService.EXTRA_TRACK_TITLES, ArrayList(tracks.map { it.title }))
                putExtra(PapriaAudioService.EXTRA_TRACK_INDEX, tracks.indexOfFirst { it.remoteFileId == fileId }.coerceAtLeast(0))
            }
        }
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        // The audio service is application-owned. Leaving the reader UI must
        // not stop playback: MediaSession/lock-screen controls continue to
        // work while the app is backgrounded. A future explicit “停止” action
        // is the only path that should stop the service.
        onDispose { }
    }
    // Bind this page to the same MediaSession used by notification, lock-screen
    // and Bluetooth controls. The UI therefore reflects actual audio focus,
    // pause/resume and seek events instead of maintaining an independent timer.
    DisposableEffect(context, offlineReason) {
        if (offlineReason != null) return@DisposableEffect onDispose { }
        var connectedController: MediaController? = null
        val token = SessionToken(context, ComponentName(context, PapriaAudioService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        val listener = object : Player.Listener {
            fun update(player: Player) {
                playing = player.isPlaying
                positionMs = player.currentPosition.coerceAtLeast(0L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                player.duration.takeIf { it > 0L }?.let { durationMs = it }
                speed = playbackSpeeds.minBy { abs(it - player.playbackParameters.speed) }
            }

            override fun onEvents(player: Player, events: Player.Events) = update(player)

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                playing = isPlaying
                if (isPlaying) playbackNotice = null
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (!playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS) {
                    playbackNotice = "音频焦点丢失，已暂停播放。"
                }
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                playbackFailure = "音频解码或资源读取失败，已停止播放。"
                playing = false
            }
        }
        future.addListener(
            {
                runCatching { future.get() }.onSuccess { created ->
                    connectedController = created
                    controller = created
                    created.addListener(listener)
                    listener.update(created)
                }.onFailure {
                    // Playback still works through the foreground service; keep
                    // the page actionable if a controller binds late.
                    playbackNotice = "正在连接系统播放控件。"
                }
            },
            ContextCompat.getMainExecutor(context),
        )
        onDispose {
            connectedController?.removeListener(listener)
            connectedController?.release()
            if (controller === connectedController) controller = null
            future.cancel(false)
        }
    }
    LaunchedEffect(controller, playing, offlineReason) {
        while (playing && offlineReason == null) {
            delay(500)
            val active = controller
            if (active != null) {
                positionMs = active.currentPosition.coerceAtLeast(0L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                active.duration.takeIf { it > 0L }?.let { durationMs = it }
                playing = active.isPlaying
            } else {
                positionMs = (positionMs + 500).coerceAtMost(durationMs.toInt())
            }
        }
    }
    fun sendAudioAction(action: String, configure: Intent.() -> Unit = {}) {
        if (offlineReason != null) {
            playbackFailure = offlineReason
            playing = false
            return
        }
        context.startService(Intent(context, PapriaAudioService::class.java).apply {
            this.action = action
            configure()
        })
    }
    fun seekTo(nextPosition: Int) {
        positionMs = nextPosition.coerceIn(0, durationMs.toInt())
        controller?.seekTo(positionMs.toLong()) ?: sendAudioAction(PapriaAudioService.ACTION_SEEK) {
            putExtra(PapriaAudioService.EXTRA_POSITION_MS, positionMs.toLong())
        }
    }

    Column(Modifier.weight(1f).fillMaxWidth().background(palette.canvas)) {
        AudioTopBar(eink = eink, onBack = { (context as? Activity)?.finish() })
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val statusMessage = playbackFailure ?: offlineReason
            val noticeMessage = playbackNotice
            if (statusMessage != null) {
                AudioStatus(message = statusMessage, palette = palette, tone = AudioStatusTone.ERROR, eink = eink)
            } else if (noticeMessage != null) {
                AudioStatus(message = noticeMessage, palette = palette, tone = AudioStatusTone.WARNING, eink = eink)
            } else if (cachedAudio) {
                AudioStatus(message = "已缓存，可离线播放", palette = palette, tone = AudioStatusTone.SUCCESS, eink = eink)
            }
            AudioCover(bitmap = coverBitmap, title = title, palette = palette, eink = eink)
            Text(
                title,
                color = palette.primary,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(fontSize = 26.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold),
            )
            Text(
                remoteTrackTitles.getOrNull(remoteTrackIndex).orEmpty().ifBlank { "当前章节" },
                color = palette.secondary,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = TextStyle(fontSize = 17.sp, lineHeight = 24.sp),
            )
            Text(
                "${formatPlaybackTime(positionMs.toLong())} / ${formatPlaybackTime(durationMs)}",
                color = if (eink) palette.primary else palette.action,
                style = TextStyle(fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium),
            )
            Slider(
                value = positionMs.toFloat(),
                onValueChange = { positionMs = it.toInt() },
                onValueChangeFinished = { seekTo(positionMs) },
                valueRange = 0f..durationMs.toFloat(),
                modifier = Modifier.fillMaxWidth().semantics {
                    contentDescription = "播放进度：${formatPlaybackTime(positionMs.toLong())}，总时长 ${formatPlaybackTime(durationMs)}"
                },
                colors = SliderDefaults.colors(
                    thumbColor = if (eink) palette.primary else palette.action,
                    activeTrackColor = if (eink) palette.primary else palette.action,
                    inactiveTrackColor = if (eink) ComposeColor(0xFFD5D5D5) else palette.line,
                ),
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(
                    onClick = { seekTo(positionMs - 15_000) },
                    enabled = offlineReason == null,
                    modifier = Modifier.size(64.dp).semantics { contentDescription = "后退 15 秒" },
                    border = BorderStroke(1.dp, palette.primary),
                    shape = if (eink) RectangleShape else RoundedCornerShape(32.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = palette.primary,
                        disabledContentColor = palette.disabled,
                    ),
                ) { Text("↶\n15", textAlign = TextAlign.Center, style = TextStyle(fontSize = 16.sp, lineHeight = 18.sp)) }
                Button(
                    onClick = {
                        val action = if (playing) PapriaAudioService.ACTION_PAUSE else PapriaAudioService.ACTION_RESUME
                        if (!playing) playbackNotice = null
                        sendAudioAction(action)
                        playing = !playing
                    },
                    enabled = offlineReason == null,
                    modifier = Modifier.size(80.dp).semantics {
                        contentDescription = if (playing) "暂停播放" else "播放"
                    },
                    shape = if (eink) RectangleShape else RoundedCornerShape(40.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (eink) palette.primary else palette.action,
                        contentColor = if (eink) ComposeColor.White else palette.raised,
                        disabledContainerColor = palette.raised,
                        disabledContentColor = palette.disabled,
                    ),
                ) {
                    Icon(
                        imageVector = if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = null,
                        modifier = Modifier.size(36.dp),
                    )
                }
                OutlinedButton(
                    onClick = { seekTo(positionMs + 15_000) },
                    enabled = offlineReason == null,
                    modifier = Modifier.size(64.dp).semantics { contentDescription = "前进 15 秒" },
                    border = BorderStroke(1.dp, palette.primary),
                    shape = if (eink) RectangleShape else RoundedCornerShape(32.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = palette.primary,
                        disabledContentColor = palette.disabled,
                    ),
                ) { Text("15\n↷", textAlign = TextAlign.Center, style = TextStyle(fontSize = 16.sp, lineHeight = 18.sp)) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                playbackSpeeds.forEach { value ->
                    val selected = speed == value
                    Button(
                        onClick = {
                            speed = value
                            sendAudioAction(PapriaAudioService.ACTION_SET_SPEED) { putExtra(PapriaAudioService.EXTRA_SPEED, value) }
                        },
                        enabled = offlineReason == null,
                        modifier = Modifier.weight(1f).height(48.dp),
                        shape = if (eink) RectangleShape else RoundedCornerShape(0.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (selected) palette.action else palette.raised,
                            contentColor = if (selected) palette.raised else palette.primary,
                            disabledContainerColor = palette.raised,
                            disabledContentColor = palette.disabled,
                        ),
                        border = BorderStroke(1.dp, if (eink) palette.primary else palette.line),
                    ) { Text(audioSpeedLabel(value), style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium)) }
                }
            }
            Box(Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { sleepExpanded = true },
                    enabled = offlineReason == null,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    border = BorderStroke(1.dp, if (eink) palette.primary else palette.line),
                    shape = if (eink) RectangleShape else RoundedCornerShape(6.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = palette.primary,
                        disabledContentColor = palette.disabled,
                    ),
                ) {
                    Text("◷   睡眠计时：$sleepLabel", Modifier.weight(1f), textAlign = TextAlign.Start, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium))
                    Text("›", style = TextStyle(fontSize = 28.sp, lineHeight = 28.sp))
                }
                DropdownMenu(expanded = sleepExpanded, onDismissRequest = { sleepExpanded = false }) {
                    listOf("关闭", "15 分钟", "30 分钟", "本章结束").forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option) },
                            onClick = {
                                sleepLabel = option
                                val minutes = when (option) {
                                    "15 分钟" -> 15
                                    "30 分钟" -> 30
                                    "本章结束" -> ceil((durationMs - positionMs).coerceAtLeast(1_000).toDouble() / 60_000.0).toInt().coerceAtLeast(1)
                                    else -> 0
                                }
                                sendAudioAction(PapriaAudioService.ACTION_SLEEP_TIMER) {
                                    putExtra(PapriaAudioService.EXTRA_SLEEP_MINUTES, minutes)
                                }
                                sleepExpanded = false
                            },
                        )
                    }
                }
            }
            if (statusMessage == null) {
                Text(
                    "音频焦点丢失时会暂停播放；解码、离线或资源错误会保留在此处。",
                    color = palette.secondary,
                    textAlign = TextAlign.Center,
                    style = TextStyle(fontSize = 13.sp, lineHeight = 18.sp),
                )
            }
        }
    }
}

@Composable
private fun AudioTopBar(eink: Boolean, onBack: () -> Unit) {
    val palette = readerPalette(if (eink) DisplayMode.EINK else DisplayMode.NORMAL)
    Row(
        Modifier.fillMaxWidth().height(if (eink) 48.dp else 64.dp)
            .background(palette.raised).border(1.dp, palette.line).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ReaderHeaderButton(
            label = "返回",
            normalIcon = Icons.AutoMirrored.Rounded.ArrowBack,
            einkText = "←",
            enabled = true,
            eink = eink,
            onClick = onBack,
        )
        Text(
            "音频阅读",
            Modifier.weight(1f).padding(horizontal = 8.dp),
            color = palette.primary,
            style = TextStyle(fontSize = if (eink) einkPixels(22f) else 24.sp, lineHeight = if (eink) einkPixels(30f) else 32.sp, fontWeight = FontWeight.SemiBold),
        )
    }
}

private enum class AudioStatusTone {
    SUCCESS,
    WARNING,
    ERROR,
}

@Composable
private fun AudioStatus(message: String, palette: ReaderPalette, tone: AudioStatusTone, eink: Boolean) {
    val shape = if (eink) RectangleShape else RoundedCornerShape(6.dp)
    val color = when (tone) {
        AudioStatusTone.SUCCESS -> palette.success
        AudioStatusTone.WARNING -> palette.warning
        AudioStatusTone.ERROR -> palette.action
    }
    Row(
        Modifier.fillMaxWidth().border(1.dp, color, shape).padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (tone == AudioStatusTone.SUCCESS) "✓  $message" else "！  $message",
            color = color,
            textAlign = TextAlign.Center,
            style = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
        )
    }
}

@Composable
private fun AudioCover(bitmap: Bitmap?, title: String, palette: ReaderPalette, eink: Boolean) {
    val shape = if (eink) RectangleShape else RoundedCornerShape(8.dp)
    Box(
        Modifier.size(224.dp).clip(shape).background(palette.raised).border(1.dp, palette.line, shape),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap.asImageBitmap(),
                contentDescription = "$title 封面",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Text(
                "音频\n封面",
                color = palette.primary,
                textAlign = TextAlign.Center,
                style = TextStyle(fontSize = 28.sp, lineHeight = 38.sp, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Medium),
            )
        }
    }
}

private fun audioSpeedLabel(speed: Float): String = when (speed) {
    0.8f -> "0.8x"
    1.0f -> "1.0x"
    1.25f -> "1.25x"
    1.5f -> "1.5x"
    else -> "2.0x"
}

private fun formatPlaybackTime(milliseconds: Long): String {
    val seconds = (milliseconds.coerceAtLeast(0L) / 1_000).toInt()
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

private fun hasActiveNetwork(context: Context): Boolean {
    val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
    val network = manager.activeNetwork ?: return false
    val capabilities = manager.getNetworkCapabilities(network) ?: return false
    return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
}

private fun readTextForReader(file: File): String {
    require(file.isFile) { "文件不存在或已被移除" }
    return when (file.extension.lowercase()) {
        "txt", "md" -> file.inputStream().bufferedReader().use { it.readText().take(MAX_PREVIEW_CHARS) }
        "fb2" -> readFb2(file)
        "epub", "kepub" -> EpubBook.open(file).chapters.joinToString("\n\n") { chapter ->
            "${chapter.title}\n\n${chapter.text}"
        }.trim().take(MAX_PREVIEW_CHARS)
        "mobi", "azw", "azw3" -> PalmDocReader.read(file).take(MAX_PREVIEW_CHARS)
        else -> error("不支持预览此格式：${file.extension.uppercase().ifBlank { "未知格式" }}")
    }.also { require(it.isNotBlank()) { "文件中没有可读内容" } }
}

private data class PdfInspection(val pageCount: Int, val reason: String? = null)

private fun inspectPdf(file: File): PdfInspection = runCatching {
    require(file.isFile) { "文件不存在或已被移除" }
    val count = PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)).use { it.pageCount }
    require(count > 0) { "PDF 中没有可读页面" }
    PdfInspection(count)
}.getOrElse { PdfInspection(0, it.message ?: "PDF 文件损坏或不受支持") }

private fun renderPdfPage(path: String, pageIndex: Int): Bitmap? = runCatching {
    PdfRenderer(ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)).use { renderer ->
        if (pageIndex !in 0 until renderer.pageCount) return null
        renderer.openPage(pageIndex).use { page ->
            val maxPixels = 4_000_000L
            val requestedScale = 2.0
            val safeScale = minOf(requestedScale, kotlin.math.sqrt(maxPixels.toDouble() / (page.width.toLong() * page.height.toLong()).coerceAtLeast(1L)))
                .coerceAtLeast(0.5)
            val bitmap = Bitmap.createBitmap(
                (page.width * safeScale).toInt().coerceAtLeast(1),
                (page.height * safeScale).toInt().coerceAtLeast(1),
                Bitmap.Config.RGB_565,
            )
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            bitmap
        }
    }
}.getOrNull()

private data class ComicInspection(val entries: List<ComicArchive.Entry>, val reason: String? = null)

private fun inspectComic(file: File): ComicInspection = runCatching {
    require(file.isFile) { "文件不存在或已被移除" }
    ComicArchive.open(file).use { archive ->
        archive.entries.also { require(it.isNotEmpty()) { "压缩包中没有可读图像" } }
    }
}.fold(
    onSuccess = { ComicInspection(it) },
    onFailure = { ComicInspection(emptyList(), it.message ?: "漫画文件损坏或不受支持") },
)

private fun decodeComicPage(file: File, entry: ComicArchive.Entry?): Bitmap? = runCatching {
    if (entry == null) null else ComicArchive.open(file).use { archive -> archive.read(entry, maxBytes = 64L * 1024 * 1024) }.let { bytes ->
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val sample = if (bounds.outWidth > 0 && bounds.outHeight > 0) {
            var factor = 1
            while (bounds.outWidth / factor * (bounds.outHeight / factor) > 4_000_000) factor *= 2
            factor
        } else 1
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.RGB_565 })
    }
}.getOrNull()

private fun htmlToText(raw: String): String {
    val normalized = raw.replace(Regex("(?is)<(script|style)[^>]*>.*?</\\1>"), "")
        .replace(Regex("(?i)<br\\s*/?>"), "\n")
        .replace(Regex("(?i)</(p|div|h[1-6]|li|section|tr)>"), "\n\n")
        .replace(Regex("(?s)<[^>]+>"), " ")
    val rendered = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        Html.fromHtml(normalized, Html.FROM_HTML_MODE_LEGACY)
    } else {
        @Suppress("DEPRECATION")
        Html.fromHtml(normalized)
    }
    return rendered.toString().replace(Regex("[ \\t]+"), " ").replace(Regex("\\n{3,}"), "\n\n").trim()
}

private fun readFb2(file: File): String {
    val raw = file.inputStream().bufferedReader().use { it.readText() }
    return htmlToText(raw.replace(Regex("(?i)<image[^>]*/?>"), "").replace(Regex("(?i)</?(description|title-info|document-info|publish-info)[^>]*>"), ""))
        .take(MAX_PREVIEW_CHARS)
}

/** Reads the DRM-free PalmDOC subset used by classic MOBI/AZW files. */
private object PalmDocReader {
    fun read(file: File): String = runCatching {
        java.io.RandomAccessFile(file, "r").use { input ->
            require(input.length() >= 78) { "MOBI header is truncated" }
            val records = readU16(input, 76)
            require(records >= 2) { "MOBI has no text records" }
            val offsets = IntArray(records + 1)
            for (index in 0 until records) {
                input.seek(78L + index * 8L)
                offsets[index] = input.readInt()
            }
            offsets[records] = input.length().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            input.seek(offsets[0].toLong())
            val compression = readU16(input, offsets[0].toLong())
            val textLength = readU32(input, offsets[0].toLong() + 4).coerceAtMost(MAX_PREVIEW_CHARS.toLong()).toInt()
            val textRecords = readU16(input, offsets[0].toLong() + 8)
            val encryption = readU32(input, offsets[0].toLong() + 12)
            require(encryption == 0L) { "DRM-protected MOBI/AZW is not supported" }
            val output = java.io.ByteArrayOutputStream(textLength.coerceAtLeast(1024))
            for (record in 1..textRecords.coerceAtMost(records - 1)) {
                val start = offsets[record]
                val end = offsets[record + 1].coerceAtLeast(start)
                input.seek(start.toLong())
                val bytes = ByteArray((end - start).coerceAtMost(MAX_RECORD_BYTES))
                input.readFully(bytes)
                when (compression) {
                    1 -> output.write(bytes)
                    2 -> decompressPalmDoc(bytes, output)
                    else -> error("unsupported MOBI compression: $compression")
                }
                if (output.size() >= MAX_PREVIEW_CHARS) break
            }
            output.toString(Charsets.UTF_8.name()).replace(Regex("\\s+"), " ").trim()
        }
    }.getOrElse { throw IllegalArgumentException("${file.extension.uppercase()} 无法解析：${it.message}", it) }

    private fun decompressPalmDoc(bytes: ByteArray, output: java.io.ByteArrayOutputStream) {
        var index = 0
        while (index < bytes.size && output.size() < MAX_PREVIEW_CHARS) {
            val value = bytes[index++].toInt() and 0xff
            when {
                value == 0 -> output.write(0)
                value in 1..8 -> {
                    val count = value.coerceAtMost(bytes.size - index)
                    output.write(bytes, index, count); index += count
                }
                value in 9..0x7f -> output.write(value)
                value in 0x80..0xbf && index < bytes.size -> {
                    val next = bytes[index++].toInt() and 0xff
                    val distance = ((value and 0x3f) shl 5) or (next ushr 3)
                    val length = (next and 0x07) + 3
                    for (offset in 0 until length) {
                        val existing = output.toByteArray()
                        val position = existing.size - distance
                        if (position in existing.indices) output.write(existing[position].toInt())
                    }
                }
                else -> { output.write(' '.code); output.write(value xor 0x80) }
            }
        }
    }

    private fun readU16(input: java.io.RandomAccessFile, offset: Long): Int { input.seek(offset); return input.readUnsignedShort() }
    private fun readU32(input: java.io.RandomAccessFile, offset: Long): Long { input.seek(offset); return input.readInt().toLong() and 0xffff_ffffL }
    private const val MAX_RECORD_BYTES = 4 * 1024 * 1024
}

private const val MAX_PREVIEW_CHARS = 120_000
