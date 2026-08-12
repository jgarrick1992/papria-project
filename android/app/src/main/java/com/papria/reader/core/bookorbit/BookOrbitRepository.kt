package com.papria.reader.core.bookorbit

import android.content.Context
import com.papria.reader.core.local.AudioProgressRecord
import com.papria.reader.core.local.DownloadTaskRecord
import com.papria.reader.core.local.LocalPublication
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.local.ProgressSyncBaselineRecord
import com.papria.reader.core.local.ReadingProgressRecord
import com.papria.reader.core.local.RemoteBookRecord
import com.papria.reader.core.local.RemoteFileRecord
import com.papria.reader.core.local.SyncConflictRecord
import com.papria.reader.core.local.ServerProfileRecord
import com.papria.reader.core.model.AudioProgress
import com.papria.reader.core.model.FileProgress
import com.papria.reader.core.storage.ContentAddressedStore
import com.papria.reader.core.security.SecureSessionStore
import com.papria.reader.core.display.CoverCache
import org.json.JSONObject
import java.io.IOException

/** BookOrbit v2.5.0 boundary and local synchronization coordinator. */
class BookOrbitRepository(
    private val context: Context,
    private val client: BookOrbitClient,
    private val database: PapriaDatabase = PapriaDatabase.get(context),
    private val store: ContentAddressedStore = ContentAddressedStore(context),
) {
    private val secureSession = SecureSessionStore(context)
    fun login(username: String, password: String): ServerLogin {
        val response = client.executeOrThrow(client.loginRequest(username, password))
        val token = JSONObject(response.body).requiredAccessToken()
        client.setSession(token, response.setCookie ?: client.sessionRefreshCookie())
        val version = requireV250(client.executeOrThrow(client.appInfoRequest()).body)
        // Complete the strict login handshake before persisting a usable
        // profile. A server that accepts credentials but rejects /auth/me is
        // not a valid session for the remote-library features.
        client.executeOrThrow(client.meRequest())
        val confirmation = client.cleartextHttpConfirmation()
        database.saveServerProfile(ServerProfileRecord(
            baseUrl = client.serverUrl(),
            username = username,
            accessToken = secureSession.encrypt(token),
            refreshCookie = secureSession.encrypt(client.sessionRefreshCookie()),
            serverVersion = version,
            certificateSha256 = client.certificateSha256(),
            cleartextHttpConfirmedHost = confirmation?.host,
            cleartextHttpConfirmedPort = confirmation?.port,
            cleartextHttpConfirmedAt = confirmation?.let { System.currentTimeMillis() },
        ))
        return ServerLogin(username, version)
    }

    fun refresh(): String {
        val response = client.executeOrThrow(client.refreshRequest())
        val token = JSONObject(response.body).requiredAccessToken()
        client.setSession(token, response.setCookie ?: client.sessionRefreshCookie())
        val profile = database.serverProfile()
        if (profile != null) database.saveServerProfile(profile.copy(
            accessToken = secureSession.encrypt(token),
            refreshCookie = secureSession.encrypt(client.sessionRefreshCookie()),
        ))
        return token
    }

    /** Re-check the server gate after process restart or before a background job. */
    fun verifyServerVersion(): String {
        val version = requireV250(client.executeOrThrow(client.appInfoRequest()).body)
        database.serverProfile()?.let { profile ->
            if (profile.serverVersion != version) {
                database.saveServerProfile(profile.copy(serverVersion = version))
            }
        }
        return version
    }

    fun queryBooks(page: Int, size: Int, query: String? = null): BookPage {
        require(page >= 0 && size in 1..100) { "invalid page" }
        val response = client.executeOrThrow(client.queryBooksRequest(page, size, query))
        requireV250(database.serverProfile()?.serverVersion ?: SUPPORTED_VERSION)
        val json = JSONObject(response.body)
        val books = json.getJSONArray("items")
        val parsed = (0 until books.length()).map { books.getJSONObject(it).toQueryBook() }
        parsed.forEach { book ->
            database.upsertRemoteBook(RemoteBookRecord(book.id, book.title, book.author, book.coverUrl, System.currentTimeMillis()))
            // BookCard.files intentionally contains only file references. The exact
            // filename/size metadata is fetched from GET /books/:id before download.
        }
        return BookPage(json.getInt("page"), json.getInt("size"), json.getInt("total"), parsed)
    }

    /** Fetch every page for the local cache while preserving the exact query contract. */
    fun queryAllBooks(size: Int = 100, query: String? = null): List<RemoteBookPayload> {
        var page = 0
        val result = mutableListOf<RemoteBookPayload>()
        var total = Int.MAX_VALUE
        while (result.size < total && page < 10_000) {
            val response = queryBooks(page, size, query)
            total = response.total
            result += response.books
            if (response.books.isEmpty()) break
            page++
        }
        return result.distinctBy { it.id }
    }

    fun getBook(bookId: Long): RemoteBookPayload {
        val response = client.executeOrThrow(client.bookRequest(bookId))
        val book = JSONObject(response.body).toDetailBook()
        database.upsertRemoteBook(RemoteBookRecord(book.id, book.title, book.author, book.coverUrl, System.currentTimeMillis()))
        book.files.filter { it.sizeBytes > 0L && it.format != "unknown" }.forEach { file ->
            database.upsertRemoteFile(RemoteFileRecord(file.id, book.id, file.fileName, file.format, file.sizeBytes, file.contentHash, file.localPath))
        }
        return book
    }

    /** Download and cache the authenticated cover, including e-ink variants. */
    fun cacheCover(bookId: Long): CoverCache.CoverPaths? {
        var response = client.executeBytes(client.coverRequest(bookId))
        if (response.statusCode == 401) {
            refresh()
            response = client.executeBytes(client.coverRequest(bookId))
        }
        if (!response.isSuccessful) return null
        return CoverCache.save(context, bookId, response.body)
    }

    /** Authenticated URL/headers for Media3's streaming data source. */
    fun audioStream(fileId: Long): RemoteAudioStream {
        val request = client.serveFileRequest(fileId)
        return RemoteAudioStream(request.url.toString(), client.sessionHeaders())
    }

    fun localProgress(fileId: Long): ReadingProgressRecord? = database.readingProgress(fileId)

    /** Pull remote state before a push and persist the exact remote baseline. */
    fun pullFileProgress(fileId: Long): FileProgress {
        val remote = fetchFileProgress(fileId)
        val local = database.readingProgress(fileId)
        val remoteChangedSinceLastPull = ProgressSyncConflictPolicy.shouldCreateFileConflict(
            isLocalDirty = local?.dirty == true,
            lastPulled = database.progressBaseline(FILE_PROGRESS_KIND, fileId.toString())
                ?.remotePayload
                ?.let(::parseFileProgress),
            remote = remote,
        )
        saveProgressBaseline(FILE_PROGRESS_KIND, fileId, progressJson(remote).toString())
        if (remoteChangedSinceLastPull) {
            database.saveConflict(SyncConflictRecord(FILE_PROGRESS_KIND, fileId.toString(), progressJson(requireNotNull(local).toFileProgress()).toString(), progressJson(remote).toString(), System.currentTimeMillis()))
        }
        if (local != null && local.dirty) {
            return local.toFileProgress()
        }
        if (local == null || !local.dirty) {
            database.upsertReadingProgress(ReadingProgressRecord(fileId, remote.percentage, remote.cfi, remote.pageNumber, remote.positionSeconds, System.currentTimeMillis(), System.currentTimeMillis(), false, false, remote.koboLocationSource, remote.koboLocationType, remote.koboLocationValue, remote.koboContentSourceProgressPercent, remote.koreaderProgress))
        }
        return remote
    }

    fun pullAudioProgress(bookId: Long): AudioProgress? {
        val remote = fetchAudioProgress(bookId)
        val local = database.audioProgress(bookId)
        val baseline = database.progressBaseline(AUDIO_PROGRESS_KIND, bookId.toString())
        val remoteChangedSinceLastPull = ProgressSyncConflictPolicy.shouldCreateAudioConflict(
            isLocalDirty = local?.dirty == true,
            hasLastPull = baseline != null,
            lastPulled = baseline?.remotePayload?.let(::parseAudioProgress),
            remote = remote,
        )
        saveProgressBaseline(AUDIO_PROGRESS_KIND, bookId, remote?.let { audioProgressJson(it).toString() })
        if (remoteChangedSinceLastPull) {
            database.saveConflict(SyncConflictRecord(AUDIO_PROGRESS_KIND, bookId.toString(), audioProgressJson(requireNotNull(local).toAudioProgress()).toString(), remote?.let { audioProgressJson(it).toString() } ?: "null", System.currentTimeMillis()))
        }
        if (local != null && local.dirty) {
            return local.toAudioProgress()
        }
        if (remote == null) return null
        if (local == null || !local.dirty) database.upsertAudioProgress(AudioProgressRecord(
            bookId,
            remote.percentage,
            remote.currentFileId,
            remote.positionSeconds,
            System.currentTimeMillis(),
            false,
            local?.playbackSpeed ?: 1.0f,
            local?.sleepUntil,
        ))
        return remote
    }

    /** Persist immediately and enqueue exactly one upload payload for eventual sync. */
    fun saveLocalProgress(fileId: Long, progress: FileProgress, source: String = "bookorbit") {
        val localOnly = source == "wifi"
        val now = System.currentTimeMillis()
        database.upsertReadingProgress(ReadingProgressRecord(fileId, progress.percentage, progress.cfi, progress.pageNumber, progress.positionSeconds, now, null, !localOnly, localOnly, progress.koboLocationSource, progress.koboLocationType, progress.koboLocationValue, progress.koboContentSourceProgressPercent, progress.koreaderProgress))
        if (!localOnly) database.enqueueOutbox("file-progress", fileId.toString(), progressJson(progress).toString(), now)
    }

    fun saveLocalAudioProgress(
        bookId: Long,
        progress: AudioProgress,
        source: String = "bookorbit",
        playbackSpeed: Float? = null,
        sleepUntil: Long? = null,
    ) {
        val localOnly = source == "wifi"
        val now = System.currentTimeMillis()
        val previous = database.audioProgress(bookId)
        database.upsertAudioProgress(AudioProgressRecord(
            bookId,
            progress.percentage,
            progress.currentFileId,
            progress.positionSeconds,
            now,
            !localOnly,
            playbackSpeed ?: previous?.playbackSpeed ?: 1.0f,
            sleepUntil ?: previous?.sleepUntil,
        ))
        if (!localOnly) database.enqueueOutbox("audio-progress", bookId.toString(), audioProgressJson(progress).toString(), now)
    }

    fun uploadOutbox(maxItems: Int = 20): SyncSummary {
        var sent = 0
        var failed = 0
        database.dueOutbox(limit = maxItems).forEach { item ->
            try {
                // A negative attempt count is a local-only marker set after
                // the user explicitly chose "keep local". It skips the
                // second preflight pull exactly once, then is removed with
                // the successful outbox row; the wire payload is unchanged.
                val forceUpload = item.attempts < 0
                if (!forceUpload && database.conflict(item.kind, item.key) != null) {
                    failed++
                    return@forEach
                }
                // The server has no conditional update primitive. Pull first so a caller
                // can inspect a dirty/local-vs-remote conflict before this upload.
                if (!forceUpload) when (item.kind) {
                    "file-progress" -> pullFileProgress(item.key.toLong())
                    "audio-progress" -> pullAudioProgress(item.key.toLong())
                }
                // The pull above may discover a conflict for the first time.
                // Never continue with POST/PATCH in that case: doing so would
                // overwrite the server value before the user chooses a side.
                if (!forceUpload && database.conflict(item.kind, item.key) != null) {
                    failed++
                    return@forEach
                }
                val response = when (item.kind) {
                    "file-progress" -> executeWithRefresh { client.saveProgressRequest(item.key.toLong(), parseFileProgress(item.payload)) }
                    "audio-progress" -> executeWithRefresh { client.saveAudioProgressRequest(item.key.toLong(), parseAudioProgress(item.payload)) }
                    else -> throw IllegalArgumentException("unknown sync kind: ${item.kind}")
                }
                if (response.isSuccessful) {
                    // Verify the server's persisted representation before clearing the
                    // local outbox. A proxy/server that silently drops a field is
                    // surfaced as a conflict instead of being reported as synced.
                    when (item.kind) {
                        "file-progress" -> verifyUploadedFileProgress(item.key.toLong(), parseFileProgress(item.payload))
                        "audio-progress" -> verifyUploadedAudioProgress(item.key.toLong(), parseAudioProgress(item.payload))
                    }
                    database.deleteOutbox(item.id)
                    when (item.kind) {
                        "file-progress" -> markFileProgressSynced(item.key.toLong(), parseFileProgress(item.payload))
                        "audio-progress" -> markAudioProgressSynced(item.key.toLong(), parseAudioProgress(item.payload))
                    }
                    sent++
                }
            } catch (_: Exception) {
                failed++
                val attempts = if (item.attempts < 0) -1 else item.attempts + 1
                val delay = (1L shl (if (attempts < 0) 0 else attempts.coerceAtMost(6))) * 1_000L
                database.retryOutbox(item.id, attempts, System.currentTimeMillis() + delay)
            }
        }
        return SyncSummary(sent, failed)
    }

    fun conflicts(): List<SyncConflictRecord> = database.conflicts()

    /** Resolve a displayed local/server conflict without inventing field aliases. */
    fun resolveConflict(conflict: SyncConflictRecord, keepLocal: Boolean) {
        if (!keepLocal) {
            when (conflict.kind) {
                "file-progress" -> database.upsertReadingProgress(parseFileProgress(conflict.remotePayload).let { value ->
                    ReadingProgressRecord(conflict.key.toLong(), value.percentage, value.cfi, value.pageNumber, value.positionSeconds, System.currentTimeMillis(), System.currentTimeMillis(), false, false, value.koboLocationSource, value.koboLocationType, value.koboLocationValue, value.koboContentSourceProgressPercent, value.koreaderProgress)
                })
                "audio-progress" -> if (conflict.remotePayload == "null") {
                    database.deleteAudioProgress(conflict.key.toLong())
                } else database.upsertAudioProgress(parseAudioProgress(conflict.remotePayload).let { value ->
                    val previous = database.audioProgress(conflict.key.toLong())
                    AudioProgressRecord(conflict.key.toLong(), value.percentage, value.currentFileId, value.positionSeconds, System.currentTimeMillis(), false, previous?.playbackSpeed ?: 1.0f, previous?.sleepUntil)
                })
            }
            saveProgressBaseline(conflict.kind, conflict.key.toLong(), conflict.remotePayload.takeUnless { it == "null" })
            database.dueOutbox(limit = 100).filter { it.kind == conflict.kind && it.key == conflict.key }.forEach { database.deleteOutbox(it.id) }
        } else {
            // Keep the exact local snapshot and mark its existing outbox row
            // for one forced upload. The next successful POST/PATCH is still
            // verified with a GET, so this does not weaken server validation.
            database.dueOutbox(now = Long.MAX_VALUE, limit = 1000).firstOrNull { it.kind == conflict.kind && it.key == conflict.key }?.let {
                database.retryOutbox(it.id, attempts = -1, nextAttemptAt = System.currentTimeMillis())
            }
        }
        database.deleteConflict(conflict.kind, conflict.key)
    }

    /**
     * Restore the exact local snapshot from a resolution that is still visible
     * to the user.  This is deliberately local-only: the next sync will once
     * again surface the preserved conflict rather than silently overwriting a
     * BookOrbit value.
     */
    fun restoreConflictResolution(conflict: SyncConflictRecord) {
        when (conflict.kind) {
            "file-progress" -> {
                val value = parseFileProgress(conflict.localPayload)
                database.upsertReadingProgress(
                    ReadingProgressRecord(
                        fileId = conflict.key.toLong(),
                        percentage = value.percentage,
                        cfi = value.cfi,
                        pageNumber = value.pageNumber,
                        positionSeconds = value.positionSeconds,
                        localUpdatedAt = System.currentTimeMillis(),
                        remoteUpdatedAt = null,
                        dirty = true,
                        localOnly = false,
                        koboLocationSource = value.koboLocationSource,
                        koboLocationType = value.koboLocationType,
                        koboLocationValue = value.koboLocationValue,
                        koboContentSourceProgressPercent = value.koboContentSourceProgressPercent,
                        koreaderProgress = value.koreaderProgress,
                    ),
                )
            }
            "audio-progress" -> {
                if (conflict.localPayload == "null") {
                    database.deleteAudioProgress(conflict.key.toLong())
                } else {
                    val value = parseAudioProgress(conflict.localPayload)
                    val previous = database.audioProgress(conflict.key.toLong())
                    database.upsertAudioProgress(
                        AudioProgressRecord(
                            bookId = conflict.key.toLong(),
                            percentage = value.percentage,
                            currentFileId = value.currentFileId,
                            positionSeconds = value.positionSeconds,
                            updatedAt = System.currentTimeMillis(),
                            dirty = true,
                            playbackSpeed = previous?.playbackSpeed ?: 1.0f,
                            sleepUntil = previous?.sleepUntil,
                        ),
                    )
                }
            }
        }
        database.saveConflict(conflict)
    }

    private fun fetchFileProgress(fileId: Long): FileProgress {
        val json = JSONObject(executeWithRefresh { client.getProgressRequest(fileId) }.body)
        return FileProgress(
            percentage = json.getDouble("percentage"),
            cfi = json.nullableString("cfi"),
            pageNumber = json.nullableInt("pageNumber"),
            positionSeconds = json.nullableDouble("positionSeconds"),
            koboLocationSource = json.nullableString("koboLocationSource"),
            koboLocationType = json.nullableString("koboLocationType"),
            koboLocationValue = json.nullableString("koboLocationValue"),
            koboContentSourceProgressPercent = json.nullableDouble("koboContentSourceProgressPercent"),
            koreaderProgress = json.nullableString("koreaderProgress"),
        )
    }

    private fun fetchAudioProgress(bookId: Long): AudioProgress? {
        val body = executeWithRefresh { client.getAudioProgressRequest(bookId) }.body.trim()
        if (body.isEmpty() || body == "null") return null
        return parseAudioProgress(body)
    }

    private fun saveProgressBaseline(kind: String, itemId: Long, remotePayload: String?) {
        database.saveProgressBaseline(
            ProgressSyncBaselineRecord(kind, itemId.toString(), remotePayload, System.currentTimeMillis()),
        )
    }

    /**
     * The POST/PATCH immediately before this GET is our own write, so this
     * verification must refresh the baseline without treating that write as a
     * competing remote update. A mismatching value is still surfaced as a
     * conflict and leaves the outbox item pending.
     */
    private fun verifyUploadedFileProgress(fileId: Long, uploaded: FileProgress) {
        val remote = fetchFileProgress(fileId)
        saveProgressBaseline(FILE_PROGRESS_KIND, fileId, progressJson(remote).toString())
        if (!ProgressSyncConflictPolicy.sameFileProgress(uploaded, remote)) {
            val local = database.readingProgress(fileId)?.toFileProgress() ?: uploaded
            database.saveConflict(
                SyncConflictRecord(FILE_PROGRESS_KIND, fileId.toString(), progressJson(local).toString(), progressJson(remote).toString(), System.currentTimeMillis()),
            )
            throw IOException("remote file progress verification failed")
        }
    }

    private fun verifyUploadedAudioProgress(bookId: Long, uploaded: AudioProgress) {
        val remote = fetchAudioProgress(bookId)
        saveProgressBaseline(AUDIO_PROGRESS_KIND, bookId, remote?.let { audioProgressJson(it).toString() })
        if (remote == null || !ProgressSyncConflictPolicy.sameAudioProgress(uploaded, remote)) {
            val local = database.audioProgress(bookId)?.toAudioProgress() ?: uploaded
            database.saveConflict(
                SyncConflictRecord(AUDIO_PROGRESS_KIND, bookId.toString(), audioProgressJson(local).toString(), remote?.let { audioProgressJson(it).toString() } ?: "null", System.currentTimeMillis()),
            )
            throw IOException("remote audio progress verification failed")
        }
    }

    private fun markFileProgressSynced(fileId: Long, uploaded: FileProgress) {
        database.readingProgress(fileId)?.takeIf {
            ProgressSyncConflictPolicy.sameFileProgress(it.toFileProgress(), uploaded)
        }?.let { current ->
            database.upsertReadingProgress(current.copy(dirty = false, remoteUpdatedAt = System.currentTimeMillis()))
        }
    }

    private fun markAudioProgressSynced(bookId: Long, uploaded: AudioProgress) {
        database.audioProgress(bookId)?.takeIf {
            ProgressSyncConflictPolicy.sameAudioProgress(it.toAudioProgress(), uploaded)
        }?.let { current ->
            database.upsertAudioProgress(current.copy(dirty = false, updatedAt = System.currentTimeMillis()))
        }
    }

    private fun executeWithRefresh(request: () -> okhttp3.Request): ApiResponse {
        val first = client.execute(request())
        if (first.statusCode != 401) {
            if (!first.isSuccessful) throw BookOrbitHttpException(first.statusCode, first.body)
            return first
        }
        refresh()
        return client.executeOrThrow(request())
    }

    fun downloadFile(fileId: Long): DownloadResult {
        val remote = database.remoteFile(fileId)?.let { cached ->
            RemoteFilePayload(cached.id, cached.fileName, cached.format, cached.sizeBytes, cached.contentHash, cached.localPath)
        } ?: getBookFile(fileId)
        var task = database.downloadTask(fileId) ?: DownloadTaskRecord(fileId, 0, remote.sizeBytes, "queued", null, System.currentTimeMillis())
        // The database checkpoint can lag a successful write if the process is
        // killed between fsync and the Room update. Treat the part file as the
        // source of truth, otherwise an append could duplicate bytes after a
        // restart and fail the final length/hash check.
        val partLength = store.partLength(fileId)
        if (partLength > remote.sizeBytes) {
            store.partFile(fileId).delete()
            task = task.copy(offsetBytes = 0, state = "queued", error = null, updatedAt = System.currentTimeMillis())
        } else if (partLength != task.offsetBytes) {
            task = task.copy(offsetBytes = partLength, totalBytes = remote.sizeBytes, updatedAt = System.currentTimeMillis())
            database.upsertDownload(task)
        }
        if (store.freeBytes() < (remote.sizeBytes - task.offsetBytes).coerceAtLeast(0) + MIN_FREE_BYTES) {
            database.upsertDownload(task.copy(state = "failed", error = "insufficient storage", updatedAt = System.currentTimeMillis()))
            throw IOException("insufficient storage")
        }
        val initialOffset = task.offsetBytes.coerceIn(0, remote.sizeBytes)
        var requestOffset = initialOffset.takeIf { it > 0 }
        var response = openWithRefresh { client.serveFileRequest(fileId, requestOffset) }
        if (response.code == 200 && requestOffset != null) {
            // Server ignored Range. Restart into a clean part as required by the contract.
            store.partFile(fileId).delete()
            task = task.copy(offsetBytes = 0, state = "running", error = null, updatedAt = System.currentTimeMillis())
            database.upsertDownload(task)
            requestOffset = null
            response.close()
            response = openWithRefresh { client.serveFileRequest(fileId, null) }
        }
        if (response.code !in setOf(200, 206)) {
            val body = response.body?.string().orEmpty()
            response.close()
            throw BookOrbitHttpException(response.code, body)
        }
        val append = requestOffset != null && response.code == 206
        if (response.code == 206) validatePartialResponse(response, requestOffset ?: 0L, remote.sizeBytes)
        require(requestOffset == null || response.code == 206) { "BookOrbit returned an invalid range response" }
        if (!append && initialOffset > 0 && requestOffset == null) task = task.copy(offsetBytes = 0)
        var written = if (append) task.offsetBytes else 0L
        database.upsertDownload(task.copy(offsetBytes = written, totalBytes = remote.sizeBytes, state = "running", error = null, updatedAt = System.currentTimeMillis()))
        try {
            val body = response.body ?: throw IOException("BookOrbit returned an empty body")
            body.byteStream().use { input ->
                store.openPart(fileId, append).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var lastPersist = written
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        output.write(buffer, 0, count)
                        written += count
                        if (written - lastPersist >= 256 * 1024L) {
                            database.upsertDownload(task.copy(offsetBytes = written, totalBytes = remote.sizeBytes, state = "running", updatedAt = System.currentTimeMillis()))
                            lastPersist = written
                        }
                    }
                }
            }
        } catch (error: Exception) {
            database.upsertDownload(task.copy(offsetBytes = written, totalBytes = remote.sizeBytes, state = "paused", error = error.message, updatedAt = System.currentTimeMillis()))
            throw error
        } finally {
            response.close()
        }
        require(written == remote.sizeBytes) { "download length mismatch: expected=${remote.sizeBytes}, actual=$written" }
        val stored = try {
            store.finalizePart(fileId, remote.contentHash)
        } catch (error: Exception) {
            database.upsertDownload(task.copy(offsetBytes = written, totalBytes = remote.sizeBytes, state = "failed", error = error.message, updatedAt = System.currentTimeMillis()))
            throw error
        }
        val now = System.currentTimeMillis()
        database.upsertDownload(task.copy(offsetBytes = written, totalBytes = remote.sizeBytes, state = "completed", error = null, updatedAt = now))
        // The first download may not have a publication row yet. The detail
        // request stores the file's parent book in remote_files, so retain it
        // for progress/audio synchronization from the first successful import.
        val bookId = database.remoteFile(fileId)?.bookId
            ?: database.localPublications().firstOrNull { it.remoteFileId == fileId }?.remoteBookId
        database.upsertPublication(LocalPublication(
            localId = "remote-file-$fileId", title = remote.fileName, author = null, format = remote.format,
            localPath = stored.file.absolutePath, contentHash = stored.sha256, remoteBookId = bookId, remoteFileId = fileId,
            source = "bookorbit", downloaded = true, updatedAt = now,
        ))
        return DownloadResult(fileId, stored.sha256, stored.file.absolutePath, stored.sizeBytes)
    }

    private fun getBookFile(fileId: Long): RemoteFilePayload {
        val book = database.localPublications().firstOrNull { it.remoteFileId == fileId }?.remoteBookId?.let(::getBook)
            ?: throw IllegalArgumentException("remote file $fileId is not cached; fetch its book first")
        return book.files.firstOrNull { it.id == fileId } ?: throw IllegalArgumentException("remote file not found: $fileId")
    }

    private fun openWithRefresh(request: () -> okhttp3.Request): okhttp3.Response {
        var response = client.open(request())
        if (response.code == 401) {
            response.close()
            refresh()
            response = client.open(request())
        }
        return response
    }

    private fun validatePartialResponse(response: okhttp3.Response, expectedStart: Long, expectedTotal: Long) {
        val value = response.header("Content-Range") ?: throw IOException("missing Content-Range")
        val match = Regex("^bytes (\\d+)-(\\d+)/(\\d+)$").matchEntire(value)
            ?: throw IOException("invalid Content-Range")
        val start = match.groupValues[1].toLong()
        val end = match.groupValues[2].toLong()
        val total = match.groupValues[3].toLong()
        require(start == expectedStart && total == expectedTotal && end >= start) { "unexpected Content-Range: $value" }
        response.header("Content-Length")?.toLongOrNull()?.let { length ->
            require(length == end - start + 1) { "Content-Length does not match Content-Range" }
        }
    }

    private fun requireV250(body: String): String {
        val version = JSONObject(body).getString("version")
        require(version == SUPPORTED_VERSION) { "unsupported BookOrbit version: $version" }
        return version
    }

    private fun JSONObject.toQueryBook(): RemoteBookPayload {
        val authors = getJSONArray("authors")
        // Query cards intentionally do not retain their file references: the
        // detail endpoint is the only source of download metadata. Still
        // require the published reference shape instead of inventing an empty
        // list for a malformed response.
        val fileReferences = getJSONArray("files")
        (0 until fileReferences.length()).forEach { index ->
            fileReferences.getJSONObject(index).validateQueryFileReference()
        }
        return RemoteBookPayload(
            id = getLong("id"),
            title = requiredNonBlankString("title"),
            author = (0 until authors.length()).map { authors.getString(it) }.firstOrNull { it.isNotBlank() },
            coverUrl = null,
            files = emptyList(),
        )
    }

    private fun JSONObject.toDetailBook(): RemoteBookPayload {
        // BookOrbit v2.5.0 defines detail authors as records with the exact
        // `name` field. Query and detail shapes are intentionally not aliased.
        val filesJson = getJSONArray("files")
        val authors = getJSONArray("authors")
        return RemoteBookPayload(
            id = getLong("id"),
            title = requiredNonBlankString("title"),
            author = (0 until authors.length()).map { authors.getJSONObject(it).requiredNonBlankString("name") }.firstOrNull(),
            coverUrl = null,
            files = (0 until filesJson.length()).map { filesJson.getJSONObject(it).toRemoteFile() },
        )
    }

    private fun JSONObject.toRemoteFile(): RemoteFilePayload {
        val sizeBytes = getLong("sizeBytes")
        require(sizeBytes >= 0L) { "BookOrbit file sizeBytes must not be negative" }
        val durationSeconds = nullableDouble("durationSeconds")
        require(durationSeconds == null || (durationSeconds.isFinite() && durationSeconds >= 0.0)) {
            "BookOrbit file durationSeconds must be finite and non-negative"
        }
        return RemoteFilePayload(
            id = getLong("id"),
            fileName = requiredNonBlankString("filename"),
            format = requiredNonBlankString("format"),
            sizeBytes = sizeBytes,
            contentHash = null,
            localPath = null,
            role = nullableString("role"),
            durationSeconds = durationSeconds,
        )
    }

    private fun JSONObject.validateQueryFileReference() {
        getLong("id")
        requiredNonBlankString("format")
        val sizeBytes = getLong("sizeBytes")
        require(sizeBytes >= 0L) { "BookOrbit file sizeBytes must not be negative" }
    }

    private fun JSONObject.requiredNonBlankString(key: String): String = getString(key).also { value ->
        require(value.isNotBlank()) { "BookOrbit $key must not be blank" }
    }

    private fun JSONObject.requiredAccessToken(): String = requiredNonBlankString("accessToken").also { token ->
        require(token.all { it.code in 0x21..0x7e }) {
            "BookOrbit accessToken contains a character unsafe for an HTTP header"
        }
    }

    private fun progressJson(progress: FileProgress) = JSONObject().apply {
        put("percentage", progress.percentage)
        progress.cfi?.let { put("cfi", it) }
        progress.pageNumber?.let { put("pageNumber", it) }
        progress.positionSeconds?.let { put("positionSeconds", it) }
        progress.koboLocationSource?.let { put("koboLocationSource", it) }
        progress.koboLocationType?.let { put("koboLocationType", it) }
        progress.koboLocationValue?.let { put("koboLocationValue", it) }
        progress.koboContentSourceProgressPercent?.let { put("koboContentSourceProgressPercent", it) }
        progress.koreaderProgress?.let { put("koreaderProgress", it) }
    }

    private fun audioProgressJson(progress: AudioProgress) = JSONObject().apply {
        put("percentage", progress.percentage); put("currentFileId", progress.currentFileId); put("positionSeconds", progress.positionSeconds)
    }

    private fun parseFileProgress(value: String) = JSONObject(value).let {
        FileProgress(
            percentage = it.getDouble("percentage"),
            cfi = it.nullableString("cfi"),
            pageNumber = it.nullableInt("pageNumber"),
            positionSeconds = it.nullableDouble("positionSeconds"),
            koboLocationSource = it.nullableString("koboLocationSource"),
            koboLocationType = it.nullableString("koboLocationType"),
            koboLocationValue = it.nullableString("koboLocationValue"),
            koboContentSourceProgressPercent = it.nullableDouble("koboContentSourceProgressPercent"),
            koreaderProgress = it.nullableString("koreaderProgress"),
        )
    }
    private fun parseAudioProgress(value: String) = JSONObject(value).let { AudioProgress(it.getDouble("percentage"), it.getLong("currentFileId"), it.getDouble("positionSeconds")) }

    private fun JSONObject.nullableString(key: String): String? = if (isNull(key)) null else getString(key)
    private fun JSONObject.nullableInt(key: String): Int? = if (isNull(key)) null else getInt(key)
    private fun JSONObject.nullableDouble(key: String): Double? = if (isNull(key)) null else getDouble(key)

    companion object {
        const val SUPPORTED_VERSION = "v2.5.0"
        private const val FILE_PROGRESS_KIND = "file-progress"
        private const val AUDIO_PROGRESS_KIND = "audio-progress"
        private const val MIN_FREE_BYTES = 8L * 1024L * 1024L
    }
}

