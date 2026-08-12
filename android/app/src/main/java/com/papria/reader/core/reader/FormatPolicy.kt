package com.papria.reader.core.reader

import java.io.File
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.Locale

/**
 * Single import gate for the formats declared by the product contract.
 * Filename extensions are not trusted on their own for container formats:
 * the bounded signature check prevents a renamed executable from reaching a
 * ZIP/PDF reader.  DRM detection remains in the format-specific reader.
 */
object FormatPolicy {
    val supportedExtensions = setOf(
        "epub", "kepub", "mobi", "azw", "azw3", "fb2", "pdf",
        "cbz", "cbr", "cb7", "m4b", "m4a", "mp3", "opus", "ogg", "flac",
        // Plain text is useful for a basic reader and does not weaken archive
        // validation; it is intentionally not sent to BookOrbit conversion.
        "txt", "md",
    )

    fun extension(fileName: String): String = fileName.substringAfterLast('.', "").lowercase()

    fun validateName(fileName: String) {
        require(fileName.isNotBlank() && fileName.toByteArray(StandardCharsets.UTF_8).size <= 255) { "invalid file name" }
        require(fileName != "." && fileName != ".." && !fileName.contains('/') && !fileName.contains('\\')) { "invalid file name" }
        require(fileName.none { it.code < 0x20 || it.code == 0x7f || it in charArrayOf('<', '>', ':', '"', '|', '?', '*') }) { "invalid file name" }
        require(!fileName.endsWith('.') && !fileName.endsWith(' ')) { "invalid file name" }
        val device = fileName.substringBefore('.').uppercase()
        require(device !in setOf("CON", "PRN", "AUX", "NUL") && !device.matches(Regex("(?:COM|LPT)[1-9]"))) { "invalid file name" }
        require(extension(fileName) in supportedExtensions) { "unsupported format: ${extension(fileName)}" }
        if (FormatCoreRuntime.enabled && extension(fileName) !in setOf("txt", "md")) {
            FormatCoreRuntime.validateFilename(fileName)
        }
    }

    fun validateHeader(fileName: String, input: InputStream) {
        val extension = extension(fileName)
        val header = ByteArray(16)
        val count = input.read(header)
        val bytes = if (count > 0) header.copyOf(count) else ByteArray(0)

        // When the release native gate is enabled, the Rust core is the
        // authoritative extension/signature decision. The local checks below
        // remain the default path for builds that intentionally omit the
        // optional ABI artifact.
        // Rust's SupportedFormat intentionally excludes the local-only plain
        // text extensions; keep those on the platform path even when the
        // native gate is enabled.
        if (FormatCoreRuntime.enabled && extension !in setOf("txt", "md")) {
            val detected = FormatCoreRuntime.detectFormat(fileName, bytes)
            require(detected == extension.uppercase(Locale.ROOT)) { "format signature mismatch" }
            return
        }

        when (extension) {
            "epub", "kepub", "cbz" -> require(bytes.startsWith(byteArrayOf(0x50, 0x4b, 0x03, 0x04)) || bytes.startsWith(byteArrayOf(0x50, 0x4b, 0x05, 0x06))) { "ZIP signature mismatch" }
            "cbr" -> require(bytes.startsWith("Rar!\u001a\u0007".toByteArray(StandardCharsets.ISO_8859_1))) { "RAR signature mismatch" }
            "cb7" -> require(bytes.startsWith(byteArrayOf(0x37, 0x7a, 0xbc.toByte(), 0xaf.toByte(), 0x27, 0x1c))) { "7z signature mismatch" }
            "pdf" -> require(bytes.startsWith("%PDF-".toByteArray(StandardCharsets.US_ASCII))) { "PDF signature mismatch" }
        }
    }

    fun validateFile(file: File, fileName: String = file.name) {
        validateName(fileName)
        require(file.isFile && file.length() > 0L) { "empty file" }
        file.inputStream().use { validateHeader(fileName, it) }
    }

    /** Scan archive metadata before a Wi-Fi upload is admitted to the library. */
    fun validateContainer(file: File, fileName: String = file.name) {
        when (extension(fileName)) {
            "epub", "kepub" -> EpubBook.open(file).close()
            "cbz", "cbr", "cb7" -> ComicArchive.open(file).use { it.entries }
            else -> Unit
        }
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
