package com.papria.reader.core.display

import android.content.Context
import java.io.File
import java.security.MessageDigest

/** Stores colour and e-ink cover variants without changing the source bytes. */
object CoverCache {
    private const val MAX_BYTES = 16L * 1024L * 1024L

    fun save(context: Context, bookId: Long, bytes: ByteArray): CoverPaths? {
        if (bookId <= 0 || bytes.isEmpty() || bytes.size > MAX_BYTES) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val root = File(context.cacheDir, "covers").apply { mkdirs() }
        val color = File(root, "$bookId-$digest.color")
        if (!color.isFile) color.outputStream().use { it.write(bytes) }
        val gray = EinkCoverCache.fromStream(context, bytes.inputStream(), binary = false)
        val binary = EinkCoverCache.fromStream(context, bytes.inputStream(), binary = true)
        return CoverPaths(color = color, gray = gray, binary = binary)
    }

    /** Restore a fetched cover while BookOrbit is offline. */
    fun cached(context: Context, bookId: Long): CoverPaths? {
        if (bookId <= 0) return null
        val color = File(context.cacheDir, "covers").listFiles()
            ?.firstOrNull { it.isFile && it.name.startsWith("$bookId-") && it.name.endsWith(".color") }
            ?: return null
        val digest = color.name.removePrefix("$bookId-").removeSuffix(".color")
        val einkDir = File(context.cacheDir, "covers/eink")
        return CoverPaths(
            color = color,
            gray = File(einkDir, "$digest-g.png").takeIf(File::isFile),
            binary = File(einkDir, "$digest-b.png").takeIf(File::isFile),
        )
    }

    fun clear(context: Context) {
        File(context.cacheDir, "covers").deleteRecursively()
    }

    data class CoverPaths(val color: File, val gray: File?, val binary: File?)
}
