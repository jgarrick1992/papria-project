import Foundation
import Compression

/// Bounded ZIP reader used by EPUB/KEPUB and CBZ previews.
///
/// It reads the central directory and one member at a time; the complete
/// archive is never copied into memory. RAR/7z are intentionally left to the
/// platform archive adapter so a missing decoder cannot be mistaken for ZIP.
final class PapriaZipArchive {
    struct Entry: Sendable {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16
        let generalPurposeFlags: UInt16
        let crc32: UInt32
        let localHeaderOffset: Int64
    }

    enum Error: Swift.Error {
        case invalidArchive
        case unsupportedCompression
        case unsafePath
        case entryTooLarge
        case decompressionFailed
        case checksumMismatch
    }

    private let handle: FileHandle
    private let fileSize: Int64
    let entries: [Entry]

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = Int64((try? handle.seekToEnd()) ?? 0)
        guard fileSize >= 22 else { throw Error.invalidArchive }
        let tailSize = Int(min(fileSize, 65_557))
        try handle.seek(toOffset: UInt64(fileSize - Int64(tailSize)))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        guard let marker = tail.lastIndex(of: 0x50),
              marker + 3 < tail.count,
              tail[marker + 1] == 0x4b,
              tail[marker + 2] == 0x05,
              tail[marker + 3] == 0x06 else { throw Error.invalidArchive }
        let centralCount = Int(Self.readUInt16(tail, marker + 10))
        let centralSize = Int(Self.readUInt32(tail, marker + 12))
        let centralOffset = Int64(Self.readUInt32(tail, marker + 16))
        guard centralCount <= 10_000, centralSize <= 64 * 1024 * 1024,
              centralOffset >= 0, centralOffset + Int64(centralSize) <= fileSize else { throw Error.invalidArchive }
        try handle.seek(toOffset: UInt64(centralOffset))
        let central = try handle.read(upToCount: centralSize) ?? Data()
        var cursor = 0
        var parsed: [Entry] = []
        var names = Set<String>()
        var totalUncompressed: Int64 = 0
        for _ in 0..<centralCount {
            guard cursor + 46 <= central.count, Self.readUInt32(central, cursor) == 0x02014b50 else { throw Error.invalidArchive }
            let flags = Self.readUInt16(central, cursor + 8)
            let method = Self.readUInt16(central, cursor + 10)
            let crc32 = Self.readUInt32(central, cursor + 16)
            let compressed = Int(Self.readUInt32(central, cursor + 20))
            let uncompressed = Int(Self.readUInt32(central, cursor + 24))
            let nameLength = Int(Self.readUInt16(central, cursor + 28))
            let extraLength = Int(Self.readUInt16(central, cursor + 30))
            let commentLength = Int(Self.readUInt16(central, cursor + 32))
            let localOffset = Int64(Self.readUInt32(central, cursor + 42))
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= central.count, uncompressed <= 256 * 1024 * 1024, compressed >= 0,
                  let name = String(data: central[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  Self.isSafeMember(name) else { throw Error.unsafePath }
            guard flags & 0x0001 == 0 else { throw Error.invalidArchive }
            guard names.insert(name).inserted else { throw Error.invalidArchive }
            guard compressed > 0 || uncompressed == 0,
                  uncompressed <= max(compressed, 1) * 100 else { throw Error.entryTooLarge }
            let (sum, overflow) = totalUncompressed.addingReportingOverflow(Int64(uncompressed))
            guard !overflow, sum <= 1024 * 1024 * 1024 else { throw Error.entryTooLarge }
            totalUncompressed = sum
            parsed.append(Entry(name: name, compressedSize: compressed, uncompressedSize: uncompressed, method: method, generalPurposeFlags: flags, crc32: crc32, localHeaderOffset: localOffset))
            cursor = end
        }
        entries = parsed
    }

    deinit { try? handle.close() }

    func data(for entry: Entry) throws -> Data {
        guard entry.localHeaderOffset >= 0, entry.localHeaderOffset + 30 <= fileSize else { throw Error.invalidArchive }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, Self.readUInt32(header, 0) == 0x04034b50 else { throw Error.invalidArchive }
        let localFlags = Self.readUInt16(header, 6)
        let localMethod = Self.readUInt16(header, 8)
        let localCRC32 = Self.readUInt32(header, 14)
        let localCompressedSize = Int(Self.readUInt32(header, 18))
        let localUncompressedSize = Int(Self.readUInt32(header, 22))
        let nameLength = Int(Self.readUInt16(header, 26))
        let extraLength = Int(Self.readUInt16(header, 28))
        let payloadOffset = entry.localHeaderOffset + 30 + Int64(nameLength + extraLength)
        guard payloadOffset >= 0, payloadOffset + Int64(entry.compressedSize) <= fileSize else { throw Error.invalidArchive }
        guard localFlags == entry.generalPurposeFlags, localMethod == entry.method else { throw Error.invalidArchive }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset + 30))
        let localName = try handle.read(upToCount: nameLength) ?? Data()
        guard localName == Data(entry.name.utf8) else { throw Error.invalidArchive }
        if localFlags & 0x0008 == 0 {
            guard localCRC32 == entry.crc32,
                  localCompressedSize == entry.compressedSize,
                  localUncompressedSize == entry.uncompressedSize else { throw Error.invalidArchive }
        }
        try handle.seek(toOffset: UInt64(payloadOffset))
        let compressed = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard compressed.count == entry.compressedSize else { throw Error.invalidArchive }
        if entry.method == 0 {
            guard compressed.count == entry.uncompressedSize else { throw Error.invalidArchive }
            return try Self.validated(compressed, for: entry)
        }
        guard entry.method == 8 else { throw Error.unsupportedCompression }
        if entry.uncompressedSize == 0 {
            return try Self.validated(Data(), for: entry)
        }
        guard entry.compressedSize > 0,
              entry.compressedSize <= Int.max / 100,
              entry.uncompressedSize <= max(entry.compressedSize * 100, 1) else { throw Error.entryTooLarge }
        var output = Data(count: entry.uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize, source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == entry.uncompressedSize else { throw Error.decompressionFailed }
        return try Self.validated(output, for: entry)
    }

