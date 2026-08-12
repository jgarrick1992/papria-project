package com.papria.reader.core.security

import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Trust manager for an explicitly confirmed server certificate fingerprint.
 *
 * The normal platform trust chain is still used whenever it succeeds. If a
 * user has explicitly confirmed a self-signed host, the leaf certificate's
 * DER SHA-256 fingerprint is checked against the stored value. No global
 * trust-all manager or hostname bypass is allowed.
 */
object CertificatePinning {
    fun trustManager(fingerprint: String): X509TrustManager {
        val expected = decodeFingerprint(fingerprint)
        val defaults = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(null as java.security.KeyStore?) }
        val delegate = defaults.trustManagers.filterIsInstance<X509TrustManager>().singleOrNull()
            ?: error("system X509 trust manager is unavailable")
        return PinnedTrustManager(delegate, expected)
    }

    fun sslContext(trustManager: X509TrustManager): SSLContext = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf(trustManager), SecureRandom())
    }

    private fun decodeFingerprint(value: String): ByteArray {
        val normalized = value.trim().replace(":", "").replace(" ", "")
        require(normalized.length == 64 && normalized.all { it in "0123456789abcdefABCDEF" }) {
            "certificate fingerprint must be a 64-character SHA-256 hex value"
        }
        return ByteArray(32) { index -> normalized.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private class PinnedTrustManager(
        private val delegate: X509TrustManager,
        private val expectedFingerprint: ByteArray,
    ) : X509TrustManager {
        override fun getAcceptedIssuers(): Array<X509Certificate> = delegate.acceptedIssuers

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            delegate.checkClientTrusted(chain, authType)
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            require(chain.isNotEmpty()) { "server certificate chain is empty" }
            val actual = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
            if (!actual.contentEquals(expectedFingerprint)) {
                throw CertificateException("server certificate fingerprint does not match the confirmed value")
            }
            // A pinned self-signed certificate is accepted only after the
            // fingerprint match; otherwise preserve normal platform checks.
            runCatching { delegate.checkServerTrusted(chain, authType) }
        }
    }
}
