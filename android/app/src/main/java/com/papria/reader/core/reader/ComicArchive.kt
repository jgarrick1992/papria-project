package com.papria.reader.core.reader

import org.apache.commons.compress.archivers.sevenz.SevenZArchiveEntry
import org.apache.commons.compress.archivers.sevenz.SevenZMethod
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import com.github.junrar.Archive
import com.github.junrar.exception.RarException
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.zip.CRC32
import java.util.zip.ZipFile

/**
 * Bounded comic archive adapter. ZIP/CBZ uses the JDK, CB7 uses Commons
 * Compress and RAR4 metadata are parsed locally. Compressed RAR4 members are
 * decoded with Junrar only after that metadata passes the same limits as
 * ZIP/7z. The adapter never extracts an archive to a directory. Encrypted,
 * split, large and Unicode-encoded RAR4 members are rejected during archive
 * enumeration; they must not silently disappear and produce an apparently
 * empty comic.
 */
class ComicArchive private constructor(
    private val file: File,
    private val kind: Kind,
) : AutoCloseable {
    enum class Kind { ZIP, SEVEN_Z, RAR4 }

    data class Entry(val name: String, val sizeBytes: Long)

    internal data class ArchiveRecord(
        val name: String,
        val sizeBytes: Long,
        val compressedSizeBytes: Long,
        val encrypted: Boolean,
        val directory: Boolean = false,
        /** False when the container does not expose packed-size metadata. */
        val compressionRatioKnown: Boolean = true,
    )

    val entries: List<Entry> by lazy { listEntries() }

    fun read(entry: Entry, maxBytes: Long = MAX_ENTRY_BYTES): ByteArray {
        require(entry.sizeBytes in 0..maxBytes) { "comic entry exceeds safety limit" }
        return when (kind) {
            Kind.ZIP -> ZipFile(file).use { zip ->
                val item = zip.getEntry(entry.name) ?: throw IOException("missing ZIP entry")
                require(safeImageName(entry.name) && !item.isDirectory && item.size in 0..maxBytes) { "unsafe ZIP entry" }
                zip.getInputStream(item).use { it.readBounded(maxBytes) }
            }
            Kind.SEVEN_Z -> SevenZFile(file).use { archive ->
                var item: SevenZArchiveEntry? = archive.getNextEntry()
                while (item != null) {
                    if (item!!.name == entry.name) {
                        require(safeImageName(entry.name) && !item!!.isDirectory && item!!.size in 0..maxBytes) { "unsafe 7z entry" }
                        return archive.readBounded(maxBytes)
                    }
                    item = archive.getNextEntry()
                }
                throw IOException("missing 7z entry")
            }
            Kind.RAR4 -> Rar4.read(file, entry.name, maxBytes)
        }
    }

    override fun close() = Unit

    private fun listEntries(): List<Entry> = when (kind) {
        Kind.ZIP -> ZipFile(file).use { zip ->
            FormatCoreRuntime.inspectComicArchive(file, "ZIP")
            val records = zip.entries().asSequence().map {
                ArchiveRecord(
                    name = it.name,
                    sizeBytes = it.size,
                    compressedSizeBytes = it.compressedSize,
                    encrypted = (it.method == 99) || ((it.method != 0) && it.compressedSize < 0),
                    directory = it.isDirectory,
                )
            }.toList()
            validateAggregate(records)
            records.filter { !it.directory && safeImageName(it.name) }.map { Entry(it.name, it.sizeBytes) }.sortedBy { it.name.lowercase() }
        }
        Kind.SEVEN_Z -> SevenZFile(file).use { archive ->
            FormatCoreRuntime.inspectComicArchive(file, "SEVEN_ZIP")
            val records = archive.entries.asSequence().map { entry ->
                ArchiveRecord(
                    name = entry.name,
                    sizeBytes = entry.size,
                    // Commons Compress does not expose the packed size for a
                    // SevenZ entry. The uncompressed and aggregate caps still
                    // apply; the Rust boundary receives a zero packed-size
                    // sentinel and therefore skips only the ratio check.
                    compressedSizeBytes = 0L,
                    encrypted = entry.contentMethods?.any { method -> method.method == SevenZMethod.AES256SHA256 } == true,
                    directory = entry.isDirectory,
                    compressionRatioKnown = false,
                )
            }.toList()
            validateAggregate(records)
            records.filter { !it.directory && safeImageName(it.name) }.map { Entry(it.name, it.sizeBytes) }.sortedBy { it.name.lowercase() }
        }
        Kind.RAR4 -> {
            FormatCoreRuntime.inspectComicArchive(file, "RAR")
            Rar4.listStoredRecords(file).also(::validateAggregate).filter { !it.directory && safeImageName(it.name) }
                .map { Entry(it.name, it.sizeBytes) }.sortedBy { it.name.lowercase() }
        }
    }

    private fun validateAggregate(records: List<ArchiveRecord>) {
        require(records.size <= MAX_ENTRIES) { "archive has too many entries" }
        val names = HashSet<String>(records.size)
        var total = 0L
        records.forEach { record ->
            require(names.add(record.name)) { "duplicate archive entry" }
            require(!record.encrypted) { "encrypted comic archive entry is not supported" }
            // Directory records commonly end in `/`; validate their logical
            // path without treating that required marker as an empty member.
            val logicalName = if (record.directory) record.name.trimEnd('/') else record.name
            require(logicalName.isNotBlank() && !logicalName.startsWith('/') && !logicalName.contains('\\')) { "unsafe archive path" }
            require(logicalName.split('/').none { it.isBlank() || it == "." || it == ".." }) { "unsafe archive path" }
            require(logicalName.none { it.code < 0x20 || it.code == 0x7f }) { "unsafe archive path" }
            require(record.sizeBytes in 0..MAX_ENTRY_BYTES) { "archive entry exceeds safety limit" }
            if (record.sizeBytes > 0 && record.compressionRatioKnown) {
                require(record.compressedSizeBytes > 0 && withinCompressionRatio(record.sizeBytes, record.compressedSizeBytes)) {
                    "archive compression ratio exceeds safety limit"
                }
            }
            total = Math.addExact(total, record.sizeBytes)
            require(total <= MAX_TOTAL_BYTES) { "archive exceeds total safety limit" }
        }
        // Every installed app has already passed the real-container Rust
        // inspector before this adapter enumerates decoder metadata. These
        // local checks remain a decoder-side defence during decompression.
    }

    private fun withinCompressionRatio(uncompressed: Long, compressed: Long): Boolean {
        if (compressed <= 0) return false
        // Avoid overflowing compressed * MAX_COMPRESSION_RATIO on hostile
        // metadata. If the product would overflow Long, every legal Long
        // uncompressed size is necessarily below the ratio bound.
        if (compressed > Long.MAX_VALUE / MAX_COMPRESSION_RATIO) return true
        return uncompressed <= compressed * MAX_COMPRESSION_RATIO
    }

    companion object {
        private const val MAX_ENTRIES = 10_000
        private const val MAX_ENTRY_BYTES = 256L * 1024 * 1024
        private const val MAX_TOTAL_BYTES = 1L * 1024 * 1024 * 1024
        private const val MAX_COMPRESSION_RATIO = 100L

        fun open(file: File): ComicArchive {
            require(file.isFile && file.length() <= 8L * 1024 * 1024 * 1024) { "invalid comic archive" }
            val extension = file.extension.lowercase()
            val kind = when (extension) {
                "cbz", "zip" -> Kind.ZIP
                "cb7", "7z" -> Kind.SEVEN_Z
                "cbr", "rar" -> Kind.RAR4
                else -> throw IOException("unsupported comic archive: $extension")
            }
            return ComicArchive(file, kind)
        }

        private fun safeImageName(name: String): Boolean {
            if (name.isBlank() || name.startsWith('/') || name.contains('\\')) return false
            if (name.split('/').any { it == ".." || it.isBlank() }) return false
            return name.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "png", "webp", "gif", "bmp")
        }
    }
}

