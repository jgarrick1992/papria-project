package com.papria.reader.core.bookorbit

import com.papria.reader.core.model.AudioProgress
import com.papria.reader.core.model.FileProgress
import okhttp3.Request
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BookOrbitRequestJsonBoundaryTest {
    private val client = BookOrbitClient("https://books.example.test/root")

    @Test
    fun loginJsonEscapesControlCharactersWithoutRenamingKeys() {
        val cases = listOf(
            ("" to "") to "{\"username\":\"\",\"password\":\"\"}",
            ("a\"b" to "c\\d") to "{\"username\":\"a\\\"b\",\"password\":\"c\\\\d\"}",
            ("line\nfeed" to "tab\treturn\r") to
                "{\"username\":\"line\\nfeed\",\"password\":\"tab\\treturn\\r\"}",
            ("nul\u0000" to "back\bform\u000c") to
                "{\"username\":\"nul\\u0000\",\"password\":\"back\\bform\\f\"}",
        )

        cases.forEach { (credentials, expected) ->
            assertEquals(expected, body(client.loginRequest(credentials.first, credentials.second)))
        }
    }

    @Test
    fun queryJsonOmitsOnlyNullBlankOrWhitespaceQueries() {
        val omittedQueries = listOf<String?>(null, "", " ", "\t\r\n")
        omittedQueries.forEach { query ->
            val json = body(client.queryBooksRequest(0, Int.MAX_VALUE, query))
            assertEquals(
                "{\"sort\":[{\"field\":\"title\",\"dir\":\"asc\"}]," +
                    "\"pagination\":{\"page\":0,\"size\":${Int.MAX_VALUE}}," +
                    "\"collapseSeries\":false}",
                json,
            )
            assertFalse(json.contains("\"q\""))
        }

        val significant = body(client.queryBooksRequest(0, 1, "  title\"\\\n  "))
        assertTrue(significant.endsWith(",\"q\":\"  title\\\"\\\\\\n  \"}"))
    }

    @Test
    fun fileProgressJsonUsesExactNullableFieldMatrixAndPreservesZeroExtremes() {
        val minimal = body(client.saveProgressRequest(1, FileProgress(percentage = 0.0)))
        assertEquals("{\"percentage\":0.0}", minimal)

        val complete = body(
            client.saveProgressRequest(
                Long.MAX_VALUE,
                FileProgress(
                    percentage = 100.0,
                    cfi = "",
                    pageNumber = Int.MAX_VALUE,
                    positionSeconds = 0.0,
                    koboLocationSource = "source\n",
                    koboLocationType = "type\"",
                    koboLocationValue = "value\\",
                    koboContentSourceProgressPercent = Double.MIN_VALUE,
                    koreaderProgress = "",
                ),
            ),
        )
        assertEquals(
            "{\"percentage\":100.0,\"cfi\":\"\",\"pageNumber\":${Int.MAX_VALUE}," +
                "\"positionSeconds\":0.0,\"koboLocationSource\":\"source\\n\"," +
                "\"koboLocationType\":\"type\\\"\",\"koboLocationValue\":\"value\\\\\"," +
                "\"koboContentSourceProgressPercent\":${Double.MIN_VALUE},\"koreaderProgress\":\"\"}",
            complete,
        )
    }

    @Test
    fun audioProgressUsesExactPatchContractAtNumericBoundaries() {
        val request = client.saveAudioProgressRequest(
            Long.MAX_VALUE,
            AudioProgress(
                percentage = 0.0,
                currentFileId = Long.MAX_VALUE,
                positionSeconds = Double.MIN_VALUE,
            ),
        )

        assertEquals("PATCH", request.method)
        assertEquals(
            "https://books.example.test/root/api/v1/books/${Long.MAX_VALUE}/audio-progress",
            request.url.toString(),
        )
        assertEquals(
            "{\"percentage\":0.0,\"currentFileId\":${Long.MAX_VALUE}," +
                "\"positionSeconds\":${Double.MIN_VALUE}}",
            body(request),
        )
    }

    @Test
    fun requestPathsPreserveZeroAndMaximumIdentifierBoundariesWithoutAliases() {
        val cases = listOf(
            client.bookRequest(Long.MAX_VALUE) to "/root/api/v1/books/${Long.MAX_VALUE}",
            client.coverRequest(0) to "/root/api/v1/books/0/cover",
            client.serveFileRequest(0, 0) to "/root/api/v1/books/files/0/serve",
            client.getProgressRequest(Long.MAX_VALUE) to "/root/api/v1/books/files/${Long.MAX_VALUE}/progress",
        )

        cases.forEach { (request, expectedPath) ->
            assertEquals(expectedPath, request.url.encodedPath)
        }
        assertEquals("bytes=0-", cases[2].first.header("Range"))
    }

    private fun body(request: Request): String = Buffer().use { buffer ->
        requireNotNull(request.body).writeTo(buffer)
        buffer.readUtf8()
    }
}
