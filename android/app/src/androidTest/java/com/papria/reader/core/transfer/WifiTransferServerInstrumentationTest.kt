package com.papria.reader.core.transfer

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.papria.reader.core.local.PapriaDatabase
import com.papria.reader.core.local.TransferUploadRecord
import com.papria.reader.core.storage.ContentAddressedStore
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WifiTransferServerInstrumentationTest {
    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val database: PapriaDatabase
        get() = PapriaDatabase.get(context)

    private val store: ContentAddressedStore
        get() = ContentAddressedStore(context)

    private var server: WifiTransferServer? = null
    private val transferIds = linkedSetOf<String>()
    private val importedHashes = linkedSetOf<String>()

    @After
    fun tearDown() {
        server?.close()
        transferIds.forEach { uploadId ->
            database.transfer(uploadId)?.let { File(it.tempPath).delete() }
            database.deleteTransfer(uploadId)
        }
        importedHashes.forEach { hash ->
            database.deletePublication("wifi-$hash")
            store.remove(hash)
        }
    }

    @Test
    fun start_is_idempotent_serves_the_public_page_and_cleans_stale_uploads() {
        val staleId = "instrumentation-stale-${UUID.randomUUID()}"
        val stalePart = File(context.cacheDir, "wifi-$staleId.part").apply {
            writeBytes(byteArrayOf(1, 2, 3))
        }
        transferIds += staleId
        database.saveTransfer(
            TransferUploadRecord(
                uploadId = staleId,
                fileName = "stale.txt",
                sizeBytes = stalePart.length(),
                resumeTokenHash = sha256("stale-resume-token"),
                tempPath = stalePart.absolutePath,
                receivedBytes = stalePart.length(),
                createdAt = 1L,
                updatedAt = 1L,
            ),
        )
        val session = activeSession()
        val address = deviceIpv4Address()
        val receiver = WifiTransferServer(context, database, store, session).also { server = it }

        assertSame(session, receiver.start(address, requestedPort = 0))
        val originalPort = receiver.port
        assertTrue(originalPort > 0)
        assertSame(session, receiver.start(address, requestedPort = originalPort))
        assertEquals(originalPort, receiver.port)
        assertEquals("http://${address.hostAddress}:$originalPort/#${session.bearerToken}", receiver.uploadUrl)

        val page = request(address, originalPort, method = "GET", path = "/")
        assertEquals(200, page.status)
        assertTrue(page.header("content-type").orEmpty().startsWith("text/html"))
        assertTrue(page.body.isNotEmpty())
        assertNull(database.transfer(staleId))
        assertFalse(stalePart.exists())

        receiver.close()
        server = null
        assertConnectionRejected(address, originalPort)
    }

    @Test
    fun expired_or_incorrect_bearer_cannot_create_an_upload() {
        val address = deviceIpv4Address()
        val active = activeSession()
        val activeReceiver = WifiTransferServer(context, database, store, active).also { server = it }
        activeReceiver.start(address, requestedPort = 0)
        val metadata = JSONObject().put("fileName", "blocked.txt").put("sizeBytes", 4).toString()
        val wrongResponse = request(
            address,
            activeReceiver.port,
            method = "POST",
            path = "/api/uploads",
            headers = mapOf(
                "Authorization" to "Bearer wrong-bearer",
                "Content-Type" to "application/json",
            ),
            body = metadata.toByteArray(StandardCharsets.UTF_8),
        )
        assertEquals(401, wrongResponse.status)
        activeReceiver.close()

        val expired = TransferSession(
            uploadSessionId = "instrumentation-expired",
            bearerToken = "expired-bearer",
            expiresAtEpochMillis = System.currentTimeMillis() - 1,
        )
        val receiver = WifiTransferServer(context, database, store, expired).also { server = it }
        receiver.start(address, requestedPort = 0)
        val expiredResponse = request(
            address,
            receiver.port,
            method = "POST",
            path = "/api/uploads",
            headers = mapOf(
                "Authorization" to "Bearer ${expired.bearerToken}",
                "Content-Type" to "application/json",
            ),
            body = metadata.toByteArray(StandardCharsets.UTF_8),
        )
        assertEquals(401, expiredResponse.status)
    }

    @Test
    fun upload_http_flow_enforces_resume_token_writes_bytes_and_completes_import() {
        val content = "Papria instrumentation transfer".toByteArray(StandardCharsets.UTF_8)
        val address = deviceIpv4Address()
        val session = activeSession()
        val receiver = WifiTransferServer(context, database, store, session).also { server = it }
        receiver.start(address, requestedPort = 0)

        val created = createUpload(address, receiver, session, "instrumented.txt", content.size.toLong())
        val uploadId = created.getString("uploadId")
        val resumeToken = created.getString("resumeToken")
        transferIds += uploadId
        val record = requireNotNull(database.transfer(uploadId))
        val part = File(record.tempPath)
        assertEquals(0L, record.receivedBytes)
        assertFalse(part.exists())

        val hiddenStatus = request(
            address,
            receiver.port,
            method = "GET",
            path = "/api/uploads/$uploadId",
            headers = uploadHeaders(session, "wrong-resume-token"),
        )
        val invalidChunk = request(
            address,
            receiver.port,
            method = "PUT",
            path = "/api/uploads/$uploadId/chunks/0",
            headers = uploadHeaders(session, resumeToken) +
                ("Content-Range" to "bytes 1-${content.size}/${content.size}"),
            body = content,
        )

        assertEquals(404, hiddenStatus.status)
        assertEquals(400, invalidChunk.status)
        assertEquals(0L, requireNotNull(database.transfer(uploadId)).receivedBytes)
        assertFalse(part.exists())

        val uploaded = request(
            address,
            receiver.port,
            method = "PUT",
            path = "/api/uploads/$uploadId/chunks/0",
            headers = uploadHeaders(session, resumeToken) +
                ("Content-Range" to "bytes 0-${content.size - 1}/${content.size}"),
            body = content,
        )
        assertEquals(204, uploaded.status)
        assertEquals(content.size.toLong(), requireNotNull(database.transfer(uploadId)).receivedBytes)
        assertArrayEquals(content, part.readBytes())

        val status = request(
            address,
            receiver.port,
            method = "GET",
            path = "/api/uploads/$uploadId",
            headers = uploadHeaders(session, resumeToken),
        )
        assertEquals(200, status.status)
        assertEquals(content.size.toLong(), JSONObject(status.bodyText()).getLong("receivedBytes"))

        val wrongOwnerComplete = request(
            address,
            receiver.port,
            method = "POST",
            path = "/api/uploads/$uploadId/complete",
            headers = uploadHeaders(session, "wrong-resume-token"),
        )
        assertEquals(404, wrongOwnerComplete.status)
        assertNotNull(database.transfer(uploadId))
        assertTrue(part.isFile)

        val completed = request(
            address,
            receiver.port,
            method = "POST",
            path = "/api/uploads/$uploadId/complete",
            headers = uploadHeaders(session, resumeToken),
        )
        assertEquals(201, completed.status)
        val completedJson = JSONObject(completed.bodyText())
        val hash = completedJson.getString("sha256")
        importedHashes += hash
        assertEquals(sha256(content), hash)
        assertEquals(content.size.toLong(), completedJson.getLong("sizeBytes"))
        assertNull(database.transfer(uploadId))
        assertFalse(part.exists())
        assertArrayEquals(content, requireNotNull(store.existing(hash)).readBytes())
        assertTrue(database.localPublications().any { it.localId == "wifi-$hash" && it.source == "wifi" })
    }

    @Test
    fun cancel_with_the_resume_token_removes_the_record_and_partial_file() {
        val content = byteArrayOf(4, 3, 2, 1)
        val address = deviceIpv4Address()
        val session = activeSession()
        val receiver = WifiTransferServer(context, database, store, session).also { server = it }
        receiver.start(address, requestedPort = 0)
        val created = createUpload(address, receiver, session, "cancelled.txt", content.size.toLong())
        val uploadId = created.getString("uploadId")
        val resumeToken = created.getString("resumeToken")
        transferIds += uploadId
        val part = File(requireNotNull(database.transfer(uploadId)).tempPath)

        val uploaded = request(
            address,
            receiver.port,
            method = "PUT",
            path = "/api/uploads/$uploadId/chunks/0",
            headers = uploadHeaders(session, resumeToken) +
                ("Content-Range" to "bytes 0-${content.size - 1}/${content.size}"),
            body = content,
        )
        assertEquals(204, uploaded.status)
        assertTrue(part.isFile)

        val denied = request(
            address,
            receiver.port,
            method = "DELETE",
            path = "/api/uploads/$uploadId",
            headers = uploadHeaders(session, "wrong-resume-token"),
        )
        assertEquals(404, denied.status)
        assertNotNull(database.transfer(uploadId))
        assertTrue(part.isFile)

        val cancelled = request(
            address,
            receiver.port,
            method = "DELETE",
            path = "/api/uploads/$uploadId",
            headers = uploadHeaders(session, resumeToken),
        )
        assertEquals(204, cancelled.status)
        assertNull(database.transfer(uploadId))
        assertFalse(part.exists())
    }

    private fun createUpload(
        address: InetAddress,
        receiver: WifiTransferServer,
        session: TransferSession,
        fileName: String,
        sizeBytes: Long,
    ): JSONObject {
        val body = JSONObject().put("fileName", fileName).put("sizeBytes", sizeBytes)
            .toString().toByteArray(StandardCharsets.UTF_8)
        val response = request(
            address,
            receiver.port,
            method = "POST",
            path = "/api/uploads",
            headers = mapOf(
                "Authorization" to "Bearer ${session.bearerToken}",
                "Content-Type" to "application/json",
            ),
            body = body,
        )
        assertEquals(201, response.status)
        return JSONObject(response.bodyText()).also {
            assertEquals(0L, it.getLong("receivedBytes"))
            assertTrue(it.getString("resumeToken").length == 64)
        }
    }

    private fun activeSession(): TransferSession = TransferSession(
        uploadSessionId = "instrumentation-${UUID.randomUUID()}",
        bearerToken = "bearer-${UUID.randomUUID()}",
        expiresAtEpochMillis = System.currentTimeMillis() + 60_000,
    )

    private fun uploadHeaders(session: TransferSession, resumeToken: String): Map<String, String> = mapOf(
        "Authorization" to "Bearer ${session.bearerToken}",
        "X-Papria-Resume-Token" to resumeToken,
    )

    private fun deviceIpv4Address(): InetAddress {
        val address = Collections.list(NetworkInterface.getNetworkInterfaces())
            .asSequence()
            .filter { runCatching { it.isUp }.getOrDefault(false) }
            .flatMap { Collections.list(it.inetAddresses).asSequence() }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress && !it.isAnyLocalAddress }
        return address ?: InetAddress.getByName("127.0.0.1")
    }

    private fun request(
        address: InetAddress,
        port: Int,
        method: String,
        path: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
    ): HttpResponse {
        Socket(address, port).use { socket ->
            socket.soTimeout = 5_000
            val output = socket.getOutputStream()
            val requestHeaders = linkedMapOf(
                "Host" to "${address.hostAddress}:$port",
                "Connection" to "close",
            )
            requestHeaders.putAll(headers)
            if (body.isNotEmpty() && requestHeaders.keys.none { it.equals("Content-Length", ignoreCase = true) }) {
                requestHeaders["Content-Length"] = body.size.toString()
            }
            val head = buildString {
                append(method).append(' ').append(path).append(" HTTP/1.1\r\n")
                requestHeaders.forEach { (name, value) -> append(name).append(": ").append(value).append("\r\n") }
                append("\r\n")
            }
            output.write(head.toByteArray(StandardCharsets.ISO_8859_1))
            output.write(body)
            output.flush()

            val input = BufferedInputStream(socket.getInputStream())
            val statusLine = readHttpLine(input)
            val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
                ?: error("invalid HTTP status line: $statusLine")
            val responseHeaders = linkedMapOf<String, String>()
            while (true) {
                val line = readHttpLine(input)
                if (line.isEmpty()) break
                val separator = line.indexOf(':')
                require(separator > 0) { "invalid HTTP response header: $line" }
                responseHeaders[line.substring(0, separator).lowercase()] = line.substring(separator + 1).trim()
            }
            val contentLength = responseHeaders["content-length"]?.toIntOrNull() ?: 0
            val responseBody = ByteArray(contentLength)
            var offset = 0
            while (offset < responseBody.size) {
                val count = input.read(responseBody, offset, responseBody.size - offset)
                check(count >= 0) { "response ended before Content-Length" }
                offset += count
            }
            return HttpResponse(status, responseHeaders, responseBody)
        }
    }

    private fun readHttpLine(input: BufferedInputStream): String {
        val output = ByteArrayOutputStream()
        while (true) {
            val value = input.read()
            check(value >= 0) { "unexpected end of HTTP response" }
            if (value == '\n'.code) break
            if (value != '\r'.code) output.write(value)
        }
        return output.toString(StandardCharsets.ISO_8859_1.name())
    }

    private fun assertConnectionRejected(address: InetAddress, port: Int) {
        val connected = runCatching { Socket(address, port).use { } }.isSuccess
        assertFalse("closed receiver still accepted a connection on port $port", connected)
    }

    private fun sha256(value: String): String = sha256(value.toByteArray(StandardCharsets.UTF_8))

    private fun sha256(value: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(value)
        .joinToString("") { "%02x".format(it) }

    private data class HttpResponse(
        val status: Int,
        val headers: Map<String, String>,
        val body: ByteArray,
    ) {
        fun header(name: String): String? = headers[name.lowercase()]
        fun bodyText(): String = String(body, StandardCharsets.UTF_8)
    }
}
