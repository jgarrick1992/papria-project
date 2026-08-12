package com.papria.reader.ui

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.Observer
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.papria.reader.core.display.DisplayMode
import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.BookOrbitRepository
import com.papria.reader.core.bookorbit.CleartextHttpConfirmation
import com.papria.reader.core.bookorbit.RemoteBookPayload
import com.papria.reader.core.bookorbit.RemoteFilePayload
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.sync.BookOrbitSyncWorker
import com.papria.reader.core.sync.DownloadWorker
import com.papria.reader.core.transfer.WifiTransferService
import com.papria.reader.core.transfer.WifiTransferUploadSnapshot
import com.papria.reader.core.local.LocalPublication
import com.papria.reader.core.local.ReadingProgressRecord
import com.papria.reader.core.local.SyncConflictRecord
import com.papria.reader.core.storage.ContentAddressedStore
import com.papria.reader.core.reader.FormatPolicy
import com.papria.reader.core.display.CoverCache
import com.papria.reader.core.security.SecureSessionStore
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

class PapriaViewModel(application: Application) : AndroidViewModel(application) {
    private val database = PapriaDatabase.get(application)
    private val preferences = application.getSharedPreferences("display", Context.MODE_PRIVATE)
    private val uiPreferences = application.getSharedPreferences("papria-ui", Context.MODE_PRIVATE)
    private val workManager = WorkManager.getInstance(application)
    private var bookOrbitRepository: BookOrbitRepository? = null
    private val downloadProgressSamples = mutableMapOf<Long, DownloadProgressSample>()
    private val observedSyncWorkStates = mutableMapOf<String, WorkInfo.State>()
    private val syncWorkObserver = Observer<List<WorkInfo>> { workInfos ->
        val currentIds = workInfos.mapTo(mutableSetOf()) { it.id.toString() }
        observedSyncWorkStates.keys.retainAll(currentIds)
        workInfos.forEach { work ->
            val workId = work.id.toString()
            val previous = observedSyncWorkStates.put(workId, work.state)
            // Record a timestamp only when this process has observed a real
            // transition into SUCCEEDED. Existing historical WorkManager
            // entries do not expose their completion time, so they remain
            // intentionally unavailable instead of being relabelled as now.
            if (previous != null && previous != WorkInfo.State.SUCCEEDED && work.state == WorkInfo.State.SUCCEEDED) {
                val completedAt = System.currentTimeMillis()
                lastSuccessfulSyncAt = completedAt
                uiPreferences.edit().putLong(LAST_SUCCESSFUL_SYNC_AT_KEY, completedAt).apply()
            }
        }
    }

    var selectedDisplayMode by mutableStateOf(preferences.getString("mode", DisplayMode.NORMAL.name)?.let { runCatching { DisplayMode.valueOf(it) }.getOrDefault(DisplayMode.NORMAL) } ?: DisplayMode.NORMAL)
        private set
    var selectedTab by mutableStateOf(AppTab.LIBRARY)
        private set
    var bookOrbitDestination by mutableStateOf(BookOrbitDestination.CATALOG)
        private set
    var selectedRemoteBook by mutableStateOf<RemoteBookPayload?>(null)
        private set
    var wifiRunning by mutableStateOf(false)
        private set
    var wifiUrl by mutableStateOf<String?>(null)
        private set
    var wifiMessage by mutableStateOf("传书服务未启动")
        private set
    /** Receiver-side upload snapshots. These are emitted by WifiTransferServer only. */
    var wifiUploads by mutableStateOf<List<WifiTransferUploadSnapshot>>(emptyList())
        private set
    var connectionMessage by mutableStateOf("")
        private set
    var bookOrbitLoading by mutableStateOf(false)
        private set
    var bookOrbitOffline by mutableStateOf(false)
        private set
    var serverAddress by mutableStateOf("")
        private set
    var serverUsername by mutableStateOf<String?>(null)
        private set
    var serverCertificateSha256 by mutableStateOf<String?>(null)
        private set
    var storageSummary by mutableStateOf<StorageSummary?>(null)
        private set
    var onlyWifiDownloads by mutableStateOf(uiPreferences.getBoolean("only-wifi-downloads", false))
        private set
    var remoteBooks by mutableStateOf<List<RemoteBookPayload>>(emptyList())
        private set
    var conflicts by mutableStateOf<List<SyncConflictRecord>>(emptyList())
        private set
    var covers by mutableStateOf<Map<Long, CoverCache.CoverPaths>>(emptyMap())
        private set
    var readingPositions by mutableStateOf<Map<Long, ReadingProgressRecord>>(emptyMap())
        private set
    var conflictResolutionMessage by mutableStateOf<String?>(null)
        private set
    var lastResolvedConflict by mutableStateOf<SyncConflictRecord?>(null)
        private set
    /** Time of an observed, successfully completed one-time progress sync. */
    var lastSuccessfulSyncAt by mutableStateOf(
        uiPreferences.getLong(LAST_SUCCESSFUL_SYNC_AT_KEY, 0L).takeIf { it > 0L },
    )
        private set
    /** Actual WorkManager constraints for each queued / paused / failed task. */
    var wifiRestrictedDownloads by mutableStateOf<Set<Long>>(emptySet())
        private set
    /** Real transfer rates derived from successive persisted download checkpoints. */
    var downloadBytesPerSecond by mutableStateOf<Map<Long, Long>>(emptyMap())
        private set

