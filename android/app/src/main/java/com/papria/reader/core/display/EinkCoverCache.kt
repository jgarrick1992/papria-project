package com.papria.reader.core.display

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Generates a stable monochrome cover cache for the e-ink profile. The cache
 * is keyed by the source bytes and threshold mode, so normal colour covers are
 * never overwritten and a server refresh invalidates the old bitmap.
 */
object EinkCoverCache {
    fun fromStream(context: Context, input: InputStream, binary: Boolean = false): File? {
        val bytes = input.readBytes()
        if (bytes.isEmpty() || bytes.size > MAX_SOURCE_BYTES) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val directory = File(context.cacheDir, "covers/eink").apply { mkdirs() }
        val output = File(directory, "$digest-${if (binary) "b" else "g"}.png")
        if (output.isFile) return output
        val source = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        return runCatching {
            val target = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(target)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val matrix = ColorMatrix().apply { setSaturation(0f) }
            paint.colorFilter = ColorMatrixColorFilter(matrix)
            canvas.drawBitmap(source, 0f, 0f, paint)
            if (binary) {
                for (y in 0 until target.height) for (x in 0 until target.width) {
                    val pixel = target.getPixel(x, y)
                    val level = (0.299 * android.graphics.Color.red(pixel) + 0.587 * android.graphics.Color.green(pixel) + 0.114 * android.graphics.Color.blue(pixel)).toInt()
                    target.setPixel(x, y, if (level >= 160) android.graphics.Color.WHITE else android.graphics.Color.BLACK)
                }
            }
            output.outputStream().use { target.compress(Bitmap.CompressFormat.PNG, 100, it) }
            source.recycle(); target.recycle()
            output
        }.getOrNull()
    }

    private const val MAX_SOURCE_BYTES = 16 * 1024 * 1024
}
