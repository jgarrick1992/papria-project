import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

import papria_format_coreFFI

enum FormatCoreNativeBridge {
    static func convertToInternalEpubFile(source: URL, format: String) throws -> URL? {
        let input = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard input.count <= 256 * 1024 * 1024 else { throw FormatCoreNativeBridgeError.inputTooLarge }
        guard let converted = try convertToInternalEpub(format: format, input: input), !converted.isEmpty else { return nil }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria/Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256Digest.hex(input)
        let destination = directory.appendingPathComponent("\(digest).\(format.lowercased()).epub")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try converted.write(to: destination, options: .atomic)
        }
        return destination
    }

    /// Validate the actual comic container through the generated UniFFI API
    /// before the Swift ZIP/libarchive decoder opens it. The callback serves
    /// only exact bounded ranges from the caller-owned file; Rust never sees a
    /// host path or retains this handle after the inspection call.
    static func inspectComicArchive(source: URL, expectedKind: String) throws {
        let inspector = try NativeArchiveByteSource(url: source)
        let kind = try inspector.inspectKind()
        guard kind == expectedKind else { throw FormatCoreNativeBridgeError.invalidArchive }
    }

    /// This C-ABI adapter registers UniFFI's callback vtable directly, avoiding
    /// a second source copy that could drift from the generated framework ABI.
    private final class NativeArchiveByteSource {
        private static let registryLock = NSLock()
        private nonisolated(unsafe) static var nextHandle: UInt64 = 1
        private nonisolated(unsafe) static var registry: [UInt64: NativeArchiveByteSource] = [:]
        private nonisolated(unsafe) static var callbackVtable = UniffiVTableCallbackInterfaceArchiveByteSource(
            length: { handle, output, status in
                guard let source = NativeArchiveByteSource.lookup(handle) else {
                    NativeArchiveByteSource.failCallback(status)
                    return
                }
                output.pointee = source.byteCount
                NativeArchiveByteSource.succeedCallback(status)
            },
            readAt: { handle, offset, length, output, status in
                guard let source = NativeArchiveByteSource.lookup(handle) else {
                    NativeArchiveByteSource.failCallback(status)
                    return
                }
                do {
                    output.pointee = try NativeArchiveByteSource.makeRustBuffer(source.read(offset: offset, length: length))
                    NativeArchiveByteSource.succeedCallback(status)
                } catch {
                    NativeArchiveByteSource.failCallback(status)
                }
            },
            uniffiFree: { handle in NativeArchiveByteSource.remove(handle) }
        )
        private static let callbackRegistered: Void = {
            uniffi_papria_format_core_fn_init_callback_vtable_archivebytesource(&callbackVtable)
        }()

        private let handle: FileHandle
        private let byteCount: UInt64

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.uint64Value > 0,
                  size.uint64Value <= 8 * 1024 * 1024 * 1024 else {
                throw FormatCoreNativeBridgeError.invalidArchive
            }
            self.byteCount = size.uint64Value
            self.handle = try FileHandle(forReadingFrom: url)
        }

        deinit { try? handle.close() }

        func inspectKind() throws -> String {
            _ = Self.callbackRegistered
            let callbackHandle = Self.insert(self)
            defer { Self.remove(callbackHandle) }
            var status = makeStatus()
            let limits = try Self.defaultArchiveLimitsBuffer()
            defer { freeRustBuffer(limits) }
            let output = uniffi_papria_format_core_fn_func_inspect_comic_archive(callbackHandle, limits, &status)
            guard status.code == 0 else {
                let message = takeErrorMessage(&status)
                throw FormatCoreNativeBridgeError.conversionFailed(message)
            }
            defer { freeRustBuffer(output) }
            guard let pointer = output.data, output.len >= 4 else {
                throw FormatCoreNativeBridgeError.invalidArchive
            }
            let data = Data(bytes: pointer, count: Int(output.len))
            let rawKind = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self).bigEndian }
            switch rawKind {
            case 1: return "ZIP"
            case 2: return "RAR"
            case 3: return "SEVEN_ZIP"
            default: throw FormatCoreNativeBridgeError.invalidArchive
            }
        }

        private func read(offset: UInt64, length: UInt32) throws -> [UInt8] {
            let requested = UInt64(length)
            guard requested <= 64 * 1024,
                  offset <= byteCount,
                  requested <= byteCount - offset else {
                throw FormatCoreNativeBridgeError.invalidArchive
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            guard data.count == Int(length) else { throw FormatCoreNativeBridgeError.invalidArchive }
            return Array(data)
        }

        private static func makeRustBuffer(_ bytes: [UInt8]) throws -> RustBuffer {
            var status = FormatCoreNativeBridge.makeStatus()
            let buffer = bytes.withUnsafeBufferPointer { pointer in
                ffi_papria_format_core_rustbuffer_from_bytes(
                    ForeignBytes(len: Int32(pointer.count), data: pointer.baseAddress),
                    &status,
                )
            }
            guard status.code == 0 else {
                let message = FormatCoreNativeBridge.takeErrorMessage(&status)
                throw FormatCoreNativeBridgeError.conversionFailed(message)
            }
            return buffer
        }

        private static func defaultArchiveLimitsBuffer() throws -> RustBuffer {
            var status = FormatCoreNativeBridge.makeStatus()
            let limits = uniffi_papria_format_core_fn_func_default_archive_limits(&status)
            guard status.code == 0 else {
                let message = FormatCoreNativeBridge.takeErrorMessage(&status)
                throw FormatCoreNativeBridgeError.conversionFailed(message)
            }
            return limits
        }

        private static func insert(_ source: NativeArchiveByteSource) -> UInt64 {
            registryLock.lock()
            defer { registryLock.unlock() }
            let handle = nextHandle
            nextHandle += 1
            registry[handle] = source
            return handle
        }

        private static func lookup(_ handle: UInt64) -> NativeArchiveByteSource? {
            registryLock.lock()
            defer { registryLock.unlock() }
            return registry[handle]
        }

        private static func remove(_ handle: UInt64) {
            registryLock.lock()
            registry.removeValue(forKey: handle)
            registryLock.unlock()
        }

        private static func succeedCallback(_ status: UnsafeMutablePointer<RustCallStatus>?) {
            guard let status else { return }
            status.pointee.code = 0
            status.pointee.errorBuf = RustBuffer(capacity: 0, len: 0, data: nil)
        }

        private static func failCallback(_ status: UnsafeMutablePointer<RustCallStatus>?) {
            guard let status else { return }
            // Any callback failure maps to Rust's ArchiveSourceError and then
            // to the public fail-closed ArchiveSafetyError.SourceReadFailed.
            status.pointee.code = 2
            status.pointee.errorBuf = RustBuffer(capacity: 0, len: 0, data: nil)
        }
    }

    private static func convertToInternalEpub(format: String, input: Data) throws -> Data? {
        guard let variant = FormatVariant(rawValue: format.lowercased()) else {
            throw FormatCoreNativeBridgeError.unsupportedFormat(format)
        }
        let formatBuffer = try makeRustBuffer(variant.encoded)
        let inputBuffer = try makeRustBuffer(sequenceBytes(input))
        var status = makeStatus()
        let output = uniffi_papria_format_core_fn_func_convert_to_internal_epub(formatBuffer, inputBuffer, &status)
        guard status.code == 0 else {
            let message = takeErrorMessage(&status)
            throw FormatCoreNativeBridgeError.conversionFailed(message)
        }
        defer { freeRustBuffer(output) }
        return try decodeSequence(output)
    }

    private enum FormatVariant: String {
        case epub, kepub, mobi, azw, azw3, fb2

        var encoded: [UInt8] {
            let value: Int32
            switch self {
            case .epub: value = 1
            case .kepub: value = 2
            case .mobi: value = 3
            case .azw: value = 4
            case .azw3: value = 5
            case .fb2: value = 6
            }
            return withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
    }

    private static func sequenceBytes(_ input: Data) -> [UInt8] {
        let count = Int32(clamping: input.count)
        var bytes = withUnsafeBytes(of: count.bigEndian) { Array($0) }
        bytes.append(contentsOf: input)
        return bytes
    }

    private static func makeRustBuffer(_ bytes: [UInt8]) throws -> RustBuffer {
        var status = makeStatus()
        let buffer = bytes.withUnsafeBufferPointer { pointer in
            ffi_papria_format_core_rustbuffer_from_bytes(
                ForeignBytes(len: Int32(pointer.count), data: pointer.baseAddress),
                &status,
            )
        }
        guard status.code == 0 else {
            let message = takeErrorMessage(&status)
            throw FormatCoreNativeBridgeError.conversionFailed(message)
        }
        return buffer
    }

    private static func decodeSequence(_ buffer: RustBuffer) throws -> Data {
        guard let pointer = buffer.data else { return Data() }
        let raw = Data(bytes: pointer, count: Int(buffer.len))
        guard raw.count >= MemoryLayout<Int32>.size else { throw FormatCoreNativeBridgeError.invalidResult }
        let count = raw.prefix(4).withUnsafeBytes { buffer in
            Int32(bigEndian: buffer.loadUnaligned(as: Int32.self))
        }
        guard count >= 0, raw.count == 4 + Int(count) else { throw FormatCoreNativeBridgeError.invalidResult }
        return Data(raw.dropFirst(4))
    }

    private static func freeRustBuffer(_ buffer: RustBuffer) {
        var status = makeStatus()
        ffi_papria_format_core_rustbuffer_free(buffer, &status)
    }

    private static func makeStatus() -> RustCallStatus {
        RustCallStatus(code: 0, errorBuf: RustBuffer(capacity: 0, len: 0, data: nil))
    }

    private static func takeErrorMessage(_ status: inout RustCallStatus) -> String {
        defer { freeRustBuffer(status.errorBuf) }
        guard let pointer = status.errorBuf.data else { return "Rust format conversion failed" }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: Int(status.errorBuf.len)), encoding: .utf8)
            ?? "Rust format conversion failed"
    }
}

enum FormatCoreNativeBridgeError: LocalizedError {
    case inputTooLarge
    case unsupportedFormat(String)
    case conversionFailed(String)
    case invalidResult
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "文件超过共享格式核心的安全大小限制"
        case .unsupportedFormat(let format): return "共享格式核心不支持格式：\(format)"
        case .conversionFailed(let message): return message
        case .invalidResult: return "共享格式核心返回了无效 EPUB 数据"
        case .invalidArchive: return "共享格式核心拒绝了漫画压缩包"
        }
    }
}

private enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return String(data.hashValue, radix: 16)
        #endif
    }
}
