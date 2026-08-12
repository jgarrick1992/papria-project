package com.papria.reader

import com.papria.reader.core.bookorbit.BookOrbitClient
import com.papria.reader.core.bookorbit.CleartextTransportPolicy
import com.papria.reader.core.bookorbit.CleartextHttpConfirmation
import com.papria.reader.core.local.ServerProfileRecord
import com.papria.reader.core.model.FileProgress
import com.papria.reader.core.security.CertificatePinning
import okio.Buffer
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class BookOrbitContractTest {
    @Test
    fun progressRequestUsesExactBookOrbitKeys() {
        val request = BookOrbitClient("https://books.example.test").saveProgressRequest(17, FileProgress(42.0, cfi = "epubcfi(/6/4)", pageNumber = 3))
        assertEquals("POST", request.method)
        assertEquals("https://books.example.test/api/v1/books/files/17/progress", request.url.toString())
        val body = Buffer().also { request.body!!.writeTo(it) }.readUtf8()
        assertTrue(body.contains("\"percentage\":42.0"))
        assertTrue(body.contains("\"cfi\":\"epubcfi(/6/4)\""))
        assertTrue(body.contains("\"pageNumber\":3"))
    }

    @Test
    fun rangeRequestStartsAtRequestedByte() {
        val request = BookOrbitClient("https://books.example.test").serveFileRequest(9, 1024)
        assertEquals("bytes=1024-", request.header("Range"))
    }

    @Test
    fun queryUsesZeroBasedPaginationAndExactSortDirectionKey() {
        val request = BookOrbitClient("https://books.example.test").queryBooksRequest(0, 20)
        val body = Buffer().also { request.body!!.writeTo(it) }.readUtf8()
        assertTrue(body.contains("\"pagination\":{\"page\":0,\"size\":20}"))
        assertTrue(body.contains("\"dir\":\"asc\""))
    }

    @Test
    fun sessionHeadersAreAddedOnlyWhenExecuting() {
        val client = BookOrbitClient("https://books.example.test")
        client.setSession("access-token", "refresh=opaque")
        assertEquals(null, client.meRequest().header("Authorization"))
        assertEquals(null, client.meRequest().header("Cookie"))
    }

    @Test
    fun certificateFingerprintMustBeExactlySha256Hex() {
        val invalid = listOf("", "00", "zz".repeat(32), "0".repeat(63), "0".repeat(65))
        invalid.forEach { value ->
            try {
                CertificatePinning.trustManager(value)
                throw AssertionError("invalid fingerprint was accepted: $value")
            } catch (_: IllegalArgumentException) {
                // expected fail-closed validation
            }
        }
    }

    @Test
    fun expiredAccessTokenRefreshesOnceAndRetriesOriginalRequest() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
            server.enqueue(
                MockResponse()
                    .setResponseCode(200)
                    .addHeader("Set-Cookie", "refresh_token=rotated; Path=/; HttpOnly")
                    .setBody("{\"accessToken\":\"fresh-token\"}"),
            )
            server.enqueue(MockResponse().setResponseCode(200).setBody("{\"version\":\"v2.5.0\"}"))
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, server.port),
                cleartextTransportPolicy = permittedCleartextTransport(),
            )
            client.setSession("expired-token", "refresh_token=old")

            val response = client.executeOrThrow(client.appInfoRequest())

            assertEquals(200, response.statusCode)
            assertEquals("fresh-token", client.sessionAccessToken())
            assertEquals("refresh_token=rotated", client.sessionRefreshCookie())
            assertEquals(3, server.requestCount)
            val first = server.takeRequest()
            assertEquals("Bearer expired-token", first.getHeader("Authorization"))
            val refresh = server.takeRequest()
            assertEquals("POST", refresh.method)
            assertEquals("refresh_token=old", refresh.getHeader("Cookie"))
            val retry = server.takeRequest()
            assertEquals("Bearer fresh-token", retry.getHeader("Authorization"))
            assertEquals("refresh_token=rotated", retry.getHeader("Cookie"))
        }
    }

    @Test
    fun refreshTokenEscapesAreDecodedWithoutAcceptingAnAlternateKey() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
            server.enqueue(MockResponse().setResponseCode(200).setBody("{\"accessToken\":\"fresh\\u002Dtoken\"}"))
            server.enqueue(MockResponse().setResponseCode(200).setBody("{\"version\":\"v2.5.0\"}"))
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation("localhost", server.port),
                cleartextTransportPolicy = permittedCleartextTransport(),
            )
            client.setSession("expired-token", "refresh_token=old")
            client.executeOrThrow(client.appInfoRequest())
            assertEquals("fresh-token", client.sessionAccessToken())
        }
    }

    @Test
    fun refreshResponseIgnoresUnknownFields() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
            server.enqueue(MockResponse().setResponseCode(200).setBody("{\"accessToken\":\"fresh-token\",\"tokenType\":\"Bearer\",\"unexpected\":true}"))
            server.enqueue(MockResponse().setResponseCode(200).setBody("{\"version\":\"v2.5.0\"}"))
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation("localhost", server.port),
                cleartextTransportPolicy = permittedCleartextTransport(),
            )
            client.setSession("expired-token", "refresh_token=old")
            client.executeOrThrow(client.appInfoRequest())
            assertEquals("fresh-token", client.sessionAccessToken())
        }
    }

    @Test
    fun cleartextHttpRequiresExplicitConfirmationBeforeOpening() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(200).setBody("ok"))
            server.start()
            val client = BookOrbitClient(server.url("/").toString(), httpClient = OkHttpClient())
            try {
                client.execute(client.appInfoRequest())
                throw AssertionError("unconfirmed cleartext HTTP was accepted")
            } catch (error: IllegalArgumentException) {
                assertTrue(error.message!!.contains("explicit confirmation"))
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun cleartextHttpAcceptsOnlyTheConfirmedLanHostAndPort() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(200).setBody("ok"))
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation("localhost", server.port),
                cleartextTransportPolicy = permittedCleartextTransport(),
            )
            assertEquals(200, client.execute(client.appInfoRequest()).statusCode)
            assertEquals(1, server.requestCount)
        }
    }

    @Test
    fun cleartextHttpRejectsAConfirmationForAnotherPort() {
        MockWebServer().use { server ->
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, if (server.port == 65535) 1 else server.port + 1),
            )
            try {
                client.execute(client.appInfoRequest())
                throw AssertionError("confirmation for another port was accepted")
            } catch (error: IllegalArgumentException) {
                assertTrue(error.message!!.contains("explicit confirmation"))
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun cleartextHttpRequiresAndroidPolicyEvenAfterExactUserConfirmation() {
        MockWebServer().use { server ->
            server.start()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, server.port),
                cleartextTransportPolicy = CleartextTransportPolicy { false },
            )

            try {
                client.execute(client.appInfoRequest())
                throw AssertionError("platform-denied cleartext HTTP was accepted")
            } catch (error: IllegalArgumentException) {
                assertTrue(error.message!!.contains("network policy denies"))
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun cleartextRedirectCannotEscapeTheConfirmedLanPort() {
        MockWebServer().use { confirmedServer ->
            MockWebServer().use { redirectTarget ->
                redirectTarget.enqueue(MockResponse().setResponseCode(200).setBody("unexpected"))
                redirectTarget.start()
                confirmedServer.enqueue(
                    MockResponse()
                        .setResponseCode(302)
                        .addHeader("Location", redirectTarget.url("/api/v1/app/info")),
                )
                confirmedServer.start()
                val client = BookOrbitClient(
                    serverUrl = confirmedServer.url("/").toString(),
                    httpClient = OkHttpClient(),
                    cleartextHttpConfirmation = CleartextHttpConfirmation("localhost", confirmedServer.port),
                    cleartextTransportPolicy = permittedCleartextTransport(),
                )

                try {
                    client.execute(client.appInfoRequest())
                    throw AssertionError("cleartext redirect escaped the confirmed port")
                } catch (error: IllegalArgumentException) {
                    assertTrue(error.message!!.contains("explicit confirmation"))
                }
                assertEquals(1, confirmedServer.requestCount)
                assertEquals(0, redirectTarget.requestCount)
            }
        }
    }

    @Test
    fun androidNetworkSecurityConfigDeniesCleartextWithoutDomainExceptions() {
        val manifest = File("src/main/AndroidManifest.xml")
        val config = File("src/main/res/xml/network_security_config.xml")
        assertTrue("Gradle test must run from the Android app module", manifest.isFile && config.isFile)

        val manifestText = manifest.readText()
        assertTrue(manifestText.contains("android:usesCleartextTraffic=\"false\""))
        assertTrue(manifestText.contains("android:networkSecurityConfig=\"@xml/network_security_config\""))

        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(config)
        assertEquals("network-security-config", document.documentElement.nodeName)
        val baseConfigs = document.getElementsByTagName("base-config")
        assertEquals(1, baseConfigs.length)
        assertEquals("false", baseConfigs.item(0).attributes.getNamedItem("cleartextTrafficPermitted").nodeValue)
        assertFalse("A static domain allowlist must not pretend to implement user-selected hosts", document.getElementsByTagName("domain-config").length > 0)
    }

    @Test
    fun persistedHttpConfirmationMustContainTimestampAndMatchCurrentHost() {
        val profile = ServerProfileRecord(
            baseUrl = "http://localhost:8080",
            username = "reader",
            accessToken = null,
            refreshCookie = null,
            serverVersion = "v2.5.0",
            certificateSha256 = null,
            cleartextHttpConfirmedHost = "localhost",
            cleartextHttpConfirmedPort = 8080,
            cleartextHttpConfirmedAt = 1L,
        )
        assertTrue(BookOrbitClient.fromPersistedProfile(profile) != null)
        assertEquals(null, BookOrbitClient.fromPersistedProfile(profile.copy(cleartextHttpConfirmedAt = null)))
        assertEquals(null, BookOrbitClient.fromPersistedProfile(profile.copy(cleartextHttpConfirmedPort = 8081)))
        assertEquals(null, BookOrbitClient.fromPersistedProfile(profile.copy(baseUrl = "http://8.8.8.8:8080")))
    }

    private fun permittedCleartextTransport(): CleartextTransportPolicy = CleartextTransportPolicy { true }
}
