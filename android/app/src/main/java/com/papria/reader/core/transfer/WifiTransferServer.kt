package com.papria.reader.core.transfer

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.os.Build
import com.papria.reader.core.local.LocalPublication
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.local.TransferUploadRecord
import com.papria.reader.core.storage.ContentAddressedStore
import com.papria.reader.core.reader.FormatPolicy
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.StateFlow

internal data class ContentRange(val start: Long, val end: Long, val total: Long) {
    val length: Long get() = end - start + 1
}

internal data class WifiUploadProgressReconciliation(
    val receivedBytes: Long,
    val shouldUpdateDatabase: Boolean,
    val shouldTruncateFile: Boolean,
)

/**
 * Uses the bytes that are physically present on disk as the sole source of truth for resume.
 * A process can die after writing a partial chunk, so only completed 8 MiB chunks (or the exact
 * final length) are resumable. The caller truncates an incomplete trailing chunk before accepting
 * another request, which prevents a later append from turning it into a sparse-file gap.
 */
internal fun reconcileWifiUploadProgress(
    persistedReceivedBytes: Long,
    actualFileLength: Long,
    declaredSizeBytes: Long,
): WifiUploadProgressReconciliation {
    require(declaredSizeBytes > 0) { "invalid declared size" }
    require(actualFileLength >= 0) { "invalid upload file length" }
    require(actualFileLength <= declaredSizeBytes) { "upload file exceeds declared size" }
    val resumableBytes = if (actualFileLength == declaredSizeBytes) {
        actualFileLength
    } else {
        actualFileLength - actualFileLength % WifiTransferServer.CHUNK_BYTES
    }
    return WifiUploadProgressReconciliation(
        receivedBytes = resumableBytes,
        shouldUpdateDatabase = persistedReceivedBytes != resumableBytes,
        shouldTruncateFile = actualFileLength != resumableBytes,
    )
}

internal fun reconcileWifiUploadPartFile(
    temp: File,
    persistedReceivedBytes: Long,
    declaredSizeBytes: Long,
): WifiUploadProgressReconciliation {
    require(!temp.exists() || temp.isFile) { "upload path is not a file" }
    val actualLength = if (temp.isFile) temp.length() else 0L
    val reconciliation = reconcileWifiUploadProgress(
        persistedReceivedBytes = persistedReceivedBytes,
        actualFileLength = actualLength,
        declaredSizeBytes = declaredSizeBytes,
    )
    if (reconciliation.shouldTruncateFile) {
        java.io.RandomAccessFile(temp, "rw").use { it.setLength(reconciliation.receivedBytes) }
    }
    return reconciliation
}