    private static func isSafeMember(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.split(separator: "/").contains("..") && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func validated(_ data: Data, for entry: Entry) throws -> Data {
        guard data.count == entry.uncompressedSize, crc32(data) == entry.crc32 else { throw Error.checksumMismatch }
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24 }
}

/// Shared iOS import gate for the formats declared by the reader contract.
/// Container signatures are checked before a platform decoder sees the file.
enum FormatPolicy {
    static let supportedExtensions: Set<String> = [
        "epub", "kepub", "mobi", "azw", "azw3", "fb2", "pdf",
        "cbz", "cbr", "cb7", "m4b", "m4a", "mp3", "opus", "ogg", "flac",
        "txt", "md"
    ]

    static func validate(fileURL: URL, fileName: String? = nil) throws {
        let name = fileName ?? fileURL.lastPathComponent
        try validateName(name)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw FormatPolicyError.emptyFile }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        let ext = `extension`(of: name)
        switch ext {
        case "epub", "kepub", "cbz":
            guard header.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) || header.starts(with: Data([0x50, 0x4b, 0x05, 0x06])) else { throw FormatPolicyError.signatureMismatch }
        case "cbr":
            guard header.starts(with: Data("Rar!\u{1A}\u{07}".utf8)) else { throw FormatPolicyError.signatureMismatch }
        case "cb7":
            guard header.starts(with: Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) else { throw FormatPolicyError.signatureMismatch }
        case "pdf":
            guard header.starts(with: Data("%PDF-".utf8)) else { throw FormatPolicyError.signatureMismatch }
        default: break
        }
        // Validate the complete archive before content-addressed import. This
        // keeps malformed paths, duplicate members, oversized entries and
        // compression bombs out of the local library, not only out of the
        // later reader view.
        switch ext {
        case "epub", "kepub", "cbz":
            _ = try PapriaZipArchive(url: fileURL)
        case "cbr", "cb7":
            try LibArchiveComic.validate(at: fileURL)
        default:
            break
        }
        switch ext {
        case "cbz": try FormatCoreNativeBridge.inspectComicArchive(source: fileURL, expectedKind: "ZIP")
        case "cbr": try FormatCoreNativeBridge.inspectComicArchive(source: fileURL, expectedKind: "RAR")
        case "cb7": try FormatCoreNativeBridge.inspectComicArchive(source: fileURL, expectedKind: "SEVEN_ZIP")
        default: break
        }
    }

    static func validateName(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || "<>:\"|?*".unicodeScalars.contains($0) }),
              !value.hasSuffix("."), !value.hasSuffix(" ") else { throw FormatPolicyError.invalidName }
        let stem = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"].contains(stem) || stem.range(of: #"^(COM|LPT)[1-9]$"#, options: .regularExpression) != nil
        guard !reserved, supportedExtensions.contains(`extension`(of: value)) else { throw FormatPolicyError.unsupportedFormat }
    }

    static func `extension`(of name: String) -> String {
        name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init)?.lowercased() ?? ""
    }
}

enum FormatPolicyError: LocalizedError {
    case invalidName
    case unsupportedFormat
    case signatureMismatch
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .invalidName: return "文件名不安全"
        case .unsupportedFormat: return "不支持的文件格式"
        case .signatureMismatch: return "文件内容与扩展名不匹配"
        case .emptyFile: return "文件为空或不可读"
        }
    }
}
