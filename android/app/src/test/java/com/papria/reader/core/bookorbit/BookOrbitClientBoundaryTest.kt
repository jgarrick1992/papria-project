package com.papria.reader.core.bookorbit

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Error and resource-boundary coverage for the client transport. These tests
 * intentionally exercise the public API through MockWebServer, so the strict
 * refresh parser and body-size guards cannot be bypassed by implementation
 * details.
 */
class BookOrbitClientBoundaryTest {
    @Test
    fun refreshRejectsMalformedOrAmbiguousTokensWithoutReplayingTheOriginalRequest() {
        val invalidBodies = listOf(
            "",
            "null",
            "[]",
            "{}",
            "{\"AccessToken\":\"fresh\"}",
            "{\"accessToken\":\"\"}",
            "{\"accessToken\":7}",
            "{\"accessToken\":null}",
            "{\"accessToken\":true}",
            "{\"accessToken\":\"first\",\"accessToken\":\"second\"}",
            "{\"accessToken\":\"fresh\",}",
            "{,\"accessToken\":\"fresh\"}",
            "{\"accessToken\":\"fresh\"} trailing",
            "{\"accessToken\":\"\\u00GG\"}",
            "{\"accessToken\":\"\\x20\"}",
            "{\"accessToken\":\"unterminated}",
            "{\"accessToken\":\"line\nbreak\"}",
            "{\"accessToken\" \"missing-colon\"}",
            "{\"accessToken\":\"fresh\" \"missing-comma\":true}",
        )

        invalidBodies.forEach { invalidBody ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
                server.enqueue(MockResponse().setResponseCode(200).setBody(invalidBody))
                server.start()
                val client = localClient(server)
                client.setSession("expired-token", "refresh_token=old")

                val error = runCatching { client.executeOrThrow(client.appInfoRequest()) }.exceptionOrNull()

                assertTrue("payload must fail closed: $invalidBody", error is IllegalArgumentException)
                assertEquals("expired-token", client.sessionAccessToken())
                assertEquals("refresh_token=old", client.sessionRefreshCookie())
                assertEquals("a rejected refresh response must not replay the request", 2, server.requestCount)
            }
        }
    }

    @Test
    fun refreshAcceptsOnlyTheExactObjectWhileDecodingSafeJsonStringEscapes() {
        val validBodies = listOf(
            "{\"accessToken\":\"plain\"}" to "plain",
            " \t\r\n{ \"accessToken\" : \"spaced\" } \n" to "spaced",
            "{\"accessToken\":\"quote\\\"slash\\\\solidus\\/\"}" to "quote\"slash\\solidus/",
        )

        validBodies.forEach { (body, expectedToken) ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
                server.enqueue(MockResponse().setResponseCode(200).setBody(body))
                server.enqueue(MockResponse().setResponseCode(200).setBody("{\"version\":\"v2.5.0\"}"))
                server.start()
                val client = localClient(server)
                client.setSession("expired-token", "refresh_token=old")

                val response = client.executeOrThrow(client.appInfoRequest())

                assertEquals("valid JSON case failed: $body", 200, response.statusCode)
                assertEquals("valid JSON case failed: $body", expectedToken, client.sessionAccessToken())
                assertEquals(3, server.requestCount)
            }
        }
    }

    @Test
    fun refreshRejectsEveryEscapedAsciiControlBoundaryWithoutChangingSessionOrReplaying() {
        val controlEscapes = listOf(
            "\\u0000",
            "\\u0001",
            "\\b",
            "\\t",
            "\\n",
            "\\f",
            "\\r",
            "\\u001e",
            "\\u001f",
            "\\u007f",
        )

        controlEscapes.forEach { controlEscape ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
                server.enqueue(
                    MockResponse()
                        .setResponseCode(200)
                        .setBody("{\"accessToken\":\"prefix${controlEscape}suffix\"}"),
                )
                server.start()
                val client = localClient(server)
                client.setSession("expired-token", "refresh_token=old")

                val error = runCatching { client.executeOrThrow(client.appInfoRequest()) }.exceptionOrNull()

                assertTrue("must reject decoded control escape: $controlEscape", error is IllegalArgumentException)
                assertTrue(requireNotNull(error).message!!.contains("unsafe for an HTTP header"))
                assertEquals("expired-token", client.sessionAccessToken())
                assertEquals("refresh_token=old", client.sessionRefreshCookie())
                assertEquals("rejected token must not replay the original request", 2, server.requestCount)
            }
        }
    }

    @Test
    fun refreshParserRejectsNonAsciiUnicodeBeforeChangingTheSession() {
        val unicodeTokens = listOf(
            "latin-\u00e9" to "latin-\\u00e9",
            "c1-boundary-\u0080" to "c1-boundary-\\u0080",
            "cjk-\u4e2d" to "cjk-\\u4e2d",
            "surrogate-\uD83D\uDE00" to "surrogate-\\uD83D\\uDE00",
        )

        unicodeTokens.forEach { (_, encodedToken) ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
                server.enqueue(
                    MockResponse()
                        .setResponseCode(200)
                        .setBody("{\"accessToken\":\"$encodedToken\"}"),
                )
                server.start()
                val client = localClient(server)
                client.setSession("expired-token", "refresh_token=old")

                val error = runCatching { client.executeOrThrow(client.appInfoRequest()) }.exceptionOrNull()

                assertTrue(error is IllegalArgumentException)
                assertTrue(requireNotNull(error).message!!.contains("unsafe for an HTTP header"))
                assertEquals("expired-token", client.sessionAccessToken())
                assertEquals("refresh_token=old", client.sessionRefreshCookie())
                assertEquals("rejected token must not replay the original request", 2, server.requestCount)
            }
        }
    }

    @Test
    fun unsuccessfulRefreshNeverParsesOrReplaysItsBody() {
        listOf(400, 401, 403, 429, 500).forEach { refreshStatus ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(401).setBody("expired"))
                server.enqueue(
                    MockResponse()
                        .setResponseCode(refreshStatus)
                        .setBody("{\"accessToken\":\"must-not-be-used\"}"),
                )
                server.start()
                val client = localClient(server)
                client.setSession("expired-token", "refresh_token=old")

                val error = runCatching { client.executeOrThrow(client.appInfoRequest()) }.exceptionOrNull()

                assertTrue("refresh HTTP $refreshStatus must fail", error is BookOrbitHttpException)
                assertEquals(401, (error as BookOrbitHttpException).statusCode)
                assertEquals("expired-token", client.sessionAccessToken())
                assertEquals("refresh_token=old", client.sessionRefreshCookie())
                assertEquals(2, server.requestCount)
            }
        }
    }

    @Test
    fun executeBytesAcceptsTheExactLimitAndRotatesTheRefreshCookie() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse()
                    .setResponseCode(200)
                    .addHeader("Set-Cookie", "refresh_token=rotated; Path=/; HttpOnly")
                    .setBody("data"),
            )
            server.start()
            val client = localClient(server)
            client.setSession("access-token", "refresh_token=old")

            val response = client.executeBytes(client.coverRequest(12), maxBytes = 4)

            assertEquals(200, response.statusCode)
            assertEquals("data", String(response.body, Charsets.UTF_8))
            assertEquals("refresh_token=rotated", client.sessionRefreshCookie())
            val request = server.takeRequest()
            assertEquals("Bearer access-token", request.getHeader("Authorization"))
            assertEquals("refresh_token=old", request.getHeader("Cookie"))
        }
    }

    @Test
    fun executeBytesRejectsADeclaredBodyLargerThanItsLimitBeforeAcceptingIt() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(200).setBody("12345"))
            server.start()
            val client = localClient(server)

            val error = runCatching { client.executeBytes(client.coverRequest(12), maxBytes = 4) }.exceptionOrNull()

            assertNotNull(error)
            assertTrue(error is IllegalArgumentException)
            assertTrue(requireNotNull(error).message!!.contains("binary response is too large"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test
    fun executeBytesRejectsAnOversizedChunkedBodyWithNoDeclaredLength() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(200).setChunkedBody("12345", 1))
            server.start()
            val client = localClient(server)

            val error = runCatching { client.executeBytes(client.coverRequest(12), maxBytes = 4) }.exceptionOrNull()

            assertNotNull(error)
            assertTrue(error is IllegalArgumentException)
            assertTrue(requireNotNull(error).message!!.contains("binary response is too large"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test
    fun executeBytesHandlesZeroAndOneByteLimitsWithoutCrossRequestState() {
        listOf(0L to "", 1L to "x").forEach { (limit, body) ->
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setResponseCode(200).setBody(body))
                server.start()
                val client = localClient(server)

                val response = client.executeBytes(client.coverRequest(0), maxBytes = limit)

                assertEquals(body, response.body.toString(Charsets.UTF_8))
                assertEquals(limit, response.body.size.toLong())
                assertNull(response.setCookie)
                assertEquals(1, server.requestCount)
            }
        }
    }

    private fun localClient(server: MockWebServer): BookOrbitClient = BookOrbitClient(
        serverUrl = server.url("/").toString(),
        httpClient = OkHttpClient(),
        cleartextHttpConfirmation = CleartextHttpConfirmation(server.url("/").host, server.port),
        cleartextTransportPolicy = CleartextTransportPolicy { true },
    )
}
