package com.papria.reader

import com.papria.reader.core.reader.ComicArchive
import com.papria.reader.core.reader.EpubCfiResolution
import com.papria.reader.core.reader.EpubBook
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.apache.commons.compress.archivers.sevenz.SevenZArchiveEntry
import org.apache.commons.compress.archivers.sevenz.SevenZOutputFile
import com.papria.reader.core.reader.InternalEpubConverter
import com.papria.reader.core.reader.FormatCoreRuntime

class ReaderFormatTest {
    @Test
    fun nativeFormatCoreGateIsDisabledForDefaultJvmTests() {
        // The native-enabled Gradle variant is also used for the compile gate,
        // but JVM tests intentionally do not load an Android .so. The default
        // variant still exercises the no-op path below.
        if (FormatCoreRuntime.enabled) return
        FormatCoreRuntime.validateFilename("book.epub")
    }

    @Test
    fun plainTextStaysOnPlatformValidationPath() {
        // Rust SupportedFormat intentionally contains only BookOrbit formats;
        // Local TXT/MD files remain usable when the mandatory core is present.
        com.papria.reader.core.reader.FormatPolicy.validateName("notes.txt")
    }

    @Test
    fun epubUsesContainerSpineAndBoundedPages() {
        val file = tempFile(".epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, value: String) { zip.putNextEntry(ZipEntry(name)); zip.write(value.toByteArray()); zip.closeEntry() }
            put("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>")
            put("OPS/package.opf", "<package><metadata><dc:title>Test</dc:title></metadata><manifest><item id=\"one\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"one\"/></spine></package>")
            put("OPS/chapter.xhtml", "<html><body><h1>Chapter</h1><p>Hello EPUB</p></body></html>")
        }
        val book = EpubBook.open(file)
        assertEquals("Test", book.title)
        assertEquals(1, book.chapters.size)
        assertTrue(book.pages(0, 18).single().contains("Hello EPUB"))
        file.delete()
    }