private fun java.io.InputStream.readBounded(maxBytes: Long): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        require(total <= maxBytes) { "archive entry exceeds safety limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private fun SevenZFile.readBounded(maxBytes: Long): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        total += count
        require(total <= maxBytes) { "archive entry exceeds safety limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private object Rar4 {
    private val signature = byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00)
    private const val FILE_HEADER = 0x74
    private const val MAIN_HEADER = 0x73
    private const val METHOD_STORE = 0x30
    private const val FLAG_SPLIT_BEFORE = 0x0001
    private const val FLAG_SPLIT_AFTER = 0x0002
    private const val FLAG_ENCRYPTED = 0x0004
    private const val FLAG_LARGE = 0x0100
    private const val FLAG_UNICODE = 0x0200
    private const val FLAG_HAS_SALT = 0x0400
    private const val FLAG_HAS_ADD_SIZE = 0x8000
    private const val MAIN_FLAG_ENCRYPTED = 0x0080

    fun listStoredRecords(file: File): List<ComicArchive.ArchiveRecord> = scan(file).map { it.record }

    fun read(file: File, name: String, maxBytes: Long): ByteArray {
        require(name.isNotBlank() && safeRarName(name)) { "unsafe RAR entry name" }
        val record = scan(file).firstOrNull { it.record.name == name }
            ?: throw IOException("RAR entry is absent")
        require(record.record.sizeBytes <= maxBytes) { "RAR entry exceeds safety limit" }
        return if (record.method == METHOD_STORE) readStored(file, record, maxBytes) else readCompressed(file, record, maxBytes)
    }

    private fun readStored(file: File, record: Record, maxBytes: Long): ByteArray {
        RandomAccessFile(file, "r").use { input ->
            input.seek(record.dataOffset)
            val output = ByteArrayOutputStream(record.record.sizeBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            val buffer = ByteArray(64 * 1024)
            val checksum = CRC32()
            var remaining = record.record.sizeBytes
            while (remaining > 0L) {
                val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (count <= 0) throw IOException("truncated RAR entry")
                output.write(buffer, 0, count)
                checksum.update(buffer, 0, count)
                remaining -= count
            }
            if (checksum.value != record.crc32) {
                throw IOException("RAR entry checksum mismatch")
            }
            return output.toByteArray()
        }
    }

    /**
     * Junrar is reached only after [scan] has checked the RAR4 signature,
     * complete headers, names, per-entry/aggregate bounds, packed size and
     * encryption/split flags. The output stream repeats the declared size cap
     * while decoding, preventing a compressed member from materialising more
     * bytes than its validated metadata permits.
     */
    private fun readCompressed(file: File, record: Record, maxBytes: Long): ByteArray = try {
        Archive(file).use { archive ->
            if (archive.isEncrypted || archive.isPasswordProtected) {
                throw IOException("encrypted RAR archive is not supported")
            }
            val header = archive.fileHeaders.firstOrNull {
                // The local scanner accepts only canonical UTF-8 names and
                // rejects RAR's alternate Unicode encoding, so this matching
                // cannot turn a path validation into a library-specific alias.
                it.fileName == record.record.name
            } ?: throw IOException("RAR entry is absent from decoder index")
            if (header.isEncrypted || header.hasSalt() || header.isSplitBefore || header.isSplitAfter || header.isLargeBlock || header.isUnicode) {
                throw IOException("unsupported RAR entry flags")
            }
            if (header.fullPackSize != record.record.compressedSizeBytes || header.fullUnpackSize != record.record.sizeBytes) {
                throw IOException("RAR decoder metadata does not match validated header")
            }
            val output = BoundedRarOutput(record.record.sizeBytes.coerceAtMost(maxBytes))
            archive.extractFile(header, output)
            output.bytes().also { bytes ->
                val checksum = CRC32().apply { update(bytes) }.value
                if (checksum != record.crc32) throw IOException("RAR entry checksum mismatch")
            }
        }
    } catch (error: RarException) {
        throw IOException("unable to decode RAR4 entry", error)
    }

    private class BoundedRarOutput(private val expectedBytes: Long) : java.io.OutputStream() {
        private val output = ByteArrayOutputStream(expectedBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        private var written = 0L

        override fun write(value: Int) = write(byteArrayOf(value.toByte()))

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            require(offset >= 0 && length >= 0 && offset <= buffer.size - length) { "invalid RAR output buffer" }
            val updated = try {
                Math.addExact(written, length.toLong())
            } catch (error: ArithmeticException) {
                throw IOException("RAR entry exceeds safety limit", error)
            }
            if (updated > expectedBytes) throw IOException("RAR entry exceeds safety limit")
            output.write(buffer, offset, length)
            written = updated
        }

        fun bytes(): ByteArray {
            if (written != expectedBytes) throw IOException("truncated RAR entry")
            return output.toByteArray()
        }
    }

    private data class Record(
        val record: ComicArchive.ArchiveRecord,
        val dataOffset: Long,
        val crc32: Long,
        val method: Int,
    )

    private fun scan(file: File): List<Record> {
        RandomAccessFile(file, "r").use { input ->
            val marker = ByteArray(signature.size)
            input.readFully(marker)
            require(marker.contentEquals(signature)) { "only RAR4 archives are supported" }
            val records = mutableListOf<Record>()
            var position = signature.size.toLong()
            var fileEntryCount = 0
            var sawEndMarker = false
            while (position + 7 <= input.length()) {
                input.seek(position)
                readUInt16LE(input, position) // header CRC
                val type = input.readUnsignedByte()
                val flags = readUInt16LE(input, position + 3).toInt()
                val headerSize = readUInt16LE(input, position + 5).toInt()
                require(headerSize >= 7 && position + headerSize <= input.length()) { "invalid RAR header" }
                if (type == 0x7b) {
                    sawEndMarker = true
                    break // end of archive
                }
                if (type == MAIN_HEADER && (flags and MAIN_FLAG_ENCRYPTED) != 0) {
                    throw IOException("encrypted RAR archive is not supported")
                }
                if (type != FILE_HEADER) {
                    val headerStart = position
                    position += headerSize
                    if ((flags and FLAG_HAS_ADD_SIZE) != 0) {
                        val addSize = readUInt32LE(input, headerStart + 7)
                        require(addSize <= input.length() - position) { "invalid RAR data" }
                        position += addSize
                    }
                    continue
                }
                fileEntryCount += 1
                require(fileEntryCount <= 10_000) { "archive has too many entries" }
                val packed = readUInt32LE(input, position + 7)
                val unpacked = readUInt32LE(input, position + 11)
                input.seek(position + 25)
                val method = input.readUnsignedByte()
                val nameSize = readUInt16LE(input, position + 26).toInt()
                val crc = readUInt32LE(input, position + 16)
                val attributes = readUInt32LE(input, position + 28)
                require(nameSize in 1..4096 && position + 32 + nameSize <= input.length()) { "invalid RAR filename" }
                require(32L + nameSize <= headerSize.toLong()) { "invalid RAR header" }
                val nameBytes = ByteArray(nameSize)
                input.seek(position + 32)
                input.readFully(nameBytes)
                val name = decodeName(nameBytes)
                val dataOffset = position + headerSize
                require(dataOffset <= input.length() && packed <= input.length() - dataOffset) { "invalid RAR data" }
                require(safeRarName(name)) { "unsafe archive path" }
                if ((flags and (FLAG_ENCRYPTED or FLAG_HAS_SALT)) != 0) {
                    throw IOException("encrypted RAR entry is not supported")
                }
                if ((flags and (FLAG_SPLIT_BEFORE or FLAG_SPLIT_AFTER)) != 0) {
                    throw IOException("split RAR entry is not supported")
                }
                if ((flags and (FLAG_LARGE or FLAG_UNICODE or FLAG_HAS_ADD_SIZE)) != 0) {
                    throw IOException("unsupported RAR entry flags")
                }
                require(method in METHOD_STORE..0x35) { "unsupported RAR4 compression method" }
                if (method == METHOD_STORE && packed != unpacked) throw IOException("invalid stored RAR entry")
                records += Record(
                    ComicArchive.ArchiveRecord(
                        name = name,
                        sizeBytes = unpacked,
                        compressedSizeBytes = packed,
                        encrypted = false,
                        directory = (attributes and 0x10L) != 0L,
                    ),
                    dataOffset,
                    crc,
                    method,
                )
                position = dataOffset + packed
            }
            require(sawEndMarker) { "RAR end-of-archive header is missing" }
            return records
        }
    }

    private fun safeRarName(name: String): Boolean = name.isNotBlank() && !name.startsWith('/') && !name.contains('\\') && name.split('/').none { it.isBlank() || it == "." || it == ".." } && name.none { it.code < 0x20 || it.code == 0x7f }

    private fun decodeName(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        throw IOException("RAR filename is not valid UTF-8")
    }
    private fun readUInt16LE(input: RandomAccessFile, offset: Long): Long {
        input.seek(offset)
        return input.readUnsignedByte().toLong() or (input.readUnsignedByte().toLong() shl 8)
    }
    private fun readUInt32LE(input: RandomAccessFile, offset: Long): Long { input.seek(offset); return input.readUnsignedByte().toLong() or (input.readUnsignedByte().toLong() shl 8) or (input.readUnsignedByte().toLong() shl 16) or (input.readUnsignedByte().toLong() shl 24) }
}
