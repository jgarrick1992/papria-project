package com.papria.reader.core.transfer

import java.security.SecureRandom
import java.util.UUID

data class TransferSession(
    val uploadSessionId: String,
    val bearerToken: String,
    val expiresAtEpochMillis: Long,
) {
    fun isExpired(nowEpochMillis: Long = System.currentTimeMillis()): Boolean = nowEpochMillis >= expiresAtEpochMillis
}

object TransferSessionFactory {
    fun create(ttlMillis: Long = 10 * 60 * 1000L): TransferSession {
        return TransferSession(
            uploadSessionId = UUID.randomUUID().toString(),
            bearerToken = SecureTransferToken.create(byteCount = 16),
            expiresAtEpochMillis = System.currentTimeMillis() + ttlMillis,
        )
    }
}

/**
 * Generates independent, high-entropy credentials for the local receiver.
 *
 * The QR bearer is deliberately short-lived. A separate 256-bit resume
 * credential protects a single unfinished upload across receiver restarts;
 * only its SHA-256 digest is persisted by the receiver.
 */
internal object SecureTransferToken {
    private val random = SecureRandom()

    fun create(byteCount: Int): String {
        require(byteCount > 0)
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        return bytes.toHex()
    }

    private fun ByteArray.toHex(): String = buildString(size * 2) {
        val digits = "0123456789abcdef"
        for (byte in this@toHex) {
            val value = byte.toInt() and 0xff
            append(digits[value ushr 4])
            append(digits[value and 0x0f])
        }
    }
}
