package com.papria.reader.core.transfer

import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class WifiTransferServerTest {
    @Test
    fun acceptsAlignedChunkIndexAndContentRange() {
        validateChunk(
            chunkIndex = 1,
            value = "bytes 8388608-16777215/25165824",
            expectedStart = 8388608,
            expectedTotal = 25165824,
            contentLength = 8388608,
        )
    }

    @Test
    fun rejectsChunkIndexThatDoesNotMatchContentRangeStart() {
        assertRejected {
            validateChunk(
                chunkIndex = 0,
                value = "bytes 8388608-16777215/25165824",
                expectedStart = 8388608,
                expectedTotal = 25165824,
                contentLength = 8388608,
            )
        }
    }

    @Test
    fun rejectsUnalignedContentRangeStart() {
        assertRejected {
            validateChunk(
                chunkIndex = 0,
                value = "bytes 1-8388608/25165824",
                expectedStart = 1,
                expectedTotal = 25165824,
                contentLength = 8388608,
            )
        }
    }

    @Test
    fun rejectsContentRangeEndAtTotal() {
        assertRejected {
            validateChunk(
                chunkIndex = 0,
                value = "bytes 0-25165824/25165824",
                expectedStart = 0,
                expectedTotal = 25165824,
                contentLength = 25165825,
            )
        }
    }

    @Test
    fun rejectsContentRangeEndBeforeStart() {
        assertRejected {
            validateChunk(
                chunkIndex = 0,
                value = "bytes 8388608-8388607/25165824",
                expectedStart = 8388608,
                expectedTotal = 25165824,
                contentLength = 0,
            )
        }
    }

    @Test
    fun rejectsContentLengthThatDoesNotMatchContentRange() {
        assertRejected {
            validateChunk(
                chunkIndex = 0,
                value = "bytes 0-8388607/25165824",
                expectedStart = 0,
                expectedTotal = 25165824,
                contentLength = 8388607,
            )
        }
    }

    @Test
    fun reconcilesDatabaseAheadOfPartFileToActualLength() {
        withPartFile(length = 0) { part ->
            val reconciliation = reconcileWifiUploadPartFile(
                temp = part,
                persistedReceivedBytes = WifiTransferServer.CHUNK_BYTES,
                declaredSizeBytes = WifiTransferServer.CHUNK_BYTES * 2,
            )

            assertEquals(0L, reconciliation.receivedBytes)
            assertTrue(reconciliation.shouldUpdateDatabase)
            assertFalse(reconciliation.shouldTruncateFile)
            assertEquals(0L, part.length())
        }
    }

    @Test
    fun reconcilesDatabaseBehindCompletedPartFileToActualLength() {
        val reconciliation = reconcileWifiUploadProgress(
            persistedReceivedBytes = WifiTransferServer.CHUNK_BYTES,
            actualFileLength = WifiTransferServer.CHUNK_BYTES * 2,
            declaredSizeBytes = WifiTransferServer.CHUNK_BYTES * 2,
        )

        assertEquals(WifiTransferServer.CHUNK_BYTES * 2, reconciliation.receivedBytes)
        assertTrue(reconciliation.shouldUpdateDatabase)
        assertFalse(reconciliation.shouldTruncateFile)
    }

    @Test
    fun discardsPartialTrailingChunkBeforeResuming() {
        val completedChunk = WifiTransferServer.CHUNK_BYTES
        withPartFile(length = completedChunk + 4_096) { part ->
            val reconciliation = reconcileWifiUploadPartFile(
                temp = part,
                persistedReceivedBytes = completedChunk + 4_096,
                declaredSizeBytes = WifiTransferServer.CHUNK_BYTES * 3,
            )

            assertEquals(completedChunk, reconciliation.receivedBytes)
            assertTrue(reconciliation.shouldUpdateDatabase)
            assertTrue(reconciliation.shouldTruncateFile)
            assertEquals(completedChunk, part.length())
        }
    }

    @Test
    fun permitsExactFinalChunkEvenWhenItIsNotChunkAligned() {
        val declaredSize = WifiTransferServer.CHUNK_BYTES + 1
        val reconciliation = reconcileWifiUploadProgress(
            persistedReceivedBytes = declaredSize,
            actualFileLength = declaredSize,
            declaredSizeBytes = declaredSize,
        )

        assertEquals(declaredSize, reconciliation.receivedBytes)
        assertFalse(reconciliation.shouldUpdateDatabase)
        assertFalse(reconciliation.shouldTruncateFile)
    }

    @Test
    fun rejectsPartFileLongerThanDeclaredSize() {
        assertRejected {
            reconcileWifiUploadProgress(
                persistedReceivedBytes = WifiTransferServer.CHUNK_BYTES,
                actualFileLength = WifiTransferServer.CHUNK_BYTES + 1,
                declaredSizeBytes = WifiTransferServer.CHUNK_BYTES,
            )
        }
    }

    @Test
    fun uploadIdsRequireTheirIndependentResumeToken() {
        val token = "persisted-upload-resume-token"
        val hash = java.security.MessageDigest.getInstance("SHA-256")
            .digest(token.toByteArray())
            .joinToString("") { "%02x".format(it) }

        assertTrue(transferBelongsToResumeToken(hash, token))
        assertFalse(transferBelongsToResumeToken(hash, "other-upload-resume-token"))
        assertFalse(transferBelongsToResumeToken(hash, null))
    }

    private fun validateChunk(
        chunkIndex: Long,
        value: String,
        expectedStart: Long,
        expectedTotal: Long,
        contentLength: Long,
    ) {
        validateWifiChunkRange(
            chunkIndex,
            value,
            expectedStart,
            expectedTotal,
            contentLength,
        )
    }

    private fun assertRejected(block: () -> Unit) {
        try {
            block()
            fail("expected invalid chunk request to be rejected")
        } catch (_: IllegalArgumentException) {
            // Expected.
        }
    }

    private fun withPartFile(length: Long, block: (File) -> Unit) {
        val part = File.createTempFile("papria-wifi-upload", ".part")
        try {
            RandomAccessFile(part, "rw").use { it.setLength(length) }
            block(part)
        } finally {
            part.delete()
        }
    }
}