    @Test
    fun epubLayoutSettingsChangeBoundedPageBudget() {
        val file = tempFile(".epub")
        val longText = (0 until 4_000).joinToString(" ") { "word$it" }
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, value: String) { zip.putNextEntry(ZipEntry(name)); zip.write(value.toByteArray()); zip.closeEntry() }
            put("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>")
            put("OPS/package.opf", "<package><metadata><dc:title>Reflow</dc:title></metadata><manifest><item id=\"one\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"one\"/></spine></package>")
            put("OPS/chapter.xhtml", "<html><body><p>$longText</p></body></html>")
        }
        val book = EpubBook.open(file)
        val compact = book.pages(0, 18, lineSpacing = 2, paragraphSpacing = 0, margin = 0)
        val spacious = book.pages(0, 18, lineSpacing = 24, paragraphSpacing = 8, margin = 32)
        assertTrue(spacious.size >= compact.size)
        file.delete()
    }

    @Test
    fun epub2NcxAndFragmentLocatorsRestoreAcrossReflow() {
        val file = tempFile(".epub")
        val body = (0 until 4_000).joinToString(" ") { "word$it" }
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, value: String) { zip.putNextEntry(ZipEntry(name)); zip.write(value.toByteArray()); zip.closeEntry() }
            put("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>")
            put("OPS/package.opf", """
                <package><metadata><dc:title>NCX book</dc:title></metadata>
                <manifest>
                  <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                </manifest>
                <spine toc="ncx"><itemref idref="chapter"/></spine>
            """.trimIndent())
            put("OPS/chapter.xhtml", "<html><body><p>$body</p><h2 id=\"part-two\">Part two</h2><p>tail</p></body></html>")
            put("OPS/toc.ncx", """
                <ncx><navMap><navPoint><navLabel><text>Part two</text></navLabel>
                  <content src="chapter.xhtml#part-two"/>
                </navPoint></navMap></ncx>
            """.trimIndent())
        }
        val book = EpubBook.open(file)
        assertEquals(1, book.tableOfContents.size)
        assertEquals("Part two", book.tableOfContents.single().title)
        assertEquals("OPS/chapter.xhtml#part-two", book.tableOfContents.single().href)
        val target = book.pageIndexForHref(book.tableOfContents.single().href, fontSizeSp = 18)
        assertTrue(target != null)
        val compactTarget = book.pageIndexForHref(book.tableOfContents.single().href, fontSizeSp = 18, lineSpacing = 2, margin = 0)!!
        val compact = book.pages(compactTarget.first, 18, lineSpacing = 2, margin = 0)
        val cfi = book.cfiForPage(compactTarget.first, compactTarget.second, 18, lineSpacing = 2, margin = 0)
        assertTrue(cfi.startsWith("epubcfi(/6/4"))
        val resolved = book.resolveCfi(cfi)
        assertTrue(resolved is EpubCfiResolution.Resolved)
        resolved as EpubCfiResolution.Resolved
        assertEquals(compactTarget.first, resolved.chapterIndex)
        assertEquals(compactTarget.second, book.pageForOffset(resolved.chapterIndex, resolved.textOffset, 18, lineSpacing = 2, margin = 0))
        assertTrue(book.pageForOffset(resolved.chapterIndex, resolved.textOffset, 30, lineSpacing = 20, margin = 32) >= 0)
        assertTrue(compact.isNotEmpty())
        file.delete()
    }

    @Test
    fun epubCfiResolvesExternalTextNodeAndReportsUnknownNodeExplicitly() {
        val file = tempFile(".epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, value: String) { zip.putNextEntry(ZipEntry(name)); zip.write(value.toByteArray()); zip.closeEntry() }
            put("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>")
            put("OPS/package.opf", """
                <package><metadata><dc:title>CFI</dc:title></metadata>
                <manifest><item id="one" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref id="chapter-ref" idref="one"/></spine></package>
            """.trimIndent())
            put("OPS/chapter.xhtml", "<html><head><title>Hidden title</title></head><body><p id=\"opening\">Alpha Beta Gamma</p></body></html>")
        }
        val book = EpubBook.open(file)
        val external = book.resolveCfi("epubcfi(/6/4[chapter-ref]!/4/2/1:6)")
        assertTrue(external is EpubCfiResolution.Resolved)
        external as EpubCfiResolution.Resolved
        assertEquals(0, external.chapterIndex)
        assertEquals(6, external.textOffset)
        val generated = book.cfiForOffset(external.chapterIndex, external.textOffset)
        assertTrue(generated.startsWith("epubcfi(/6/4[chapter-ref]!/4/2[opening]/1:6)"))

        val unresolved = book.resolveCfi("epubcfi(/6/4[chapter-ref]!/4/8/1:0)")
        assertTrue(unresolved is EpubCfiResolution.Unresolved)

        val manifestAssertion = book.resolveCfi("epubcfi(/6/4[one]!/4/2/1:6)")
        assertTrue(manifestAssertion is EpubCfiResolution.Resolved)
        file.delete()
    }

    @Test
    fun epubRejectsUnsafeArchiveMemberBeforeReadingContainer() {
        val file = tempFile(".epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("../escape.xhtml")); zip.write("escape".toByteArray()); zip.closeEntry()
            zip.putNextEntry(ZipEntry("META-INF/container.xml")); zip.write("<container/>".toByteArray()); zip.closeEntry()
        }
        assertThrows(IllegalArgumentException::class.java) { EpubBook.open(file) }
        file.delete()
    }

    @Test
    fun cbzImageEntriesAreListedAndReadWithoutExtraction() {
        val file = tempFile(".cbz")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("01.jpg")); zip.write(byteArrayOf(1, 2, 3)); zip.closeEntry()
        }
        val archive = ComicArchive.open(file)
        assertEquals(listOf("01.jpg"), archive.entries.map { it.name })
        assertEquals(byteArrayOf(1, 2, 3).toList(), archive.read(archive.entries.single()).toList())
        file.delete()
    }

    @Test
    fun cbzRejectsTraversalBeforeImageFiltering() {
        val file = tempFile(".cbz")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("../escape.jpg")); zip.write(byteArrayOf(4)); zip.closeEntry()
        }
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cb7ImageEntriesAreListedAndReadWithoutExtraction() {
        val file = tempFile(".cb7")
        SevenZOutputFile(file).use { archive ->
            val entry = SevenZArchiveEntry().apply { name = "01.jpg" }
            archive.putArchiveEntry(entry)
            archive.write(byteArrayOf(7, 8, 9))
            archive.closeArchiveEntry()
        }
        ComicArchive.open(file).use { archive ->
            assertEquals(listOf("01.jpg"), archive.entries.map { it.name })
            assertEquals(byteArrayOf(7, 8, 9).toList(), archive.read(archive.entries.single()).toList())
        }
        file.delete()
    }

    @Test
    fun cb7RejectsTraversalBeforeImageFiltering() {
        val file = tempFile(".cb7")
        SevenZOutputFile(file).use { archive ->
            val entry = SevenZArchiveEntry().apply { name = "../escape.jpg" }
            archive.putArchiveEntry(entry)
            archive.write(byteArrayOf(7))
            archive.closeArchiveEntry()
        }
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbrStoredEntryIsReadAndChecksumChecked() {
        val file = tempFile(".cbr")
        val payload = byteArrayOf(1, 2, 3)
        file.writeBytes(rar4(listOf(RarEntry("01.jpg", payload, payload.size, method = 0x30))))
        ComicArchive.open(file).use { archive ->
            assertEquals(listOf("01.jpg"), archive.entries.map { it.name })
            assertEquals(payload.toList(), archive.read(archive.entries.single()).toList())
        }
        file.delete()
    }

    @Test
    fun cbrCompressedEntryIsEnumeratedAndMalformedPayloadFailsOnRead() {
        val file = tempFile(".cbr")
        // Method 0x31 is a valid RAR4 compressed method. This fixture does not
        // contain valid compressed RAR payload bytes, but confirms a compressed
        // member reaches the decoder instead of being silently dropped or
        // rejected globally during archive enumeration.
        file.writeBytes(rar4(listOf(RarEntry("01.jpg", byteArrayOf(1), unpackedSize = 2, method = 0x31))))
        ComicArchive.open(file).use { archive ->
            assertEquals(listOf("01.jpg"), archive.entries.map { it.name })
            assertThrows(IOException::class.java) { archive.read(archive.entries.single()) }
        }
        file.delete()
    }

    @Test
    fun cbrCompressedEntryExceedingRatioFailsBeforeDecoderRuns() {
        val file = tempFile(".cbr")
        // Header metadata must be rejected before the third-party decoder is
        // asked to inspect attacker-controlled compressed bytes.
        file.writeBytes(rar4(listOf(RarEntry("01.jpg", byteArrayOf(1), unpackedSize = 101, method = 0x31))))
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbrEncryptedEntryFailsClosedBeforeImageFiltering() {
        val file = tempFile(".cbr")
        file.writeBytes(rar4(listOf(RarEntry("01.jpg", byteArrayOf(1), flags = 0x04))))
        assertThrows(IOException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbrUnsafeMemberFailsClosedBeforeImageFiltering() {
        val file = tempFile(".cbr")
        file.writeBytes(rar4(listOf(RarEntry("../01.jpg", byteArrayOf(1)))))
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbrMissingEndMarkerFailsClosed() {
        val file = tempFile(".cbr")
        val complete = rar4(listOf(RarEntry("01.jpg", byteArrayOf(1))))
        file.writeBytes(complete.copyOf(complete.size - 7))
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbrStoredChecksumMismatchFailsWhenPageIsRead() {
        val file = tempFile(".cbr")
        val complete = rar4(listOf(RarEntry("01.jpg", byteArrayOf(1, 2, 3))))
        // The end marker is seven bytes; corrupt the final byte of the stored
        // member while leaving all metadata and the marker intact.
        complete[complete.size - 8] = 9
        file.writeBytes(complete)
        ComicArchive.open(file).use { archive ->
            assertThrows(IOException::class.java) { archive.read(archive.entries.single()) }
        }
        file.delete()
    }

    @Test
    fun cbrSplitMemberFailsClosedBeforeImageFiltering() {
        val file = tempFile(".cbr")
        file.writeBytes(rar4(listOf(RarEntry("01.jpg", byteArrayOf(1), flags = 0x0001))))
        assertThrows(IOException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun rar5SignatureFailsClosedAtTheRar4AdapterBoundary() {
        val file = tempFile(".cbr")
        file.writeBytes("Rar!\u001a\u0007\u0001\u0000".toByteArray(Charsets.ISO_8859_1))
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun cbzCompressionBombFailsBeforeImageFiltering() {
        val file = tempFile(".cbz")
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("01.jpg"))
            zip.write(ByteArray(2 * 1024 * 1024))
            zip.closeEntry()
        }
        assertThrows(IllegalArgumentException::class.java) { ComicArchive.open(file).entries }
        file.delete()
    }

    @Test
    fun fb2ConversionKeepsEmbeddedImageResource() {
        val file = tempFile(".fb2")
        file.writeText(
            "<FictionBook><description><title-info><book-title>Illustrated</book-title></title-info></description><body><section><title>One</title><p>Hello</p><image l:href=\"#cover\"/></section></body><binary id=\"cover\" content-type=\"image/png\">AQID</binary></FictionBook>",
        )
        val converted = InternalEpubConverter.convertFb2(file) ?: error("FB2 conversion failed")
        ZipFile(converted).use { zip ->
            assertTrue(zip.getEntry("OEBPS/chapter.xhtml") != null)
            assertTrue(zip.getEntry("OEBPS/Images/cover.png") != null)
            assertEquals(listOf(1, 2, 3), zip.getInputStream(zip.getEntry("OEBPS/Images/cover.png")).readBytes().map { it.toInt() and 0xff })
        }
        file.delete()
        converted.delete()
    }

    private fun tempFile(extension: String): File = File.createTempFile("papria-reader-", extension)

    private data class RarEntry(
        val name: String,
        val payload: ByteArray,
        val unpackedSize: Int = payload.size,
        val method: Int = 0x30,
        val flags: Int = 0,
    )

    /** Minimal RAR4 fixture writer; header CRC is intentionally ignored by the reader. */
    private fun rar4(entries: List<RarEntry>): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00))
        entries.forEach { entry ->
            val name = entry.name.toByteArray(Charsets.UTF_8)
            val headerSize = 32 + name.size
            val crc = CRC32().apply { update(entry.payload) }.value
            putU16(output, 0)
            output.write(0x74)
            putU16(output, entry.flags)
            putU16(output, headerSize)
            putU32(output, entry.payload.size.toLong())
            putU32(output, entry.unpackedSize.toLong())
            output.write(0) // host OS
            putU32(output, crc)
            putU32(output, 0) // DOS time
            output.write(20) // unpack version
            output.write(entry.method)
            putU16(output, name.size)
            putU32(output, 0) // attributes
            output.write(name)
            output.write(entry.payload)
        }
        putU16(output, 0)
        output.write(0x7b) // end-of-archive header
        putU16(output, 0)
        putU16(output, 7)
        return output.toByteArray()
    }

    private fun putU16(output: ByteArrayOutputStream, value: Int) {
        output.write(value and 0xff)
        output.write((value ushr 8) and 0xff)
    }

    private fun putU32(output: ByteArrayOutputStream, value: Long) {
        output.write((value and 0xff).toInt())
        output.write(((value ushr 8) and 0xff).toInt())
        output.write(((value ushr 16) and 0xff).toInt())
        output.write(((value ushr 24) and 0xff).toInt())
    }
}
