package com.papria.reader.core.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class WifiTransferChunkBoundaryTest {
    @Test
    fun acceptsInclusiveChunkSizeAndFileEndBoundaries() {
        data class Case(
            val chunkIndex: Long,
            val start: Long,
            val end: Long,
            val total: Long,
        )

        val chunk = WifiTransferServer.CHUNK_BYTES
        val cases = listOf(
            Case(chunkIndex = 0, start = 0, end = 0, total = 1),
            Case(chunkIndex = 0, start = 0, end = chunk - 1, total = chunk),
            Case(chunkIndex = 0, start = 0, end = chunk - 1, total = chunk + 1),
            Case(chunkIndex = 1, start = chunk, end = chunk, total = chunk + 1),
        )

        cases.forEach { case ->
            val range = validateWifiChunkRange(
                chunkIndex = case.chunkIndex,
                value = "bytes ${case.start}-${case.end}/${case.total}",
                expectedStart = case.start,
                expectedTotal = case.total,
                contentLength = case.end - case.start + 1,
            )

            assertEquals(case.start, range.start)
            assertEquals(case.end, range.end)
            assertEquals(case.total, range.total)
            assertEquals(case.end - case.start + 1, range.length)
        }
    }

    @Test
    fun rejectsAChunkLargerThanEightMiBEvenWhenItsHeadersAgree() {
        val oversizedLength = WifiTransferServer.CHUNK_BYTES + 1

        assertThrows(IllegalArgumentException::class.java) {
            validateWifiChunkRange(
                chunkIndex = 0,
                value = "bytes 0-${oversizedLength - 1}/${oversizedLength * 2}",
                expectedStart = 0,
                expectedTotal = oversizedLength * 2,
                contentLength = oversizedLength,
            )
        }
    }

    @Test
    fun rejectsEveryNonCanonicalContentRangeEncoding() {
        val invalidValues = listOf(
            "",
            "bytes",
            "Bytes 0-0/1",
            "BYTES 0-0/1",
            "bytes=0-0/1",
            "bytes 0 -0/1",
            "bytes 0- 0/1",
            "bytes 0-0 /1",
            "bytes 0-0/ 1",
            " bytes 0-0/1",
            "bytes 0-0/1 ",
            "bytes 0-0/*",
            "bytes -1-0/1",
            "bytes +0-0/1",
            "bytes 0-0/+1",
            "bytes 0-0/1, bytes 1-1/2",
            "bytes 9223372036854775808-9223372036854775808/9223372036854775808",
        )

        invalidValues.forEach { value ->
            assertThrows("must reject: $value", IllegalArgumentException::class.java) {
                validateWifiChunkRange(0, value, 0, 1, 1)
            }
        }
    }

    @Test
    fun rejectsContradictoryRangeMetadataAndNumericExtremes() {
        data class Case(
            val chunkIndex: Long,
            val value: String,
            val expectedStart: Long,
            val expectedTotal: Long,
            val contentLength: Long,
        )

        val chunk = WifiTransferServer.CHUNK_BYTES
        val invalidCases = listOf(
            Case(0, "bytes 0-0/1", 1, 1, 1),
            Case(0, "bytes 0-0/1", 0, 2, 1),
            Case(0, "bytes 0-0/1", 0, 1, 0),
            Case(0, "bytes 0-0/1", 0, 1, -1),
            Case(-1, "bytes 0-0/1", 0, 1, 1),
            Case(Long.MAX_VALUE, "bytes 0-0/1", 0, 1, 1),
            Case(0, "bytes 0-1/1", 0, 1, 2),
            Case(0, "bytes 1-1/2", 1, 2, 1),
            Case(1, "bytes $chunk-$chunk/${chunk + 1}", chunk, chunk + 1, 2),
        )

        invalidCases.forEach { case ->
            assertThrows("must reject: $case", IllegalArgumentException::class.java) {
                validateWifiChunkRange(
                    case.chunkIndex,
                    case.value,
                    case.expectedStart,
                    case.expectedTotal,
                    case.contentLength,
                )
            }
        }
    }
}
