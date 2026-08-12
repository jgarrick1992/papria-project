package com.papria.reader.core.bookorbit

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class CleartextTransportBoundaryTest {
    @Test
    fun clientRejectsMalformedUnsupportedAndOutOfRangeServerUrlsAtConstruction() {
        val invalidUrls = listOf(
            "",
            " ",
            "localhost:8080",
            "ftp://localhost:8080",
            "http://",
            "http://localhost:0",
            "http://localhost:65536",
            "https://localhost:99999",
        )

        invalidUrls.forEach { url ->
            assertThrows("must reject server URL: $url", IllegalArgumentException::class.java) {
                BookOrbitClient(url, httpClient = OkHttpClient())
            }
        }
    }

    @Test
    fun confirmationRejectsBlankHostsAndEveryOutOfRangePort() {
        listOf("", " ", "\t\r\n").forEach { host ->
            assertThrows(IllegalArgumentException::class.java) {
                CleartextHttpConfirmation(host, 8080)
            }
        }
        listOf(Int.MIN_VALUE, -1, 0, 65_536, Int.MAX_VALUE).forEach { port ->
            assertThrows(IllegalArgumentException::class.java) {
                CleartextHttpConfirmation("localhost", port)
            }
        }

        assertEquals(1, CleartextHttpConfirmation("localhost", 1).port)
        assertEquals(65_535, CleartextHttpConfirmation("localhost", 65_535).port)
    }

    @Test
    fun confirmationBindingUsesTheExactLanHostPortAndHttpScheme() {
        data class Case(
            val url: String,
            val confirmation: CleartextHttpConfirmation?,
            val expected: Boolean,
        )

        val cases = listOf(
            Case("http://localhost:1", CleartextHttpConfirmation("localhost", 1), true),
            Case("http://127.0.0.1:65535", CleartextHttpConfirmation("127.0.0.1", 65_535), true),
            Case("http://10.0.0.1", CleartextHttpConfirmation("10.0.0.1", 80), true),
            Case("http://172.16.0.1", CleartextHttpConfirmation("172.16.0.1", 80), true),
            Case("http://192.168.1.1", CleartextHttpConfirmation("192.168.1.1", 80), true),
            Case("http://[::1]:8080", CleartextHttpConfirmation("::1", 8080), true),
            Case("http://[fd00::1]:8080", CleartextHttpConfirmation("fd00::1", 8080), true),
            Case("http://localhost:8080", null, false),
            Case("https://localhost:8080", CleartextHttpConfirmation("localhost", 8080), false),
            Case("http://localhost:8080", CleartextHttpConfirmation("localhost", 8081), false),
            Case("http://localhost:8080", CleartextHttpConfirmation("LOCALHOST", 8080), false),
            Case("http://localhost.:8080", CleartextHttpConfirmation("localhost", 8080), false),
            Case("http://8.8.8.8:8080", CleartextHttpConfirmation("8.8.8.8", 8080), false),
        )

        cases.forEach { case ->
            assertEquals(
                "binding mismatch for ${case.url} and ${case.confirmation}",
                case.expected,
                BookOrbitClient.isCleartextConfirmationBound(case.url, case.confirmation),
            )
        }
    }

    @Test
    fun cleartextPublicIpIsRejectedBeforeAnyNetworkExchange() {
        val client = BookOrbitClient(
            serverUrl = "http://8.8.8.8:8080",
            httpClient = OkHttpClient(),
            cleartextHttpConfirmation = CleartextHttpConfirmation("8.8.8.8", 8080),
            cleartextTransportPolicy = CleartextTransportPolicy { true },
        )

        try {
            client.execute(client.appInfoRequest())
            throw AssertionError("public cleartext IP was accepted")
        } catch (error: IllegalArgumentException) {
            assertTrue(error.message!!.contains("limited to a LAN host"))
        }
    }

    @Test
    fun sameOriginRedirectRechecksAndRetainsTheConfirmedBoundary() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(307).addHeader("Location", "/redirected"))
            server.enqueue(MockResponse().setResponseCode(200).setBody("ok"))
            server.start()
            val client = localClient(server)

            val response = client.execute(client.appInfoRequest())

            assertEquals(200, response.statusCode)
            assertEquals(2, server.requestCount)
            assertEquals("/api/v1/app-info", server.takeRequest().path)
            assertEquals("/redirected", server.takeRequest().path)
        }
    }

    @Test
    fun hostAliasCannotReuseAConfirmationEvenWhenItWouldReachTheSameServer() {
        MockWebServer().use { server ->
            server.start()
            val client = localClient(server)
            val aliasHost = if (server.url("/").host == "localhost") "127.0.0.1" else "localhost"
            val request = Request.Builder()
                .url("http://$aliasHost:${server.port}/api/v1/app-info")
                .build()

            val error = runCatching { client.open(request) }.exceptionOrNull()

            assertTrue(error is IllegalArgumentException)
            assertTrue(requireNotNull(error).message!!.contains("explicit confirmation"))
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun deniedPlatformPolicyIsFailClosedAndDoesNotOpenASocket() {
        MockWebServer().use { server ->
            server.start()
            val checkedHosts = mutableListOf<String>()
            val client = BookOrbitClient(
                serverUrl = server.url("/").toString(),
                httpClient = OkHttpClient(),
                cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, server.port),
                cleartextTransportPolicy = CleartextTransportPolicy { host ->
                    checkedHosts += host
                    false
                },
            )

            val error = runCatching { client.execute(client.appInfoRequest()) }.exceptionOrNull()

            assertTrue(error is IllegalArgumentException)
            assertEquals(listOf(server.url("/").host), checkedHosts)
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun httpsNeedsNoCleartextConfirmationOrPolicyException() {
        val checkedHosts = mutableListOf<String>()
        val client = BookOrbitClient(
            serverUrl = "https://books.example.test:8443",
            httpClient = OkHttpClient(),
            cleartextTransportPolicy = CleartextTransportPolicy { host ->
                checkedHosts += host
                false
            },
        )

        assertFalse(client.isCleartextHttp())
        assertEquals("books.example.test", client.host())
        assertEquals(8443, client.port())
        assertTrue(checkedHosts.isEmpty())
    }

    private fun localClient(server: MockWebServer): BookOrbitClient = BookOrbitClient(
        serverUrl = server.url("/").toString(),
        httpClient = OkHttpClient(),
        cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, server.port),
        cleartextTransportPolicy = CleartextTransportPolicy { true },
    )
}
