package com.papria.reader.core.storage

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale

/** Content-addressed storage for books imported locally or downloaded from BookOrbit. */
class ContentAddressedStore(context: Context) {
    private val root = File(context.filesDir, "books").apply { mkdirs() }
    private val parts = File(context.filesDir, "downloads").apply { mkdirs() }

    fun contentFile(sha256: String): File = File(root, normalizeHash(sha256))

    fun partFile(fileId: Long): File = File(parts, "$fileId.part")

    fun existing(sha256: String?): File? = sha256?.takeIf { isSha256(it) }?.let(::contentFile)?.takeIf(File::exists)

    /** Remove one content object after its last publication reference is gone. */
    fun remove(sha256: String): Boolean = contentFile(sha256).takeIf(File::isFile)?.delete() == true

    fun openPart(fileId: Long, append: Boolean = true): OutputStream = FileOutputStream(partFile(fileId), append)

    fun partLength(fileId: Long): Long = partFile(fileId).length()

    /** Finalize only after the caller has validated the expected byte count and hash. */
    fun finalizePart(fileId: Long, expectedSha256: String? = null): StoredContent {
        val part = partFile(fileId)
        require(part.isFile) { "download part does not exist: $fileId" }
        val hash = sha256(part)
        require(expectedSha256 == null || hash.equals(expectedSha256, ignoreCase = true)) {
            "SHA-256 mismatch: expected=$expectedSha256 actual=$hash"
        }
        val target = contentFile(hash)
        if (!target.exists()) {
            require(part.renameTo(target)) { "could not atomically move downloaded file" }
        } else {
            part.delete()
        }
        return StoredContent(hash, target, target.length())
    }

    fun import(input: InputStream, expectedSize: Long? = null, expectedSha256: String? = null, tempName: String = "import-${System.nanoTime()}"): StoredContent {
        val temp = File(parts, "$tempName.part")
        return try {
            temp.outputStream().use { output -> input.copyTo(output) }
            if (expectedSize != null) require(temp.length() == expectedSize) { "size mismatch" }
            val hash = sha256(temp)
            require(expectedSha256 == null || hash.equals(expectedSha256, ignoreCase = true)) { "SHA-256 mismatch" }
            val target = contentFile(hash)
            if (!target.exists()) require(temp.renameTo(target)) { "could not finalize imported file" } else temp.delete()
            StoredContent(hash, target, target.length())
        } catch (error: Exception) {
            temp.delete()
            throw error
        }
    }

    fun import(file: File, expectedSha256: String? = null): StoredContent = file.inputStream().use { import(it, file.length(), expectedSha256, "import-${file.name.hashCode()}") }

    fun sha256(file: File): String = file.inputStream().use(::sha256)

    fun sha256(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count > 0) digest.update(buffer, 0, count)
        }
        return digest.digest().toHex()
    }

    fun freeBytes(): Long = root.usableSpace

    fun ensureCapacity(additionalBytes: Long) {
        require(additionalBytes >= 0 && freeBytes() >= additionalBytes + MIN_FREE_BYTES) {
            "insufficient storage"
        }
    }

    fun cleanupParts(olderThanEpochMillis: Long): Int {
        var removed = 0
        parts.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < olderThanEpochMillis && file.delete()) removed++
        }
        return removed
    }

    private fun normalizeHash(value: String): String = value.trim().lowercase(Locale.US).also { require(isSha256(it)) { "invalid SHA-256" } }

    private fun isSha256(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

    private fun ByteArray.toHex(): String = buildString(size * 2) {
        for (byte in this@toHex) append("0123456789abcdef"[(byte.toInt() ushr 4) and 0x0f]).append("0123456789abcdef"[byte.toInt() and 0x0f])
    }

    private companion object {
        const val MIN_FREE_BYTES = 8L * 1024L * 1024L
    }
}

data class StoredContent(val sha256: String, val file: File, val sizeBytes: Long)