private fun ReadingProgressRecord.toFileProgress() = FileProgress(
    percentage = percentage,
    cfi = cfi,
    pageNumber = pageNumber,
    positionSeconds = positionSeconds,
    koboLocationSource = koboLocationSource,
    koboLocationType = koboLocationType,
    koboLocationValue = koboLocationValue,
    koboContentSourceProgressPercent = koboContentSourceProgressPercent,
    koreaderProgress = koreaderProgress,
)

private fun AudioProgressRecord.toAudioProgress() = AudioProgress(percentage, currentFileId, positionSeconds)

/** Pure conflict rule kept separate so both progress types have the same gate. */
internal object ProgressSyncConflictPolicy {
    fun shouldCreateFileConflict(
        isLocalDirty: Boolean,
        lastPulled: FileProgress?,
        remote: FileProgress,
    ): Boolean = isLocalDirty && lastPulled != null && !sameFileProgress(lastPulled, remote)

    fun shouldCreateAudioConflict(
        isLocalDirty: Boolean,
        hasLastPull: Boolean,
        lastPulled: AudioProgress?,
        remote: AudioProgress?,
    ): Boolean {
        if (!isLocalDirty || !hasLastPull) return false
        if (lastPulled == null) return remote != null
        return remote == null || !sameAudioProgress(lastPulled, remote)
    }