    val publications = database.observePublications()
    val downloads = database.observeDownloads()

    init {
        workManager.getWorkInfosForUniqueWorkLiveData(BookOrbitSyncWorker.UNIQUE_NAME)
            .observeForever(syncWorkObserver)
        viewModelScope.launch {
            publications.collect { values ->
                val snapshot = withContext(Dispatchers.IO) {
                    val positions = values.mapNotNull { publication ->
                        database.readingProgress(publication.progressFileId)?.let { publication.progressFileId to it }
                    }.toMap()
                    val usedBytes = values.mapNotNull(LocalPublication::localPath)
                        .toSet()
                        .sumOf { path -> java.io.File(path).takeIf(java.io.File::isFile)?.length() ?: 0L }
                    PublicationSnapshot(
                        readingPositions = positions,
                        storageSummary = StorageSummary(
                            usedBytes = usedBytes,
                            freeBytes = ContentAddressedStore(getApplication()).freeBytes(),
                        ),
                    )
                }
                readingPositions = snapshot.readingPositions
                storageSummary = snapshot.storageSummary
            }
        }
        viewModelScope.launch {
            downloads.collect { values ->
                val now = SystemClock.elapsedRealtime()
                val activeIds = values.filter { it.state == "running" }.map { it.fileId }.toSet()
                val rates = downloadBytesPerSecond.toMutableMap()
                values.filter { it.state == "running" }.forEach { task ->
                    val previous = downloadProgressSamples[task.fileId]
                    if (previous != null && task.offsetBytes > previous.bytes) {
                        val elapsedMillis = (now - previous.atElapsedMillis).coerceAtLeast(1L)
                        rates[task.fileId] = ((task.offsetBytes - previous.bytes) * 1_000L / elapsedMillis).coerceAtLeast(1L)
                    }
                    downloadProgressSamples[task.fileId] = DownloadProgressSample(task.offsetBytes, now)
                }
                downloadProgressSamples.keys.retainAll(activeIds)
                rates.keys.retainAll(activeIds)
                downloadBytesPerSecond = rates
                val taskIds = values
                    .filter { it.state in setOf("queued", "running", "paused", "failed") }
                    .map { it.fileId }
                val restricted = withContext(Dispatchers.IO) {
                    taskIds.filter { fileId ->
                        runCatching {
                            workManager.getWorkInfosForUniqueWork("bookorbit-download-$fileId")
                                .get()
                                .any { info -> info.constraints.requiredNetworkType == NetworkType.UNMETERED }
                        }.getOrDefault(false)
                    }.toSet()
                }
                wifiRestrictedDownloads = restricted
            }
        }
        viewModelScope.launch {
            WifiTransferService.uploadSnapshot.collect { snapshot ->
                wifiUploads = snapshot.uploads
                if (snapshot.isRunning) {
                    wifiRunning = true
                } else if (wifiRunning) {
                    wifiRunning = false
                    wifiUrl = null
                    wifiMessage = "传书服务已停止"
                }
            }
        }
        // Restore the encrypted session without blocking the first local
        // library frame. If the server is unavailable, local/Wi-Fi features
        // remain usable and the user can reconnect from the BookOrbit tab.
        viewModelScope.launch(Dispatchers.IO) {
            val profile = database.serverProfile()
            if (profile == null) {
                // A user may have explicitly exited while retaining the
                // offline catalog. It remains useful after process restart,
                // but no server/session metadata is inferred from it.
                val cachedBooks = runCatching { database.cachedRemoteBooks() }.getOrDefault(emptyList())
                if (cachedBooks.isNotEmpty()) withContext(Dispatchers.Main) {
                    remoteBooks = cachedBooks
                    bookOrbitOffline = true
                    connectionMessage = "离线：仅显示已缓存内容"
                }
                return@launch
            }
            withContext(Dispatchers.Main) {
                serverAddress = profile.baseUrl
                serverUsername = profile.username
                serverCertificateSha256 = profile.certificateSha256
                bookOrbitLoading = true
            }
            val secure = SecureSessionStore(getApplication())
            val client = BookOrbitClient.fromPersistedProfile(profile) ?: run {
                withContext(Dispatchers.Main) {
                    bookOrbitLoading = false
                    bookOrbitOffline = true
                    connectionMessage = "离线：仅显示已缓存内容"
                }
                return@launch
            }
            client.setSession(secure.decrypt(profile.accessToken), secure.decrypt(profile.refreshCookie))
            val repository = BookOrbitRepository(getApplication(), client, database)
            bookOrbitRepository = repository
            runCatching {
                repository.verifyServerVersion()
                repository.queryAllBooks(100)
            }.onSuccess { books ->
                bookOrbitRepository = repository
                withContext(Dispatchers.Main) {
                    remoteBooks = books
                    bookOrbitOffline = false
                    bookOrbitLoading = false
                    connectionMessage = "已恢复 BookOrbit 会话，已缓存 ${books.size} 本书"
                }
            }.onFailure {
                val cachedBooks = runCatching { database.cachedRemoteBooks() }.getOrDefault(emptyList())
                withContext(Dispatchers.Main) {
                    remoteBooks = cachedBooks
                    bookOrbitOffline = true
                    bookOrbitLoading = false
                    connectionMessage = if (cachedBooks.isEmpty()) {
                        "离线：没有可用的已缓存书目"
                    } else {
                        "离线：仅显示已缓存内容"
                    }
                }
            }
        }
    }

