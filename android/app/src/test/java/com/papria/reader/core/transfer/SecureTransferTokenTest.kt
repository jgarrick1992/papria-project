package com.papria.reader.core.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureTransferTokenTest {
    @Test
    fun tokenUsesExactlyTwoLowercaseHexCharactersPerRandomByte() {
        listOf(1, 2, 15, 16, 17, 31, 32, 33, 256, 4_096).forEach { byteCount ->
            val token = SecureTransferToken.create(byteCount)

            assertEquals(byteCount * 2, token.length)
            assertTrue(token.all { it in '0'..'9' || it in 'a'..'f' })
        }
    }

    @Test
    fun tokenRejectsZeroAndNegativeByteCounts() {
        listOf(0, -1, Int.MIN_VALUE).forEach { byteCount ->
            assertThrows(IllegalArgumentException::class.java) { SecureTransferToken.create(byteCount) }
        }
    }

    @Test
    fun independentlyGeneratedTransferTokensDoNotRepeat() {
        val tokens = List(256) { SecureTransferToken.create(byteCount = 32) }

        assertEquals(tokens.size, tokens.toSet().size)
        assertTrue(tokens.none(String::isBlank))
    }
}