/** Stable, constant-time comparison for the independent upload resume credential. */
internal fun transferBelongsToResumeToken(resumeTokenHash: String, resumeToken: String?): Boolean {
    if (resumeToken.isNullOrEmpty()) return false
    val currentHash = MessageDigest.getInstance("SHA-256").digest(resumeToken.toByteArray(StandardCharsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    return MessageDigest.isEqual(
        resumeTokenHash.toByteArray(StandardCharsets.US_ASCII),
        currentHash.toByteArray(StandardCharsets.US_ASCII),
    )
}

internal fun validateWifiChunkRange(
    chunkIndex: Long,
    value: String,
    expectedStart: Long,
    expectedTotal: Long,
    contentLength: Long,
): ContentRange {
    val match = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(value)
        ?: throw IllegalArgumentException("invalid Content-Range")
    val start = match.groupValues[1].toLong()
    val end = match.groupValues[2].toLong()
    val total = match.groupValues[3].toLong()
    require(total == expectedTotal && start == expectedStart) { "invalid Content-Range" }
    require(end >= start && end < total) { "invalid Content-Range" }
    require(start % WifiTransferServer.CHUNK_BYTES == 0L && chunkIndex == start / WifiTransferServer.CHUNK_BYTES) { "invalid chunk index" }
    require(end - start + 1 == contentLength) { "invalid Content-Range length" }
    require(end - start + 1 in 1..WifiTransferServer.CHUNK_BYTES) { "chunk too large" }
    return ContentRange(start, end, total)
}

/**
 * Small dependency-free HTTP/1.1 upload receiver for the foreground Wi-Fi page.
 * It intentionally supports only the exact upload endpoints in the Papria protocol.
 */
class WifiTransferServer private constructor(
    private val context: Context,
    private val database: PapriaDatabase,
    private val store: ContentAddressedStore,
    private val session: TransferSession,
    private val liveState: WifiTransferLiveState,
) : AutoCloseable {
    constructor(
        context: Context,
        database: PapriaDatabase = PapriaDatabase.get(context),
        store: ContentAddressedStore = ContentAddressedStore(context),
        session: TransferSession = TransferSessionFactory.create(),
    ) : this(context, database, store, session, WifiTransferLiveState())

    internal constructor(
        context: Context,
        liveState: WifiTransferLiveState,
    ) : this(context, PapriaDatabase.get(context), ContentAddressedStore(context), TransferSessionFactory.create(), liveState)

    private val running = AtomicBoolean(false)
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val cleanupExecutor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val cancellationRequests = ConcurrentHashMap.newKeySet<String>()
    private var serverSocket: ServerSocket? = null
    private var bindAddress: InetAddress? = null

    val sessionInfo: TransferSession get() = session
    val port: Int get() = serverSocket?.localPort ?: 0
    val address: String get() = bindAddress?.hostAddress ?: localLanAddress(context)?.hostAddress.orEmpty()
    val uploadUrl: String get() = "http://$address:$port/#${session.bearerToken}"
    /** Receiver-originated upload progress. It never includes upload credentials or temp paths. */
    val uploadSnapshot: StateFlow<WifiTransferServerSnapshot> get() = liveState.snapshot

    @Synchronized
    fun start(preferredAddress: InetAddress? = localLanAddress(context), requestedPort: Int = 0): TransferSession {
        if (running.get()) return session
        cleanupExpired()
        val address = preferredAddress ?: throw IllegalStateException("no local Wi-Fi address")
        require(!address.isLoopbackAddress && address is Inet4Address) { "Wi-Fi transfer requires a local IPv4 interface" }
        bindAddress = address
        serverSocket = ServerSocket(requestedPort, 32, address)
        running.set(true)
        liveState.start()
        cleanupExecutor.scheduleAtFixedRate(
            { runCatching { cleanupExpired() } },
            CLEANUP_INTERVAL_MILLIS,
            CLEANUP_INTERVAL_MILLIS,
            TimeUnit.MILLISECONDS,
        )
        executor.execute {
            while (running.get()) {
                try {
                    val socket = serverSocket?.accept() ?: break
                    executor.execute { handle(socket) }
                } catch (_: Exception) {
                    if (running.get()) continue
                }
            }
        }
        return session
    }

    override fun close() {
        running.set(false)
        try { serverSocket?.close() } catch (_: Exception) { }
        liveState.stop()
        executor.shutdownNow()
        cleanupExecutor.shutdownNow()
    }

    /**
     * Requests cancellation of one local receiver upload without exposing its
     * independent resume credential. Receiving, validation and failed uploads
     * are cancellable. Importing is deliberately not: the content-addressed
     * import may already have committed a shared file, so interrupting it would
     * not preserve the existing protocol's storage guarantees.
     *
     * A `true` result means the receiver accepted the request. The terminal
     * [WifiTransferUploadLifecycle.CANCELLED] event is emitted only after the
     * partial file and its persisted upload record have actually been removed.
     */
    fun cancelUpload(uploadId: String): Boolean {
        if (!running.get() || uploadId.isBlank() || !liveState.containsCancellableUpload(uploadId)) return false
        if (!cancellationRequests.add(uploadId)) return true
        return try {
            executor.execute { cancelRequestedUpload(uploadId) }
            true
        } catch (_: RuntimeException) {
            cancellationRequests.remove(uploadId)
            false
        }
    }

    private fun handle(socket: Socket) {
        socket.use { raw ->
            raw.soTimeout = 30_000
            val input = BufferedInputStream(raw.getInputStream())
            val output = BufferedOutputStream(raw.getOutputStream())
            try {
                val request = readRequest(input)
                // Cleanup also runs while a long-lived foreground transfer
                // session is active, not only when the listener starts.
                cleanupExpired()
                // The HTML shell is intentionally public to the current LAN host: the
                // session token lives in the URL fragment and therefore cannot be sent
                // with the initial GET. Every state-changing/API request remains gated.
                if (!(request.method == "GET" && request.path == "/") && !authorize(request.headers["authorization"])) {
                    respond(output, 401, "application/json", "{\"error\":\"unauthorized\"}")
                    return
                }
                when {
                    request.method == "GET" && request.path == "/" -> respond(output, 200, "text/html; charset=utf-8", uploadPage())
                    request.method == "POST" && request.path == "/api/uploads" -> createUpload(request, input, output)
                    request.method == "GET" && request.path.matches(Regex("/api/uploads/[^/]+")) -> status(request, output)
                    request.method == "PUT" && request.path.matches(Regex("/api/uploads/[^/]+/chunks/[0-9]+")) -> chunk(request, input, output)
                    request.method == "POST" && request.path.matches(Regex("/api/uploads/[^/]+/complete")) -> complete(request, output)
                    request.method == "DELETE" && request.path.matches(Regex("/api/uploads/[^/]+")) -> cancel(request, output)
                    else -> respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
                }
            } catch (_: RequestError) {
                respond(output, 400, "application/json", "{\"error\":\"bad_request\"}")
            } catch (_: Exception) {
                respond(output, 500, "application/json", "{\"error\":\"server_error\"}")
            }
        }
    }

    private fun createUpload(request: HttpRequest, input: InputStream, output: OutputStream) {
        val body = readBody(input, request.contentLength, MAX_METADATA_BYTES)
        val json = JSONObject(String(body, StandardCharsets.UTF_8))
        val fileName = safeFileName(json.getString("fileName"))
        val sizeBytes = json.getLong("sizeBytes")
        require(sizeBytes in 1..MAX_UPLOAD_BYTES) { "invalid sizeBytes" }
        require(store.freeBytes() >= sizeBytes + MIN_FREE_BYTES) { "insufficient storage" }
        val id = UUID.randomUUID().toString()
        val resumeToken = SecureTransferToken.create(byteCount = 32)
        val temp = File(context.cacheDir, "wifi-$id.part")
        val now = System.currentTimeMillis()
        database.saveTransfer(TransferUploadRecord(id, fileName, sizeBytes, sha256(resumeToken.toByteArray()), temp.absolutePath, 0, now, now))
        liveState.receiving(id, fileName, receivedBytes = 0, totalBytes = sizeBytes)
        respond(output, 201, "application/json", JSONObject().put("uploadId", id).put("resumeToken", resumeToken).put("receivedBytes", 0).toString())
    }

    @Synchronized
    private fun status(request: HttpRequest, output: OutputStream) {
        val id = uploadId(request.path)
        val item = database.transfer(id) ?: return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        if (!belongsToCurrentUpload(item, request.headers[RESUME_TOKEN_HEADER])) return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        val recovered = reconcileTransfer(item)
        liveState.receiving(id, recovered.fileName, recovered.receivedBytes, recovered.sizeBytes)
        respond(output, 200, "application/json", JSONObject().put("uploadId", id).put("fileName", recovered.fileName).put("sizeBytes", recovered.sizeBytes).put("receivedBytes", recovered.receivedBytes).toString())
    }

    @Synchronized
    private fun chunk(request: HttpRequest, input: InputStream, output: OutputStream) {
        val id = uploadId(request.path)
        val item = database.transfer(id) ?: return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        if (!belongsToCurrentUpload(item, request.headers[RESUME_TOKEN_HEADER])) return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        val recovered = reconcileTransfer(item)
        if (cancellationRequests.contains(id)) {
            finishCancelledUpload(recovered)
            respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
            return
        }
        val chunkIndex = request.path.substringAfterLast('/').toLongOrNull() ?: throw RequestError()
        val range = try {
            validateWifiChunkRange(
                chunkIndex = chunkIndex,
                value = request.headers["content-range"] ?: throw IllegalArgumentException("missing Content-Range"),
                expectedStart = recovered.receivedBytes,
                expectedTotal = recovered.sizeBytes,
                contentLength = request.contentLength,
            )
        } catch (_: IllegalArgumentException) {
            throw RequestError()
        }
        try {
            val temp = File(recovered.tempPath)
            temp.parentFile?.mkdirs()
            // Reconciliation guarantees this append begins exactly at the physical end of file.
            // Do not seek: seeking past EOF would silently manufacture a sparse-file hole.
            require(temp.length() == range.start) { "upload file changed while writing" }
            FileOutputStream(temp, true).use { file ->
                copyExactly(input, file, range.length) { copiedBytes ->
                    if (cancellationRequests.contains(id)) throw UploadCancellationRequested()
                    liveState.receiving(
                        uploadId = id,
                        fileName = recovered.fileName,
                        receivedBytes = range.start + copiedBytes,
                        totalBytes = recovered.sizeBytes,
                    )
                }
                file.fd.sync()
            }
            if (cancellationRequests.contains(id)) throw UploadCancellationRequested()
            require(temp.length() == range.end + 1) { "upload write did not reach expected length" }
            database.updateTransferReceived(id, range.end + 1)
            liveState.receiving(id, recovered.fileName, range.end + 1, recovered.sizeBytes)
            respond(output, 204, null, "")
        } catch (_: UploadCancellationRequested) {
            finishCancelledUpload(recovered)
            respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        } catch (error: Exception) {
            liveState.failed(id, recovered.fileName, physicalReceivedBytes(recovered), recovered.sizeBytes, safeError(error))
            throw error
        }
    }

    @Synchronized
    private fun complete(request: HttpRequest, output: OutputStream) {
        val id = uploadId(request.path)
        val item = database.transfer(id) ?: return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        if (!belongsToCurrentUpload(item, request.headers[RESUME_TOKEN_HEADER])) return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        val recovered = reconcileTransfer(item)
        try {
            if (cancellationRequests.contains(id)) throw UploadCancellationRequested()
            require(recovered.receivedBytes == recovered.sizeBytes) { "upload is incomplete" }
            val temp = File(recovered.tempPath)
            // All writes above are durable, verified sequential appends. This exact physical-length
            // check prevents a DB-only completion, and no accepted write can create a sparse gap.
            require(temp.isFile && temp.length() == recovered.sizeBytes) { "upload file missing" }
            liveState.validating(id, recovered.fileName, recovered.receivedBytes, recovered.sizeBytes)
            FormatPolicy.validateFile(temp, recovered.fileName)
            FormatPolicy.validateContainer(temp, recovered.fileName)
            if (cancellationRequests.contains(id)) throw UploadCancellationRequested()
            liveState.importing(id, recovered.fileName, recovered.receivedBytes, recovered.sizeBytes)
            val stored = store.import(temp)
            temp.delete()
            database.upsertPublication(LocalPublication(
                localId = "wifi-${stored.sha256}", title = recovered.fileName.substringBeforeLast('.').ifBlank { recovered.fileName }, author = null,
                format = recovered.fileName.substringAfterLast('.', "").lowercase(), localPath = stored.file.absolutePath, contentHash = stored.sha256,
                remoteBookId = null, remoteFileId = null, source = "wifi", downloaded = true, updatedAt = System.currentTimeMillis(),
            ))
            database.deleteTransfer(id)
            cancellationRequests.remove(id)
            liveState.completed(id, recovered.fileName, recovered.sizeBytes, recovered.sizeBytes)
            respond(output, 201, "application/json", JSONObject().put("sha256", stored.sha256).put("sizeBytes", stored.sizeBytes).toString())
        } catch (_: UploadCancellationRequested) {
            finishCancelledUpload(recovered)
            respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        } catch (error: Exception) {
            liveState.failed(id, recovered.fileName, recovered.receivedBytes, recovered.sizeBytes, safeError(error))
            throw error
        }
    }

    @Synchronized
    private fun cancel(request: HttpRequest, output: OutputStream) {
        val id = uploadId(request.path)
        val item = database.transfer(id)
        if (item != null && !belongsToCurrentUpload(item, request.headers[RESUME_TOKEN_HEADER])) return respond(output, 404, "application/json", "{\"error\":\"not_found\"}")
        item?.let { finishCancelledUpload(it) }
        respond(output, 204, null, "")
    }

    @Synchronized
    private fun cancelRequestedUpload(uploadId: String) {
        if (!cancellationRequests.contains(uploadId)) return
        val item = database.transfer(uploadId)
        if (item == null) {
            cancellationRequests.remove(uploadId)
            return
        }
        finishCancelledUpload(item)
    }

    private fun finishCancelledUpload(item: TransferUploadRecord) {
        val receivedBytes = physicalReceivedBytes(item)
        File(item.tempPath).delete()
        database.deleteTransfer(item.uploadId)
        cancellationRequests.remove(item.uploadId)
        liveState.cancelled(
            uploadId = item.uploadId,
            fileName = item.fileName,
            receivedBytes = receivedBytes,
            totalBytes = item.sizeBytes,
        )
    }

    private fun authorize(value: String?): Boolean {
        val expected = "Bearer ${session.bearerToken}"
        return value == expected && !session.isExpired()
    }

    @Synchronized
    private fun cleanupExpired() {
        val threshold = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        database.staleTransfers(threshold).forEach { finishCancelledUpload(it) }
        store.cleanupParts(threshold)
    }

    /**
     * A fresh QR bearer unlocks the active local receiver; this independent
     * proof additionally owns one unfinished upload for its 24-hour lifetime.
     */
    private fun belongsToCurrentUpload(item: TransferUploadRecord, resumeToken: String?): Boolean =
        transferBelongsToResumeToken(item.resumeTokenHash, resumeToken)

    /**
     * Correct Room metadata from the actual temporary file before status, upload, or completion.
     * A partial trailing chunk is discarded so the next accepted request must be a contiguous
     * append at an 8 MiB boundary. A file larger than its declared size is rejected fail-closed.
     */
    private fun reconcileTransfer(item: TransferUploadRecord): TransferUploadRecord {
        val temp = File(item.tempPath)
        val reconciliation = reconcileWifiUploadPartFile(
            temp = temp,
            persistedReceivedBytes = item.receivedBytes,
            declaredSizeBytes = item.sizeBytes,
        )
        if (reconciliation.shouldUpdateDatabase) {
            database.updateTransferReceived(item.uploadId, reconciliation.receivedBytes)
        }
        return item.copy(receivedBytes = reconciliation.receivedBytes)
    }

    private fun physicalReceivedBytes(item: TransferUploadRecord): Long = runCatching {
        File(item.tempPath).length().coerceIn(0, item.sizeBytes)
    }.getOrDefault(item.receivedBytes)

    private fun safeError(error: Exception): String = when (error) {
        is EOFException -> "上传数据不完整"
        is IllegalArgumentException -> error.message
            ?.replace(Regex("[\\r\\n\\t]+"), " ")
            ?.take(MAX_LIVE_ERROR_LENGTH)
            ?.takeIf { it.isNotBlank() }
            ?: "上传数据无效"
        else -> "上传处理失败"
    }

    private fun uploadPage(): String = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Papria Wi-Fi transfer</title><h1>Papria Wi-Fi transfer</h1>
        <p id="drop" style="border:2px dashed #888;padding:2em;text-align:center">拖拽文件到这里，或点击选择文件</p>
        <input id="files" type="file" multiple><pre id="status"></pre>
        <script>
        const token=location.hash.slice(1), out=document.getElementById('status'), drop=document.getElementById('drop'), queue=[]; let running=false;
        async function send(file){
          const h={'Authorization':'Bearer '+token,'Content-Type':'application/json'};
          const key='papria-upload:'+file.name+':'+file.size+':'+file.lastModified; let u=null;
          try { const saved=JSON.parse(localStorage.getItem(key)||'null'); if(saved&&typeof saved.uploadId==='string'&&typeof saved.resumeToken==='string') u=saved; else if(saved) localStorage.removeItem(key); } catch (_) { localStorage.removeItem(key); }
          if(u){const s=await fetch('/api/uploads/'+encodeURIComponent(u.uploadId),{headers:{'Authorization':'Bearer '+token,'X-Papria-Resume-Token':u.resumeToken}}); if(s.ok) u={...u,...await s.json()}; else {localStorage.removeItem(key);u=null;}}
          if(!u){const c=await fetch('/api/uploads',{method:'POST',headers:h,body:JSON.stringify({fileName:file.name,sizeBytes:file.size})}); if(!c.ok) throw Error('create '+c.status); u=await c.json(); localStorage.setItem(key,JSON.stringify({uploadId:u.uploadId,resumeToken:u.resumeToken}));}
          const chunk=8*1024*1024;
          for(let s=u.receivedBytes;s<file.size;s+=chunk){let e=Math.min(file.size,s+chunk)-1;
            const r=await fetch('/api/uploads/'+u.uploadId+'/chunks/'+Math.floor(s/chunk),{method:'PUT',headers:{'Authorization':'Bearer '+token,'X-Papria-Resume-Token':u.resumeToken,'Content-Range':'bytes '+s+'-'+e+'/'+file.size,'Content-Length':String(e-s+1)},body:file.slice(s,e+1)}); if(!r.ok) throw Error('chunk '+r.status);
            out.textContent=file.name+' '+Math.round((e+1)*100/file.size)+'%';}
          const done=await fetch('/api/uploads/'+u.uploadId+'/complete',{method:'POST',headers:{'Authorization':'Bearer '+token,'X-Papria-Resume-Token':u.resumeToken}}); if(!done.ok) throw Error('complete '+done.status); localStorage.removeItem(key); out.textContent=file.name+' 已完成';
        }
        async function drain(){if(running)return; running=true; while(queue.length){const file=queue.shift(); try{await send(file)}catch(e){out.textContent=file.name+' 失败：'+e.message}} running=false;}
        function enqueue(files){queue.push(...files); out.textContent='队列 '+queue.length+' 个文件'; drain();}
        document.getElementById('files').onchange=e=>enqueue([...e.target.files]);
        drop.ondragover=e=>{e.preventDefault();drop.style.background='#eee'};
        drop.ondragleave=()=>drop.style.background='';
        drop.ondrop=e=>{e.preventDefault();drop.style.background='';enqueue([...e.dataTransfer.files]);};
        </script>
    """.trimIndent()

    private fun readRequest(input: BufferedInputStream): HttpRequest {
        val requestLine = readLine(input) ?: throw EOFException()
        val parts = requestLine.split(' ')
        require(parts.size == 3 && parts[2] == "HTTP/1.1") { "invalid request" }
        val headers = linkedMapOf<String, String>()
        while (true) {
            val line = readLine(input) ?: throw EOFException()
            if (line.isEmpty()) break
            val index = line.indexOf(':')
            require(index > 0) { "invalid header" }
            headers[line.substring(0, index).lowercase()] = line.substring(index + 1).trim()
        }
        return HttpRequest(parts[0], parts[1].substringBefore('?'), headers, headers["content-length"]?.toLongOrNull() ?: 0)
    }

    private fun readLine(input: InputStream): String? {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val value = input.read()
            if (value < 0) return if (bytes.size() == 0) null else String(bytes.toByteArray(), StandardCharsets.ISO_8859_1)
            if (value == '\n'.code) break
            if (value != '\r'.code) bytes.write(value)
            if (bytes.size() > MAX_HEADER_BYTES) throw RequestError()
        }
        return String(bytes.toByteArray(), StandardCharsets.ISO_8859_1)
    }

    private fun readBody(input: InputStream, length: Long, max: Long): ByteArray {
        require(length in 0..max) { "invalid body length" }
        val body = ByteArray(length.toInt())
        var offset = 0
        while (offset < body.size) { val count = input.read(body, offset, body.size - offset); if (count < 0) throw EOFException(); offset += count }
        return body
    }

    private fun copyExactly(input: InputStream, output: OutputStream, length: Long, onProgress: (Long) -> Unit) {
        val buffer = ByteArray(64 * 1024)
        var remaining = length
        var copied = 0L
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count < 0) throw EOFException()
            output.write(buffer, 0, count)
            remaining -= count
            copied += count
            onProgress(copied)
        }
    }

    private fun respond(output: OutputStream, status: Int, type: String?, body: String) {
        val bytes = body.toByteArray(StandardCharsets.UTF_8)
        val reason = when (status) { 200 -> "OK"; 201 -> "Created"; 204 -> "No Content"; 400 -> "Bad Request"; 401 -> "Unauthorized"; 404 -> "Not Found"; else -> "Internal Server Error" }
        output.write("HTTP/1.1 $status $reason\r\nConnection: close\r\nContent-Length: ${if (status == 204) 0 else bytes.size}\r\n".toByteArray())
        if (type != null) output.write("Content-Type: $type\r\n".toByteArray())
        output.write("\r\n".toByteArray()); if (status != 204) output.write(bytes); output.flush()
    }

    private fun uploadId(path: String): String = path.split('/').getOrNull(3)?.takeIf { it.isNotBlank() } ?: throw RequestError()
    private fun safeFileName(value: String): String {
        require(value.isNotBlank() && value.toByteArray(StandardCharsets.UTF_8).size <= 255)
        require(value.none { it.code < 0x20 || it.code == 0x7f || it == '/' || it == '\\' || it in charArrayOf('<', '>', ':', '"', '|', '?', '*') })
        require(value != "." && value != "..")
        require(!value.endsWith('.') && !value.endsWith(' '))
        val device = value.substringBefore('.').uppercase()
        require(device !in setOf("CON", "PRN", "AUX", "NUL") && !device.matches(Regex("(?:COM|LPT)[1-9]")))
        return value
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private data class HttpRequest(val method: String, val path: String, val headers: Map<String, String>, val contentLength: Long)
    private class RequestError : RuntimeException()
    private class UploadCancellationRequested : RuntimeException()

    companion object {
        const val CHUNK_BYTES = 8L * 1024L * 1024L
        private const val MAX_UPLOAD_BYTES = 16L * 1024L * 1024L * 1024L
        private const val MAX_METADATA_BYTES = 16L * 1024L
        private const val MAX_HEADER_BYTES = 16 * 1024
        private const val MIN_FREE_BYTES = 8L * 1024L * 1024L
        private const val CLEANUP_INTERVAL_MILLIS = 60L * 60L * 1000L
        private const val RESUME_TOKEN_HEADER = "x-papria-resume-token"
        private const val MAX_LIVE_ERROR_LENGTH = 240

        fun localLanAddress(context: Context): InetAddress? {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val networks = if (Build.VERSION.SDK_INT >= 23) manager.allNetworks.toList() else emptyList()
            for (network in networks) {
                val caps = manager.getNetworkCapabilities(network)
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    val properties: LinkProperties = manager.getLinkProperties(network) ?: continue
                    properties.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }?.let { return it }
                }
            }
            return null
        }
    }
}
