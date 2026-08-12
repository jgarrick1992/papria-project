package com.papria.reader.core.transfer

import java.io.File
import java.security.MessageDigest
import java.util.Locale
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class WifiTransferBoundaryTest {
    @Test
    fun rejectsImpossibleUploadLengthsBeforeAResumeDecision() {
        val invalidLengths = listOf(
            Triple(0L, 0L, 0L),
            Triple(0L, 0L, -1L),
            Triple(0L, -1L, WifiTransferServer.CHUNK_BYTES),
            Triple(0L, 2L, 1L),
            Triple(Long.MIN_VALUE, Long.MAX_VALUE, Long.MAX_VALUE - 1),
        )

        invalidLengths.forEach { (persisted, actual, declared) ->
            assertRejected {
                reconcileWifiUploadProgress(
                    persistedReceivedBytes = persisted,
                    actualFileLength = actual,
                    declaredSizeBytes = declared,
                )
            }
        }
    }

    @Test
    fun resumeProgressUsesOnlyCompletePhysicalChunksOrTheExactFileEnd() {
        data class Case(
            val persisted: Long,
            val actual: Long,
            val declared: Long,
            val received: Long,
            val updateDatabase: Boolean,
            val truncateFile: Boolean,
        )

        val chunk = WifiTransferServer.CHUNK_BYTES
        val cases = listOf(
            Case(0, 0, 1, 0, false, false),
            Case(chunk, 0, chunk * 2, 0, true, false),
            Case(0, 1, chunk * 2, 0, false, true),
            Case(chunk - 1, chunk - 1, chunk * 2, 0, true, true),
            Case(chunk, chunk, chunk * 2, chunk, false, false),
            Case(chunk + 1, chunk + 1, chunk * 2, chunk, true, true),
            Case(Long.MIN_VALUE, chunk * 2 - 1, chunk * 3, chunk, true, true),
            Case(0, 1, 1, 1, true, false),
            Case(chunk, chunk + 1, chunk + 1, chunk + 1, true, false),
            Case(Long.MAX_VALUE, 0, Long.MAX_VALUE, 0, true, false),
        )

        cases.forEach { case ->
            val result = reconcileWifiUploadProgress(case.persisted, case.actual, case.declared)
            assertEquals("received mismatch: $case", case.received, result.receivedBytes)
            assertEquals("database decision mismatch: $case", case.updateDatabase, result.shouldUpdateDatabase)
            assertEquals("truncate decision mismatch: $case", case.truncateFile, result.shouldTruncateFile)
        }
    }

    @Test
    fun missingPartFileIsAnEmptyUploadButDirectoryPathsFailClosed() {
        val parent = createTempDirectory("papria-wifi-boundary-").toFile()
        try {
            val missing = File(parent, "missing.part")
            val result = reconcileWifiUploadPartFile(
                temp = missing,
                persistedReceivedBytes = WifiTransferServer.CHUNK_BYTES,
                declaredSizeBytes = WifiTransferServer.CHUNK_BYTES * 2,
            )
            assertEquals(0L, result.receivedBytes)
            assertTrue(result.shouldUpdateDatabase)
            assertFalse(result.shouldTruncateFile)
            assertFalse(missing.exists())

            assertRejected {
                reconcileWifiUploadPartFile(
                    temp = parent,
                    persistedReceivedBytes = 0,
                    declaredSizeBytes = 1,
                )
            }
        } finally {
            parent.deleteRecursively()
        }
    }

    @Test
    fun resumeCredentialsRequireTheCanonicalPersistedDigest() {
        val token = "resume-credential"
        val canonical = MessageDigest.getInstance("SHA-256")
            .digest(token.toByteArray())
            .joinToString("") { "%02x".format(it) }

        assertTrue(transferBelongsToResumeToken(canonical, token))
        assertFalse(transferBelongsToResumeToken(canonical.uppercase(Locale.ROOT), token))
        assertFalse(transferBelongsToResumeToken(canonical, ""))
        assertFalse(transferBelongsToResumeToken(canonical, null))
        assertFalse(transferBelongsToResumeToken("", token))
        assertFalse(transferBelongsToResumeToken("0".repeat(63), token))
        assertFalse(transferBelongsToResumeToken("0".repeat(65), token))
        assertFalse(transferBelongsToResumeToken("not-a-sha256-digest", token))
        assertFalse(transferBelongsToResumeToken(canonical, "$token\u0000"))
    }

    private fun assertRejected(block: () -> Unit) {
        try {
            block()
            fail("expected invalid resume state to be rejected")
        } catch (_: IllegalArgumentException) {
            // expected fail-closed validation
        }
    }
}
