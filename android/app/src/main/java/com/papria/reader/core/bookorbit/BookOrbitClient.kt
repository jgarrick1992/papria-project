package com.papria.reader.core.bookorbit

import com.papria.reader.core.model.AudioProgress
import com.papria.reader.core.model.FileProgress
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import com.papria.reader.core.security.CertificatePinning
import com.papria.reader.core.local.ServerProfileRecord
import java.net.InetAddress
import java.net.Inet6Address

class BookOrbitClient(
    serverUrl: String,
    certificateSha256: String? = null,
    httpClient: OkHttpClient? = null,
    cleartextHttpConfirmation: CleartextHttpConfirmation? = null,
    private val cleartextTransportPolicy: CleartextTransportPolicy = AndroidCleartextTransportPolicy,
) {
    private val baseUrl: HttpUrl = serverUrl.trimEnd('/').toHttpUrl()
    private val certificateFingerprint = certificateSha256
    private val httpConfirmation = cleartextHttpConfirmation
    private val httpClient: OkHttpClient = (httpClient ?: buildHttpClient(certificateFingerprint))
        .newBuilder()
        .addNetworkInterceptor(Interceptor { chain ->
            // Network interceptors run once per exchange, so redirects cannot
            // escape the exact LAN host-and-port confirmation checked below.
            requireTransportBoundary(chain.request().url)
            chain.proceed(chain.request())
        })
        .build()
    @Volatile private var accessToken: String? = null
    @Volatile private var refreshCookie: String? = null

    fun setSession(accessToken: String?, refreshCookie: String? = this.refreshCookie) {
        this.accessToken = accessToken
        this.refreshCookie = refreshCookie
    }

    fun sessionAccessToken(): String? = accessToken
    fun sessionRefreshCookie(): String? = refreshCookie
    fun certificateSha256(): String? = certificateFingerprint
    fun isCleartextHttp(): Boolean = baseUrl.scheme == "http"
    fun host(): String = baseUrl.host
    fun port(): Int = baseUrl.port
    fun cleartextHttpConfirmation(): CleartextHttpConfirmation? = httpConfirmation
    fun serverUrl(): String = baseUrl.toString().trimEnd('/')
    fun sessionHeaders(): Map<String, String> = buildMap {
        accessToken?.takeIf(String::isNotBlank)?.let { put("Authorization", "Bearer $it") }
        refreshCookie?.takeIf(String::isNotBlank)?.let { put("Cookie", it) }
    }

    fun loginRequest(username: String, password: String): Request = request(BookOrbitContract.loginPath).post(BookOrbitContract.loginBody(username, password)).build()

    fun refreshRequest(): Request = request(BookOrbitContract.refreshPath).post(BookOrbitContract.refreshBody()).build()

    fun appInfoRequest(): Request = request(BookOrbitContract.appInfoPath).get().build()

    fun meRequest(): Request = request(BookOrbitContract.mePath).get().build()

    fun queryBooksRequest(page: Int, size: Int, query: String? = null): Request = request(BookOrbitContract.booksQueryPath).post(BookOrbitContract.queryBody(page, size, query)).build()

    fun serveFileRequest(fileId: Long, rangeStart: Long? = null): Request {
        val builder = request(BookOrbitContract.fileServePath.replace("{fileId}", fileId.toString()))
        if (rangeStart != null) builder.header("Range", "bytes=$rangeStart-")
        return builder.get().build()
    }

    fun getProgressRequest(fileId: Long): Request = request(BookOrbitContract.fileProgressPath.replace("{fileId}", fileId.toString())).get().build()

    fun saveProgressRequest(fileId: Long, progress: FileProgress): Request = request(BookOrbitContract.fileProgressPath.replace("{fileId}", fileId.toString())).post(BookOrbitContract.fileProgressBody(progress)).build()

    fun getAudioProgressRequest(bookId: Long): Request = request(BookOrbitContract.audioProgressPath.replace("{bookId}", bookId.toString())).get().build()

    fun saveAudioProgressRequest(bookId: Long, progress: AudioProgress): Request = request(BookOrbitContract.audioProgressPath.replace("{bookId}", bookId.toString())).patch(BookOrbitContract.audioProgressBody(progress)).build()

    fun bookRequest(bookId: Long): Request = request(BookOrbitContract.bookPath.replace("{bookId}", bookId.toString())).get().build()

    fun coverRequest(bookId: Long): Request = request(BookOrbitContract.coverPath.replace("{bookId}", bookId.toString())).get().build()

    /** Execute a request with the current bearer token and refresh cookie. */
    @Throws(IOException::class)
    fun execute(request: Request): ApiResponse {
        open(request).use { response ->
            val body = response.body?.string().orEmpty()
            val cookie = response.headers.values("Set-Cookie")
                .firstOrNull { it.substringBefore('=').equals("refresh_token", ignoreCase = true) }
                ?.substringBefore(';')
            if (cookie != null) refreshCookie = cookie
            return ApiResponse(response.code, response.headers, body, cookie)
        }
    }

    /** Read a bounded binary response (covers) while preserving refresh cookies. */
    @Throws(IOException::class)
    fun executeBytes(request: Request, maxBytes: Long = 16L * 1024L * 1024L): ByteApiResponse {
        open(request).use { response ->
            val body = response.body ?: throw IOException("BookOrbit returned an empty body")
            require(body.contentLength() <= maxBytes || body.contentLength() < 0) { "binary response is too large" }
            val bytes = body.bytes()
            require(bytes.size.toLong() <= maxBytes) { "binary response is too large" }
            val cookie = response.headers.values("Set-Cookie")
                .firstOrNull { it.substringBefore('=').equals("refresh_token", ignoreCase = true) }
                ?.substringBefore(';')
            if (cookie != null) refreshCookie = cookie
            return ByteApiResponse(response.code, response.headers, bytes, cookie)
        }
    }

    /** Open a response without consuming its body. The caller owns and closes it. */
    @Throws(IOException::class)
    fun open(request: Request): Response {
        // Fail before attaching credentials or opening the first exchange.
        // The network interceptor repeats this check for redirect exchanges.
        requireTransportBoundary(request.url)
        return httpClient.newCall(authenticated(request)).execute()
    }

    fun executeOrThrow(request: Request): ApiResponse {
        var response = execute(request)
        if (response.statusCode == 401 && accessToken != null && !request.url.encodedPath.endsWith(BookOrbitContract.refreshPath)) {
            val refreshResponse = execute(refreshRequest())
            if (refreshResponse.isSuccessful) {
                val token = parseAccessToken(refreshResponse.body)
                setSession(token, refreshResponse.setCookie ?: refreshCookie)
                response = execute(request)
            }
        }
        if (!response.isSuccessful) throw BookOrbitHttpException(response.statusCode, response.body)
        return response
    }

    private fun request(path: String): Request.Builder = Request.Builder().url(baseUrl.newBuilder().addPathSegments("api/v1").addPathSegments(path.trimStart('/')).build()).header("Accept", "application/json")

    private fun requireTransportBoundary(url: HttpUrl) {
        require(url.scheme == "https" || url.scheme == "http") {
            "BookOrbit requires HTTPS or an explicitly confirmed LAN HTTP host"
        }
        if (url.scheme != "http") return
        require(isLanHost(url.host)) {
            "BookOrbit cleartext HTTP is limited to a LAN host"
        }
        require(isCleartextConfirmationBound(url, httpConfirmation)) {
            "BookOrbit HTTP requires explicit confirmation for this host"
        }
        require(cleartextTransportPolicy.isPermitted(url.host)) {
            "Android network policy denies cleartext HTTP for this host; use HTTPS"
        }
    }

    private fun authenticated(request: Request): Request = request.newBuilder().apply {
        accessToken?.takeIf(String::isNotBlank)?.let { header("Authorization", "Bearer $it") }
        refreshCookie?.takeIf(String::isNotBlank)?.let { header("Cookie", it) }
    }.build()

    private fun buildHttpClient(fingerprint: String?): OkHttpClient {
        if (fingerprint.isNullOrBlank()) return OkHttpClient()
        val trustManager = CertificatePinning.trustManager(fingerprint)
        return OkHttpClient.Builder()
            .sslSocketFactory(CertificatePinning.sslContext(trustManager).socketFactory, trustManager)
            .build()
    }

    companion object {
        /** Create a client only from the exact persisted profile boundary. */
        fun fromPersistedProfile(profile: ServerProfileRecord): BookOrbitClient? {
            val url = runCatching { profile.baseUrl.trimEnd('/').toHttpUrl() }.getOrNull() ?: return null
            if (url.scheme != "https" && url.scheme != "http") return null
            val confirmation = confirmationFromPersistedProfile(profile)
            if (url.scheme == "http" && !isCleartextConfirmationBound(profile.baseUrl, confirmation)) return null
            return BookOrbitClient(
                serverUrl = profile.baseUrl,
                certificateSha256 = profile.certificateSha256,
                cleartextHttpConfirmation = confirmation,
            )
        }

        fun confirmationFromPersistedProfile(profile: ServerProfileRecord): CleartextHttpConfirmation? {
            val host = profile.cleartextHttpConfirmedHost ?: return null
            val port = profile.cleartextHttpConfirmedPort ?: return null
            if ((profile.cleartextHttpConfirmedAt ?: 0L) <= 0L) return null
            return runCatching { CleartextHttpConfirmation(host, port) }.getOrNull()
        }

        fun isCleartextConfirmationBound(serverUrl: String, confirmation: CleartextHttpConfirmation?): Boolean {
            if (confirmation == null) return false
            val url = runCatching { serverUrl.trimEnd('/').toHttpUrl() }.getOrNull() ?: return false
            return isCleartextConfirmationBound(url, confirmation)
        }

        private fun isCleartextConfirmationBound(url: HttpUrl, confirmation: CleartextHttpConfirmation?): Boolean {
            if (confirmation == null) return false
            return url.scheme == "http" && isLanHost(url.host) &&
                confirmation.host == url.host && confirmation.port == url.port
        }

        private fun isLanHost(host: String): Boolean {
            if (host == "localhost" || host.endsWith(".local")) return true
            val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return false
            return address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress ||
                (address is Inet6Address && host.substringBefore('%').lowercase().let { it.startsWith("fc") || it.startsWith("fd") })
        }
    }

    /**
     * Decode the v2.5.0 refresh response's required `accessToken` field.
     *
     * The server may extend its response with additional fields (for example
     * `tokenType`), which are deliberately ignored. This does not introduce
     * alternate keys or fallback fields: `accessToken` remains the sole
     * required response field.
     */
    private fun parseAccessToken(body: String): String {
        return AccessTokenJsonParser(body).parse()
    }
}

