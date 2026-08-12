package com.papria.reader

import com.papria.reader.core.transfer.TransferSession
import com.papria.reader.core.transfer.TransferSessionFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferSessionTest {
    @Test
    fun transferSessionExpiresAndUsesRandomToken() {
        val first = TransferSessionFactory.create(10)
        val second = TransferSessionFactory.create(10)
        assertFalse(first.bearerToken.isEmpty())
        assertFalse(first.bearerToken == second.bearerToken)
        assertTrue(first.isExpired(first.expiresAtEpochMillis))
    }

    @Test
    fun expirationComparisonIsInclusiveAcrossLongBoundaries() {
        val cases = listOf(
            TransferSession("minimum", "token", Long.MIN_VALUE) to Long.MIN_VALUE,
            TransferSession("zero", "token", 0) to 0L,
            TransferSession("maximum", "token", Long.MAX_VALUE) to Long.MAX_VALUE,
        )

        cases.forEach { (session, boundary) ->
            if (boundary != Long.MIN_VALUE) {
                assertFalse(session.isExpired(boundary - 1))
            }
            assertTrue(session.isExpired(boundary))
            if (boundary != Long.MAX_VALUE) {
                assertTrue(session.isExpired(boundary + 1))
            }
        }
    }

    @Test
    fun factoryCreatesCanonicalIndependentSessionCredentials() {
        val before = System.currentTimeMillis()
        val sessions = List(64) { TransferSessionFactory.create(ttlMillis = 60_000) }
        val after = System.currentTimeMillis()

        assertEquals(sessions.size, sessions.map { it.uploadSessionId }.toSet().size)
        assertEquals(sessions.size, sessions.map { it.bearerToken }.toSet().size)
        sessions.forEach { session ->
            assertTrue(session.uploadSessionId.matches(UUID_PATTERN))
            assertTrue(session.bearerToken.matches(Regex("[0-9a-f]{32}")))
            assertTrue(session.expiresAtEpochMillis in (before + 60_000)..(after + 60_000))
        }
    }

    private companion object {
        val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    }
}