    fun sameFileProgress(left: FileProgress, right: FileProgress): Boolean =
        kotlin.math.abs(left.percentage - right.percentage) <= 0.1 &&
            left.cfi == right.cfi &&
            left.pageNumber == right.pageNumber &&
            kotlin.math.abs((left.positionSeconds ?: 0.0) - (right.positionSeconds ?: 0.0)) <= 1.0 &&
            left.koboLocationSource == right.koboLocationSource &&
            left.koboLocationType == right.koboLocationType &&
            left.koboLocationValue == right.koboLocationValue &&
            left.koboContentSourceProgressPercent == right.koboContentSourceProgressPercent &&
            left.koreaderProgress == right.koreaderProgress

    fun sameAudioProgress(left: AudioProgress, right: AudioProgress): Boolean =
        kotlin.math.abs(left.percentage - right.percentage) <= 0.1 &&
            left.currentFileId == right.currentFileId &&
            kotlin.math.abs(left.positionSeconds - right.positionSeconds) <= 1.0
}

data class ServerLogin(val username: String, val serverVersion: String)
data class BookPage(val page: Int, val size: Int, val total: Int, val books: List<RemoteBookPayload>)
data class RemoteBookPayload(val id: Long, val title: String, val author: String?, val coverUrl: String?, val files: List<RemoteFilePayload>)
data class RemoteFilePayload(val id: Long, val fileName: String, val format: String, val sizeBytes: Long, val contentHash: String?, val localPath: String?, val role: String? = null, val durationSeconds: Double? = null)
data class SyncSummary(val uploaded: Int, val failed: Int)
data class DownloadResult(val fileId: Long, val contentHash: String, val path: String, val sizeBytes: Long)
data class RemoteAudioStream(val url: String, val headers: Map<String, String>)