/**
 * Small JSON parser for the refresh response. It validates the complete JSON
 * shape while deliberately ignoring unknown fields, preserving the existing
 * contract's forward-compatible response behavior without accepting aliases.
 */
private class AccessTokenJsonParser(private val source: String) {
    private var index = 0

    fun parse(): String {
        skipWhitespace()
        expect('{')
        skipWhitespace()
        if (consume('}')) fail("BookOrbit refresh response is missing accessToken")

        var token: String? = null
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            if (key == "accessToken") {
                if (token != null) fail("BookOrbit refresh response contains a duplicate accessToken field")
                token = parseString()
                if (token!!.isEmpty()) fail("BookOrbit refresh response contains an empty accessToken")
                if (token!!.any { it.code !in 0x21..0x7e }) {
                    fail("BookOrbit refresh response accessToken contains a character unsafe for an HTTP header")
                }
            } else {
                skipValue()
            }
            skipWhitespace()
            when {
                consume('}') -> break
                consume(',') -> {
                    skipWhitespace()
                    if (peek() == '}') fail("BookOrbit refresh response contains a trailing comma")
                }
                else -> fail("BookOrbit refresh response contains invalid trailing input")
            }
        }

        skipWhitespace()
        if (index != source.length) fail("BookOrbit refresh response contains invalid trailing input")
        return token ?: fail("BookOrbit refresh response is missing accessToken")
    }

    private fun parseString(): String {
        expect('"')
        val value = StringBuilder()
        while (index < source.length) {
            when (val character = source[index++]) {
                '"' -> return value.toString()
                '\\' -> parseEscape(value)
                else -> {
                    if (character.code < 0x20) fail("BookOrbit refresh response contains an unescaped control character")
                    value.append(character)
                }
            }
        }
        fail("BookOrbit refresh response contains an unterminated string")
    }

    private fun parseEscape(value: StringBuilder) {
        if (index >= source.length) fail("BookOrbit refresh response contains an incomplete escape")
        when (val escaped = source[index++]) {
            '"', '\\', '/' -> value.append(escaped)
            'b' -> value.append('\b')
            'f' -> value.append('\u000c')
            'n' -> value.append('\n')
            'r' -> value.append('\r')
            't' -> value.append('\t')
            'u' -> {
                var codePoint = 0
                repeat(4) {
                    if (index >= source.length) fail("BookOrbit refresh response contains an incomplete unicode escape")
                    codePoint = (codePoint shl 4) or hexValue(source[index++])
                }
                value.append(codePoint.toChar())
            }
            else -> fail("BookOrbit refresh response contains an invalid escape: $escaped")
        }
    }

    private fun skipValue() {
        when (peek()) {
            '"' -> parseString()
            '{' -> skipObject()
            '[' -> skipArray()
            't' -> consumeLiteral("true")
            'f' -> consumeLiteral("false")
            'n' -> consumeLiteral("null")
            '-', in '0'..'9' -> skipNumber()
            else -> fail("BookOrbit refresh response contains an invalid JSON value")
        }
    }

    private fun skipObject() {
        expect('{')
        skipWhitespace()
        if (consume('}')) return
        while (true) {
            skipWhitespace()
            parseString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            skipValue()
            skipWhitespace()
            when {
                consume('}') -> return
                consume(',') -> {
                    skipWhitespace()
                    if (peek() == '}') fail("BookOrbit refresh response contains a trailing comma")
                }
                else -> fail("BookOrbit refresh response contains invalid object syntax")
            }
        }
    }

    private fun skipArray() {
        expect('[')
        skipWhitespace()
        if (consume(']')) return
        while (true) {
            skipWhitespace()
            skipValue()
            skipWhitespace()
            when {
                consume(']') -> return
                consume(',') -> {
                    skipWhitespace()
                    if (peek() == ']') fail("BookOrbit refresh response contains a trailing comma")
                }
                else -> fail("BookOrbit refresh response contains invalid array syntax")
            }
        }
    }

    private fun skipNumber() {
        consume('-')
        when {
            consume('0') -> Unit
            peek() in '1'..'9' -> while (peek() in '0'..'9') index++
            else -> fail("BookOrbit refresh response contains an invalid number")
        }
        if (consume('.')) {
            if (peek() !in '0'..'9') fail("BookOrbit refresh response contains an invalid number")
            while (peek() in '0'..'9') index++
        }
        if (peek() == 'e' || peek() == 'E') {
            index++
            if (peek() == '+' || peek() == '-') index++
            if (peek() !in '0'..'9') fail("BookOrbit refresh response contains an invalid number")
            while (peek() in '0'..'9') index++
        }
    }

    private fun consumeLiteral(literal: String) {
        if (!source.startsWith(literal, index)) fail("BookOrbit refresh response contains an invalid JSON literal")
        index += literal.length
    }

    private fun skipWhitespace() {
        while (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r') index++
    }

    private fun hexValue(character: Char): Int = when (character) {
        in '0'..'9' -> character - '0'
        in 'a'..'f' -> character - 'a' + 10
        in 'A'..'F' -> character - 'A' + 10
        else -> fail("BookOrbit refresh response contains an invalid unicode escape")
    }

    private fun peek(): Char? = source.getOrNull(index)

    private fun consume(expected: Char): Boolean {
        if (peek() != expected) return false
        index++
        return true
    }

    private fun expect(expected: Char) {
        if (!consume(expected)) fail("BookOrbit refresh response expected '$expected'")
    }

    private fun fail(message: String): Nothing = throw IllegalArgumentException(message)
}

data class CleartextHttpConfirmation(val host: String, val port: Int) {
    init {
        require(host.isNotBlank()) { "HTTP confirmation host must not be blank" }
        require(port in 1..65535) { "HTTP confirmation port is invalid" }
    }
}

data class ApiResponse(
    val statusCode: Int,
    val headers: okhttp3.Headers,
    val body: String,
    val setCookie: String?,
) {
    val isSuccessful: Boolean get() = statusCode in 200..299
}

data class ByteApiResponse(
    val statusCode: Int,
    val headers: okhttp3.Headers,
    val body: ByteArray,
    val setCookie: String?,
) {
    val isSuccessful: Boolean get() = statusCode in 200..299
}

class BookOrbitHttpException(val statusCode: Int, override val message: String) : IOException("BookOrbit HTTP $statusCode: $message")