    override fun onCleared() {
        workManager.getWorkInfosForUniqueWorkLiveData(BookOrbitSyncWorker.UNIQUE_NAME)
            .removeObserver(syncWorkObserver)
        super.onCleared()
    }

    fun setDisplayMode(mode: DisplayMode) {
        selectedDisplayMode = mode
        preferences.edit().putString("mode", mode.name).apply()
    }
    fun setTab(tab: AppTab) { selectedTab = tab }

    fun updateOnlyWifiDownloads(enabled: Boolean) {
        onlyWifiDownloads = enabled
        uiPreferences.edit().putBoolean("only-wifi-downloads", enabled).apply()
    }

    fun openBookOrbitBook(book: RemoteBookPayload) {
        selectedRemoteBook = book
        bookOrbitDestination = BookOrbitDestination.DETAIL
        if (book.files.isEmpty()) loadBook(book.id)
    }

    fun openDownloadTasks() {
        bookOrbitDestination = BookOrbitDestination.TASKS
    }

    fun returnToBookOrbitCatalog() {
        selectedRemoteBook = null
        bookOrbitDestination = BookOrbitDestination.CATALOG
    }

    fun returnFromDownloadTasks() {
        bookOrbitDestination = if (selectedRemoteBook == null) BookOrbitDestination.CATALOG else BookOrbitDestination.DETAIL
    }

