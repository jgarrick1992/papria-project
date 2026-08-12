package com.papria.reader.core.reader

import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Converts bounded DRM-free text extraction into a private EPUB cache. */
object InternalEpubConverter {
    private const val MAX_TEXT_BYTES = 32 * 1024 * 1024
    private const val MAX_INPUT_BYTES = 256L * 1024 * 1024

    fun convert(source: File, extractedText: String): File? {
        if (!source.isFile || extractedText.isBlank() || extractedText.toByteArray(StandardCharsets.UTF_8).size > MAX_TEXT_BYTES) return null
        val output = File(source.parentFile ?: return null, ".${source.name}.papria.epub")
        if (output.isFile && output.length() > 0) return output
        val title = source.nameWithoutExtension.xmlEscape()
        val chapter = "<?xml version=\"1.0\" encoding=\"utf-8\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>$title</title></head><body><p>${extractedText.xmlEscape().replace("\n\n", "</p><p>")}</p></body></html>"
        val opf = "<?xml version=\"1.0\" encoding=\"utf-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:papria:${source.name.hashCode()}</dc:identifier><dc:title>$title</dc:title><dc:language>und</dc:language></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        val nav = "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">$title</a></li></ol></nav></body></html>"
        return runCatching {
            FileOutputStream(output).use { stream ->
                ZipOutputStream(stream).use { zip ->
                    put(zip, "mimetype", "application/epub+zip", stored = true)
                    put(zip, "META-INF/container.xml", "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
                    put(zip, "OEBPS/content.opf", opf)
                    put(zip, "OEBPS/nav.xhtml", nav)
                    put(zip, "OEBPS/chapter.xhtml", chapter)
                }
            }
            output
        }.getOrNull()
    }

    /** Convert an FB2 document without dropping its embedded binary images. */
    fun convertFb2(source: File): File? {
        if (!source.isFile || source.length() > MAX_INPUT_BYTES) return null
        val raw = runCatching { source.inputStream().bufferedReader().use { it.readText() } }.getOrNull() ?: return null
        val binaries = linkedMapOf<String, Binary>()
        var binaryCursor = 0
        while (true) {
            val start = raw.indexOf("<binary", binaryCursor, ignoreCase = true)
            if (start < 0) break
            val openEnd = raw.indexOf('>', start).takeIf { it >= 0 } ?: break
            val closeStart = raw.indexOf("</binary>", openEnd + 1, ignoreCase = true).takeIf { it >= 0 } ?: break
            val attrs = raw.substring(start, openEnd + 1)
            val id = attribute(attrs, "id")
            val mediaType = attribute(attrs, "content-type")
            val encoded = raw.substring(openEnd + 1, closeStart)
            if (id != null && mediaType != null) {
                val bytes = decodeBase64(encoded)
                if (bytes != null && bytes.size <= MAX_TEXT_BYTES) binaries[id] = Binary(id, mediaType, bytes)
            }
            binaryCursor = closeStart + "</binary>".length
        }
        val body = Regex("(?is)<body\\b[^>]*>(.*?)</body>").find(raw)?.groupValues?.get(1) ?: raw
        val imageReplacements = linkedMapOf<String, String>()
        val markup = Regex("(?is)<image\\b[^>]*?/?>").replace(body) { match ->
            val id = Regex("(?i)(?:l:href|href)\\s*=\\s*\"#([^\"]+)\"").find(match.value)?.groupValues?.get(1)
            val binary = id?.let(binaries::get) ?: return@replace ""
            val token = "__PAPRIA_IMAGE_${imageReplacements.size}__"
            imageReplacements[token] = "<img src=\"Images/${binary.id}.${binary.extension}\" alt=\"\"/>"
            token
        }
        var text = plainText(markup)
        imageReplacements.forEach { (token, replacement) -> text = text.replace(token, replacement) }
        if (text.isBlank()) return null
        val title = Regex("(?is)<book-title\\b[^>]*>(.*?)</book-title>").find(raw)?.groupValues?.get(1)?.let(::plainText)?.trim().orEmpty().ifBlank { source.nameWithoutExtension }
        val titleXml = title.xmlEscape()
        val chapter = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>$titleXml</title></head><body><p>${text.xmlEscape().replace("&lt;img ", "<img ").replace("/&gt;", "/>" ).replace("\n\n", "</p><p>")}</p></body></html>"
        val opfManifest = StringBuilder("<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>")
        val entries = mutableListOf(Entry("mimetype", "application/epub+zip".toByteArray(StandardCharsets.UTF_8), true), Entry("META-INF/container.xml", CONTAINER.toByteArray(StandardCharsets.UTF_8)))
        entries += Entry("OEBPS/chapter.xhtml", chapter.toByteArray(StandardCharsets.UTF_8))
        binaries.values.forEach { binary ->
            val href = "Images/${binary.id}.${binary.extension}"
            entries += Entry("OEBPS/$href", binary.bytes)
            opfManifest.append("<item id=\"img-${binary.id.xmlEscape()}\" href=\"$href\" media-type=\"${binary.mediaType.xmlEscape()}\"/>")
        }
        val opf = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:papria:${source.name.hashCode()}</dc:identifier><dc:title>$titleXml</dc:title><dc:language>und</dc:language></metadata><manifest>$opfManifest<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        val nav = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">$titleXml</a></li></ol></nav></body></html>"
        entries += Entry("OEBPS/content.opf", opf.toByteArray(StandardCharsets.UTF_8))
        entries += Entry("OEBPS/nav.xhtml", nav.toByteArray(StandardCharsets.UTF_8))
        return writeEntries(source, entries)
    }

    private fun writeEntries(source: File, entries: List<Entry>): File? {
        val output = File(source.parentFile ?: return null, ".${source.name}.papria.epub")
        if (output.isFile && output.length() > 0) return output
        return runCatching {
            FileOutputStream(output).use { stream -> ZipOutputStream(stream).use { zip -> entries.forEach { put(zip, it.name, it.bytes, it.stored) } } }
            output
        }.getOrNull()
    }

    private fun plainText(value: String): String = value
        .replace(Regex("(?is)<(script|style)\\b[^>]*>.*?</\\1>"), "")
        .replace(Regex("(?i)<br\\s*/?>"), "\n")
        .replace(Regex("(?i)</(p|div|h[1-6]|li|section|title|subtitle|body|empty-line)>"), "\n\n")
        .replace(Regex("(?s)<[^>]+>"), "")
        .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'")
        .replace(Regex("\\n{3,}"), "\n\n").trim()

    private fun attribute(value: String, name: String): String? {
        val marker = "$name=\""
        val start = value.indexOf(marker, ignoreCase = true)
        if (start < 0) return null
        val contentStart = start + marker.length
        val contentEnd = value.indexOf('\"', contentStart)
        return contentEnd.takeIf { it >= contentStart }?.let { value.substring(contentStart, it) }
    }

    private fun decodeBase64(value: String): ByteArray? {
        val clean = value.filterNot(Char::isWhitespace)
        if (clean.length % 4 != 0) return null
        val output = java.io.ByteArrayOutputStream(clean.length * 3 / 4)
        var index = 0
        fun digit(char: Char): Int = when (char) {
            in 'A'..'Z' -> char - 'A'
            in 'a'..'z' -> char - 'a' + 26
            in '0'..'9' -> char - '0' + 52
            '+' -> 62
            '/' -> 63
            '=' -> 64
            else -> -1
        }
        while (index < clean.length) {
            val a = digit(clean[index]); val b = digit(clean[index + 1]); val c = digit(clean[index + 2]); val d = digit(clean[index + 3])
            if (a < 0 || b < 0 || c < 0 || d < 0 || a == 64 || b == 64 || (c == 64 && d != 64)) return null
            output.write((a shl 2) or (b ushr 4))
            if (c < 64) output.write((b shl 4) or (c ushr 2))
            if (d < 64 && c < 64) output.write((c shl 6) or d)
            index += 4
        }
        return output.toByteArray()
    }

    private data class Entry(val name: String, val bytes: ByteArray, val stored: Boolean = false)
    private data class Binary(val id: String, val mediaType: String, val bytes: ByteArray) {
        val extension: String get() = when (mediaType.lowercase(Locale.US)) {
            "image/jpeg", "image/jpg" -> "jpg"
            "image/png" -> "png"
            "image/gif" -> "gif"
            "image/webp" -> "webp"
            else -> "bin"
        }
    }

    private const val CONTAINER = "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"

    private fun put(zip: ZipOutputStream, name: String, value: String, stored: Boolean = false) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        put(zip, name, bytes, stored)
    }

    private fun put(zip: ZipOutputStream, name: String, bytes: ByteArray, stored: Boolean) {
        val entry = ZipEntry(name)
        if (stored) {
            entry.method = ZipEntry.STORED
            entry.size = bytes.size.toLong()
            entry.crc = java.util.zip.CRC32().apply { update(bytes) }.value
        }
        zip.putNextEntry(entry); zip.write(bytes); zip.closeEntry()
    }

    private fun String.xmlEscape(): String = replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}