    fun startWifiTransfer(context: Context) {
        val intent = Intent(context, WifiTransferService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        wifiRunning = true
        wifiMessage = "正在启动传书服务"
        viewModelScope.launch {
            delay(500)
            wifiUrl = WifiTransferService.currentUploadUrl
            if (wifiUrl == null) {
                wifiRunning = false
                wifiMessage = "传书服务启动失败：无法取得局域网地址"
            } else {
                wifiMessage = "传书服务运行中"
            }
        }
    }

    fun stopWifiTransfer(context: Context) {
        context.stopService(Intent(context, WifiTransferService::class.java))
        wifiRunning = false
        wifiUrl = null
        wifiMessage = "传书服务已停止"
    }

    fun cancelWifiUpload(uploadId: String) {
        if (WifiTransferService.cancelUpload(uploadId)) {
            wifiMessage = "已取消当前上传"
        } else {
            wifiMessage = "无法取消：上传已完成或服务已停止"
        }
    }

    fun scheduleSync(context: Context) {
        BookOrbitSyncWorker.enqueue(context)
        connectionMessage = "已加入进度同步队列"
        refreshConflicts()
    }

    fun refreshConflicts() {
        viewModelScope.launch(Dispatchers.IO) {
            val values = database.conflicts()
            withContext(Dispatchers.Main) { conflicts = values }
        }
    }

    fun resolveConflict(conflict: SyncConflictRecord, keepLocal: Boolean) {
        val repository = bookOrbitRepository ?: run {
            conflictResolutionMessage = "处理冲突失败：BookOrbit 未连接"
            return
        }
        conflictResolutionMessage = null
        lastResolvedConflict = null
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.resolveConflict(conflict, keepLocal) }
                .onSuccess {
                    withContext(Dispatchers.Main) {
                        conflicts = database.conflicts()
                        lastResolvedConflict = conflict
                        conflictResolutionMessage = if (keepLocal) {
                            "已保留本地进度；下一次同步前可恢复。"
                        } else {
                            "已使用服务器进度；下一次同步前可恢复。"
                        }
                    }
                }
                .onFailure { error ->
                    withContext(Dispatchers.Main) {
                        conflictResolutionMessage = "处理冲突失败：${error.message ?: "未知错误"}"
                    }
                }
        }
    }

    fun undoConflictResolution() {
        val conflict = lastResolvedConflict ?: return
        val repository = bookOrbitRepository ?: run {
            conflictResolutionMessage = "撤销失败：BookOrbit 未连接"
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.restoreConflictResolution(conflict) }
                .onSuccess {
                    withContext(Dispatchers.Main) {
                        conflicts = database.conflicts()
                        lastResolvedConflict = null
                        conflictResolutionMessage = "已撤销处理，冲突将在下一次同步前保留。"
                    }
                }
                .onFailure { error ->
                    withContext(Dispatchers.Main) {
                        conflictResolutionMessage = "撤销失败：${error.message ?: "未知错误"}"
                    }
                }
        }
    }

    fun connectBookOrbit(
        server: String,
        username: String,
        password: String,
        certificateSha256: String? = null,
        cleartextHttpConfirmed: Boolean = false,
        onSuccess: () -> Unit = {},
    ) {
        connectionMessage = "正在连接…"
        bookOrbitLoading = true
        bookOrbitOffline = false
        viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) {
                    val initialClient = BookOrbitClient(server.trimEnd('/'), certificateSha256?.trim()?.takeIf { it.isNotEmpty() })
                    val confirmation = if (initialClient.isCleartextHttp()) {
                        require(cleartextHttpConfirmed) { "请先明确确认当前局域网 HTTP 主机" }
                        CleartextHttpConfirmation(initialClient.host(), initialClient.port())
                    } else {
                        null
                    }
                    val client = BookOrbitClient(
                        serverUrl = initialClient.serverUrl(),
                        certificateSha256 = initialClient.certificateSha256(),
                        cleartextHttpConfirmation = confirmation,
                    )
                    val repository = BookOrbitRepository(getApplication(), client)
                    repository.login(username, password)
                    bookOrbitRepository = repository
                    com.papria.reader.core.bookorbit.BookPage(0, 100, 0, repository.queryAllBooks(100))
                }
                remoteBooks = page.books
                conflicts = database.conflicts()
                serverAddress = server.trimEnd('/')
                serverUsername = username
                serverCertificateSha256 = certificateSha256?.trim()?.takeIf { it.isNotEmpty() }
                bookOrbitLoading = false
                bookOrbitOffline = false
                connectionMessage = "已连接 BookOrbit，已缓存 ${page.books.size} 本书"
                onSuccess()
            } catch (error: Exception) {
                bookOrbitLoading = false
                bookOrbitOffline = true
                connectionMessage = "连接失败：${error.message ?: "未知错误"}"
            }
        }
    }

    /** Exit the current BookOrbit account, optionally retaining local cache. */
    fun disconnectBookOrbit(retainOfflineCache: Boolean) {
        connectionMessage = "正在退出 BookOrbit…"
        bookOrbitLoading = true
        viewModelScope.launch(Dispatchers.IO) {
            workManager.cancelUniqueWork(BookOrbitSyncWorker.UNIQUE_NAME)
            workManager.cancelUniqueWork(BookOrbitSyncWorker.PERIODIC_UNIQUE_NAME)
            val cachedBooks = if (retainOfflineCache) {
                runCatching { database.cachedRemoteBooks() }.getOrDefault(emptyList())
            } else {
                database.deleteAllDownloadTasks()
                database.deleteCachedRemoteBooks()
                CoverCache.clear(getApplication())
                emptyList()
            }
            database.deleteServerProfile()
            withContext(Dispatchers.Main) {
                bookOrbitRepository = null
                selectedRemoteBook = null
                bookOrbitDestination = BookOrbitDestination.CATALOG
                remoteBooks = cachedBooks
                serverAddress = ""
                serverUsername = null
                serverCertificateSha256 = null
                bookOrbitOffline = retainOfflineCache && cachedBooks.isNotEmpty()
                bookOrbitLoading = false
                connectionMessage = if (bookOrbitOffline) {
                    "已退出 BookOrbit；已保留离线缓存"
                } else {
                    "已退出 BookOrbit；离线缓存已清除"
                }
            }
        }
    }

    fun enqueueDownload(context: Context, fileId: Long, onlyWifi: Boolean = onlyWifiDownloads) {
        DownloadWorker.enqueue(context, fileId, onlyWifi)
        wifiRestrictedDownloads = if (onlyWifi) wifiRestrictedDownloads + fileId else wifiRestrictedDownloads - fileId
        connectionMessage = "文件 $fileId 已加入下载队列${if (onlyWifi) "，仅 Wi-Fi 下载" else ""}"
    }

    fun pauseDownload(context: Context, fileId: Long) {
        DownloadWorker.pause(context, fileId)
        connectionMessage = "下载已暂停"
    }

    fun retryDownload(context: Context, fileId: Long) {
        DownloadWorker.retry(context, fileId, fileId in wifiRestrictedDownloads)
        connectionMessage = "正在重试下载"
    }

    fun removeDownload(fileId: Long) {
        DownloadWorker.cancel(getApplication(), fileId)
        wifiRestrictedDownloads = wifiRestrictedDownloads - fileId
        viewModelScope.launch(Dispatchers.IO) {
            database.deleteDownloadTask(fileId)
        }
    }

    fun removeDownloadedFile(context: Context, fileId: Long) {
        DownloadWorker.cancel(context, fileId)
        wifiRestrictedDownloads = wifiRestrictedDownloads - fileId
        viewModelScope.launch(Dispatchers.IO) {
            val publication = database.localPublications().firstOrNull { it.remoteFileId == fileId }
            if (publication != null) {
                deletePublicationFromStore(publication)
            } else {
                database.deleteDownloadTask(fileId)
            }
        }
    }

    fun clearCompletedDownloads() {
        viewModelScope.launch(Dispatchers.IO) {
            database.observeDownloads().first()
                .filter { it.state == "completed" }
                .forEach { database.deleteDownloadTask(it.fileId) }
        }
    }

    fun waitsForWifi(fileId: Long): Boolean = fileId in wifiRestrictedDownloads

    fun downloadRate(fileId: Long): Long? = downloadBytesPerSecond[fileId]

    fun playRemoteAudio(context: Context, bookId: Long, file: RemoteFilePayload, playlist: List<RemoteFilePayload> = listOf(file)) {
        val repository = bookOrbitRepository ?: run {
            connectionMessage = "请先连接 BookOrbit"
            return
        }
        if (file.format.lowercase() !in setOf("m4b", "m4a", "mp3", "opus", "ogg", "flac")) return
        runCatching {
            val audioFiles = (if (playlist.isEmpty()) listOf(file) else playlist)
                .filter { it.format.lowercase() in setOf("m4b", "m4a", "mp3", "opus", "ogg", "flac") }
            val streams = audioFiles.map { repository.audioStream(it.id) }
            val currentIndex = audioFiles.indexOfFirst { it.id == file.id }.coerceAtLeast(0)
            val stream = streams[currentIndex]
            context.startActivity(Intent(context, com.papria.reader.ReaderActivity::class.java).apply {
                putExtra(com.papria.reader.ReaderActivity.EXTRA_FILE_ID, file.id)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_BOOK_ID, bookId)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_PROGRESS_ID, file.id)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_PATH, stream.url)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_TITLE, file.fileName)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_FORMAT, file.format)
                putExtra(com.papria.reader.ReaderActivity.EXTRA_REMOTE_AUDIO, true)
                file.durationSeconds?.takeIf { it > 0.0 }?.let {
                    putExtra(com.papria.reader.ReaderActivity.EXTRA_DURATION_MS, (it * 1000.0).toLong())
                }
                putExtra(com.papria.reader.ReaderActivity.EXTRA_HEADERS, HashMap(stream.headers))
                putStringArrayListExtra(com.papria.reader.ReaderActivity.EXTRA_PATHS, ArrayList(streams.map { it.url }))
                putExtra(com.papria.reader.ReaderActivity.EXTRA_TRACK_IDS, streams.mapIndexed { index, _ -> audioFiles[index].id }.toLongArray())
                putStringArrayListExtra(com.papria.reader.ReaderActivity.EXTRA_TRACK_TITLES, ArrayList(audioFiles.map { it.fileName }))
                putExtra(com.papria.reader.ReaderActivity.EXTRA_TRACK_INDEX, currentIndex)
            })
        }.onFailure { connectionMessage = "在线播放失败：${it.message ?: "未知错误"}" }
    }

    fun loadBook(bookId: Long) {
        if (bookOrbitOffline) {
            val cachedBook = remoteBooks.firstOrNull { it.id == bookId }
            if (cachedBook == null) {
                connectionMessage = "离线：未缓存该书的文件详情"
            } else {
                selectedRemoteBook = cachedBook
                connectionMessage = if (cachedBook.files.isEmpty()) "离线：未缓存文件详情" else "离线：显示已缓存文件详情"
            }
            return
        }
        val repository = bookOrbitRepository ?: run {
            connectionMessage = "无法读取文件列表：BookOrbit 未连接"
            return
        }
        connectionMessage = "正在读取书籍文件…"
        bookOrbitLoading = true
        viewModelScope.launch {
            try {
                val book = withContext(Dispatchers.IO) { repository.getBook(bookId) }
                remoteBooks = remoteBooks.map { if (it.id == book.id) book else it }
                selectedRemoteBook = book
                bookOrbitLoading = false
                connectionMessage = "已读取 ${book.files.size} 个文件"
            } catch (error: Exception) {
                bookOrbitLoading = false
                connectionMessage = "读取失败：${error.message ?: "未知错误"}"
            }
        }
    }

    fun loadCover(bookId: Long) {
        if (covers.containsKey(bookId)) return
        val cached = CoverCache.cached(getApplication(), bookId)
        if (cached != null) {
            covers = covers + (bookId to cached)
            return
        }
        val repository = bookOrbitRepository ?: return
        viewModelScope.launch(Dispatchers.IO) {
            val value = runCatching { repository.cacheCover(bookId) }.getOrNull() ?: return@launch
            withContext(Dispatchers.Main) { covers = covers + (bookId to value) }
        }
    }

    fun cover(bookId: Long): CoverCache.CoverPaths? = covers[bookId]

    fun readingProgressFor(publication: LocalPublication): ReadingProgressRecord? =
        readingPositions[publication.progressFileId]

    fun importFile(uri: Uri) {
        connectionMessage = "正在导入文件…"
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val resolver = getApplication<Application>().contentResolver
                    val metadata = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val name = cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                            val size = sizeColumn.takeIf { it >= 0 && !cursor.isNull(it) }?.let(cursor::getLong)
                            name to size
                        } else null
                    }
                    val name = metadata?.first
                        ?: uri.lastPathSegment ?: "imported-book"
                    metadata?.second?.let(ContentAddressedStore(getApplication())::ensureCapacity)
                    FormatPolicy.validateName(name)
                    val staging = java.io.File.createTempFile("local-import-", ".part", getApplication<Application>().cacheDir)
                    val stored = try {
                        var copiedBytes = 0L
                        resolver.openInputStream(uri)?.use { input ->
                            staging.outputStream().use { output ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    if (count == 0) continue
                                    copiedBytes += count
                                    require(copiedBytes <= MAX_LOCAL_IMPORT_BYTES) { "本地文件超过大小限制" }
                                    output.write(buffer, 0, count)
                                }
                            }
                        }
                            ?: error("无法打开文件")
                        metadata?.second?.let { require(copiedBytes == it) { "文件大小与提供方元数据不一致" } }
                        ContentAddressedStore(getApplication()).ensureCapacity(copiedBytes)
                        FormatPolicy.validateFile(staging, name)
                        FormatPolicy.validateContainer(staging, name)
                        ContentAddressedStore(getApplication()).import(staging)
                    } finally {
                        staging.delete()
                    }
                    val format = name.substringAfterLast('.', "").lowercase()
                    database.upsertPublication(LocalPublication("local-${stored.sha256}", name.substringBeforeLast('.').ifBlank { name }, null, format, stored.file.absolutePath, stored.sha256, null, null, "local", true, System.currentTimeMillis()))
                }
                connectionMessage = "文件已导入本地书库"
            } catch (error: Exception) { connectionMessage = "导入失败：${error.message ?: "未知错误"}" }
        }
    }

    /** Delete only the local reference/content; BookOrbit files are never deleted remotely. */
    fun deletePublication(publication: LocalPublication) {
        viewModelScope.launch(Dispatchers.IO) {
            deletePublicationFromStore(publication)
        }
    }

    private fun deletePublicationFromStore(publication: LocalPublication) {
        val store = ContentAddressedStore(getApplication())
        database.deletePublication(publication.localId)
        publication.remoteFileId?.let(database::deleteDownloadTask)
        if (!database.hasPublicationWithHash(publication.contentHash.orEmpty(), excludingLocalId = publication.localId)) {
            publication.contentHash?.let { runCatching { store.remove(it) } }
        }
    }
}

private data class DownloadProgressSample(val bytes: Long, val atElapsedMillis: Long)

data class StorageSummary(val usedBytes: Long, val freeBytes: Long)

private data class PublicationSnapshot(
    val readingPositions: Map<Long, ReadingProgressRecord>,
    val storageSummary: StorageSummary,
)

enum class AppTab { LIBRARY, BOOKORBIT, TRANSFER, SETTINGS }

enum class BookOrbitDestination { CATALOG, DETAIL, TASKS }

private const val MAX_LOCAL_IMPORT_BYTES = 16L * 1024L * 1024L * 1024L
private const val LAST_SUCCESSFUL_SYNC_AT_KEY = "last-successful-sync-at"
