import Foundation
import Combine
import Network
import CryptoKit
import Security

struct ImportedTransfer: Sendable {
    let id: String
    let fileURL: URL
    let fileName: String
}

/// A receiver-side snapshot of one upload in the current local-transfer
/// session. This is deliberately not persisted and does not contain either
/// bearer or resume credentials; it exists only so the foreground UI can show
/// the receiver's already-known state without changing the HTTP contract.
enum LocalTransferSessionPhase: Equatable, Sendable {
    case waitingForResume
    case receiving
    case validating
    case importing
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .receiving, .validating, .importing:
            return true
        case .waitingForResume, .completed, .failed, .cancelled:
            return false
        }
    }

    var canCancel: Bool {
        self == .receiving
    }

    var canRetryImport: Bool {
        self == .failed
    }
}

struct LocalTransferSession: Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    let sizeBytes: Int64
    let receivedBytes: Int64
    let phase: LocalTransferSessionPhase
    let failureReason: String?
    fileprivate let order: Int

    var progress: Double? {
        guard sizeBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(sizeBytes)))
    }
}

let localTransferChunkSize: Int64 = 8 * 1024 * 1024

func localTransferRecoveryOffset(actualSize: Int64, totalSize: Int64) -> Int64? {
    guard totalSize > 0,
          actualSize >= 0, actualSize <= totalSize else { return nil }
    if actualSize == totalSize { return totalSize }
    return actualSize - actualSize % localTransferChunkSize
}

/// Persist only this one-way value with an incomplete transfer. It proves
/// ownership of one upload without retaining either the QR bearer or the
/// resume credential in the receiver's persistent state.
func transferResumeTokenHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Compare the persisted digest without an early exit on the first mismatch.
func transferResumeTokenMatches(_ expectedHash: String, _ resumeToken: String) -> Bool {
    let expected = Array(expectedHash.utf8)
    let actual = Array(transferResumeTokenHash(resumeToken).utf8)
    guard expected.count == actual.count else { return false }
    var mismatch: UInt8 = 0
    for index in expected.indices {
        mismatch = mismatch | (expected[index] ^ actual[index])
    }
    return mismatch == 0
}

/// Foreground-only local HTTP receiver. The listener is restricted to Wi-Fi
/// and uses a per-session bearer token. Upload bodies are written as they
/// arrive; an 8 MiB chunk is never assembled as a whole file in memory. The
/// persisted offset is reconciled with the actual `.part` length on launch so
/// a crash cannot make a browser skip bytes or overwrite an unrelated range.
final class LocalTransferReceiver: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var displayAddress = ""
    @Published private(set) var bonjourName = ""
    @Published private(set) var sessionToken = ""
    @Published private(set) var completedCount = 0
    @Published private(set) var transferSessions: [LocalTransferSession] = []

    var hasActiveTransfer: Bool {
        transferSessions.contains { $0.phase.isActive }
    }

    var onImported: (@Sendable (ImportedTransfer) -> Void)?

    private let lock = NSLock()
    private var listener: NWListener?
    private var token = ""
    private var tokenExpiresAt = Date.distantPast
    private var port: UInt16 = 0
    private var cleanupTimer: DispatchSourceTimer?
    private var uploadDirectory: URL
    private var uploads: [String: UploadState] = [:]
    /// Files already moved into content-addressed storage but not yet recorded
    /// in the local library database.  Their session remains `.importing`
    /// until AppEnvironment confirms the database write.
    private var pendingLibraryImports: [String: ImportedTransfer] = [:]
    private var transferSessionRecords: [String: LocalTransferSession] = [:]
    private var processingUploadIDs = Set<String>()
    private var nextTransferSessionOrder = 0
    /// Guards late Network.framework callbacks from an earlier listener from
    /// overwriting the state of a newly started service.
    private var serviceGeneration: UInt64 = 0
    private let contentStore: ContentAddressedStore?

    init(contentStore: ContentAddressedStore? = try? ContentAddressedStore(), uploadDirectory: URL? = nil) {
        self.contentStore = contentStore
        let support = uploadDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria", isDirectory: true)
            .appendingPathComponent("Uploads", isDirectory: true)
        self.uploadDirectory = support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cleanupExpiredUploads()
        loadPersistedUploads()
    }

    deinit {
        listener?.cancel()
        stopCleanupTimer()
    }

    func start() {
        cleanupExpiredUploads()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            publishStartFailure(error)
            return
        }

        // The bearer token belongs only in the QR URL fragment. Bonjour
        // labels are visible to the LAN and must not leak token material.
        let serviceName = "Papria-WiFi"
        newListener.service = NWListener.Service(name: serviceName, type: "_http._tcp")
        let newToken = randomToken()
        let generation: UInt64
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            newListener.cancel()
            return
        }
        token = newToken
        tokenExpiresAt = Date().addingTimeInterval(Self.sessionTTL)
        serviceGeneration &+= 1
        generation = serviceGeneration
        // Record the listener before it starts. This prevents a double tap
        // from creating two LAN services while the first is still resolving.
        listener = newListener
        lock.unlock()
        publishTransferSessions()

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerBecameReady(
                    newListener,
                    generation: generation,
                    token: newToken,
                    serviceName: serviceName
                )
            case .failed(let error):
                self.listenerDidEnd(newListener, generation: generation, error: error)
            case .cancelled:
                self.listenerDidEnd(newListener, generation: generation, error: nil)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let handler = TransferConnection(connection: connection,
                                              begin: { [weak self] request in self?.begin(request) ?? .immediate(.serverError) },
                                              finish: { [weak self] request, sink in self?.finish(request, sink: sink) ?? .serverError },
                                              interrupted: { [weak self] request, sink in self?.connectionInterrupted(request, sink: sink) })
            handler.start()
        }
        publishStartingState(for: newListener, generation: generation)
        startCleanupTimer()
        newListener.start(queue: DispatchQueue(label: "nz.papria.local-transfer", qos: .userInitiated))
    }

    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        serviceGeneration &+= 1
        let stoppedGeneration = serviceGeneration
        token = ""
        tokenExpiresAt = .distantPast
        port = 0
        markReceivingTransfersWaitingForResumeLocked()
        lock.unlock()
        current?.cancel()
        stopCleanupTimer()
        publishTransferSessions()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isStoppedService(generation: stoppedGeneration) else { return }
            self.isRunning = false
            self.isStarting = false
            self.displayAddress = ""
            self.sessionToken = ""
            self.bonjourName = ""
        }
    }

    private func listenerBecameReady(
        _ candidate: NWListener,
        generation: UInt64,
        token: String,
        serviceName: String
    ) {
        lock.lock()
        guard listener === candidate, serviceGeneration == generation else {
            lock.unlock()
            return
        }
        port = candidate.port?.rawValue ?? 0
        let address = makeDisplayAddress()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentService(candidate, generation: generation) else { return }
            self.sessionToken = token
            self.displayAddress = address
            self.bonjourName = "\(serviceName).local"
            self.isStarting = false
            self.isRunning = true
        }
    }

    private func listenerDidEnd(_ candidate: NWListener, generation: UInt64, error: Error?) {
        lock.lock()
        guard listener === candidate, serviceGeneration == generation else {
            lock.unlock()
            return
        }
        listener = nil
        serviceGeneration &+= 1
        let stoppedGeneration = serviceGeneration
        token = ""
        tokenExpiresAt = .distantPast
        port = 0
        markReceivingTransfersWaitingForResumeLocked()
        lock.unlock()
        stopCleanupTimer()
        publishTransferSessions()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isStoppedService(generation: stoppedGeneration) else { return }
            self.isRunning = false
            self.isStarting = false
            self.sessionToken = ""
            self.bonjourName = ""
            self.displayAddress = error.map { "Wi-Fi 传书服务不可用：\($0.localizedDescription)" } ?? ""
        }
    }

    private func publishStartingState(for candidate: NWListener, generation: UInt64) {
        let update = { [weak self] in
            guard let self,
                  self.isCurrentService(candidate, generation: generation),
                  !self.isRunning else { return }
            self.isStarting = true
            self.displayAddress = ""
            self.sessionToken = ""
            self.bonjourName = ""
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func publishStartFailure(_ error: Error) {
        lock.lock()
        let canPublish = listener == nil
        let generation = serviceGeneration
        lock.unlock()
        guard canPublish else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isStoppedService(generation: generation),
                  !self.isRunning,
                  !self.isStarting else { return }
            self.displayAddress = "Wi-Fi 传书服务不可用：\(error.localizedDescription)"
        }
    }

    private func isCurrentService(_ candidate: NWListener, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listener === candidate && serviceGeneration == generation
    }

    private func isStoppedService(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listener == nil && serviceGeneration == generation
    }

    private func markReceivingTransfersWaitingForResumeLocked() {
        for (id, record) in transferSessionRecords where record.phase == .receiving {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: record.receivedBytes,
                phase: .waitingForResume,
                failureReason: nil,
                order: record.order
            )
        }
    }

    /// Cancels an upload from this receiving device without exposing the
    /// browser's resume token to the app UI. Once validation/import has begun,
    /// cancellation is intentionally unavailable so an already accepted file
    /// cannot be half-imported.
    func cancelTransfer(id: String) {
        let upload: UploadState?
        lock.lock()
        guard let record = transferSessionRecords[id], record.phase.canCancel,
              let activeUpload = uploads.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        upload = activeUpload
        transferSessionRecords[id] = LocalTransferSession(
            id: record.id,
            fileName: record.fileName,
            sizeBytes: record.sizeBytes,
            receivedBytes: record.receivedBytes,
            phase: .cancelled,
            failureReason: nil,
            order: record.order
        )
        lock.unlock()

        if let upload {
            try? FileManager.default.removeItem(at: upload.tempURL)
        }
        try? FileManager.default.removeItem(at: metadataURL(for: id))
        publishTransferSessions()
    }

    /// Re-runs the real validation/import step for a fully received file that
    /// previously failed. This does not synthesize a result or restart an HTTP
    /// upload; it only operates on the receiver's existing temporary file.
    func retryFailedImport(id: String) {
        lock.lock()
        let pendingLibraryImport: ImportedTransfer?
        if let record = transferSessionRecords[id],
           record.phase.canRetryImport,
           let pending = pendingLibraryImports[id] {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: record.receivedBytes,
                phase: .importing,
                failureReason: nil,
                order: record.order
            )
            pendingLibraryImport = pending
        } else {
            pendingLibraryImport = nil
        }
        let canRetry: Bool
        if pendingLibraryImport != nil {
            canRetry = false
        } else if let upload = uploads[id] {
            canRetry = transferSessionRecords[id]?.phase.canRetryImport == true
                && upload.receivedBytes == upload.sizeBytes
                && !processingUploadIDs.contains(id)
        } else {
            canRetry = false
        }
        lock.unlock()
        if let pendingLibraryImport {
            publishTransferSessions()
            DispatchQueue.main.async { [weak self] in self?.onImported?(pendingLibraryImport) }
            return
        }
        guard canRetry else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.completeKnownUpload(id: id)
        }
    }

    /// Removes only a failed or locally cancelled transfer record and its
    /// temporary upload data. Completed library files are never deleted here.
    func removeTransferRecord(id: String) {
        let upload: UploadState?
        lock.lock()
        guard let record = transferSessionRecords[id],
              record.phase == .failed || record.phase == .cancelled else {
            lock.unlock()
            return
        }
        upload = uploads.removeValue(forKey: id)
        transferSessionRecords.removeValue(forKey: id)
        pendingLibraryImports.removeValue(forKey: id)
        lock.unlock()

        if let upload {
            try? FileManager.default.removeItem(at: upload.tempURL)
        }
        try? FileManager.default.removeItem(at: metadataURL(for: id))
        publishTransferSessions()
    }

    /** Called only after AppEnvironment has committed the imported file to the local library. */
    func markLibraryImportCompleted(id: String) {
        lock.lock()
        guard let record = transferSessionRecords[id], pendingLibraryImports.removeValue(forKey: id) != nil else {
            lock.unlock()
            return
        }
        transferSessionRecords[id] = LocalTransferSession(
            id: record.id,
            fileName: record.fileName,
            sizeBytes: record.sizeBytes,
            receivedBytes: record.sizeBytes,
            phase: .completed,
            failureReason: nil,
            order: record.order
        )
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.completedCount += 1 }
        publishTransferSessions()
    }

    /** Keep a truthful failed session when local-library persistence rejects an imported file. */
    func markLibraryImportFailed(id: String, reason: String) {
        lock.lock()
        guard let record = transferSessionRecords[id], pendingLibraryImports[id] != nil else {
            lock.unlock()
            return
        }
        transferSessionRecords[id] = LocalTransferSession(
            id: record.id,
            fileName: record.fileName,
            sizeBytes: record.sizeBytes,
            receivedBytes: record.receivedBytes,
            phase: .failed,
            failureReason: reason,
            order: record.order
        )
        lock.unlock()
        publishTransferSessions()
    }

    private func begin(_ request: HTTPRequest) -> BodySink {
        lock.lock()
        let expectedToken = token
        let expiresAt = tokenExpiresAt
        lock.unlock()

        if request.method == "GET", request.path == "/" {
            return .memory
        }
        guard request.headers["authorization"] == "Bearer \(expectedToken)", !expectedToken.isEmpty, Date() < expiresAt else {
            return .immediate(.unauthorized)
        }
        if request.method == "POST", request.path == "/api/uploads" {
            return .memory
        }
        guard let resumeToken = request.headers[Self.resumeTokenHeader], !resumeToken.isEmpty else {
            return .immediate(.unauthorized)
        }
        if request.method == "GET", request.path.hasPrefix("/api/uploads/") {
            return .memory(resumeToken: resumeToken)
        }
        if request.method == "POST", request.path.hasSuffix("/complete") {
            return .memory(resumeToken: resumeToken)
        }
        if request.method == "DELETE", request.path.hasPrefix("/api/uploads/") {
            return .memory(resumeToken: resumeToken)
        }
        if request.method == "PUT", request.path.contains("/chunks/") {
            guard let match = request.path.range(of: #"^/api/uploads/([A-Za-z0-9-]+)/chunks/([0-9]+)$"#, options: .regularExpression),
                  let parsed = parseChunkPath(String(request.path[match])) else {
                return .immediate(.badRequest("invalid chunk path"))
            }
            guard let range = parseContentRange(request.headers["content-range"]),
                  range.length <= localTransferChunkSize,
                  request.contentLength == range.length,
                  let upload = lockedUpload(parsed.uploadID, resumeToken: resumeToken), upload.sizeBytes == range.total,
                  range.start == upload.receivedBytes,
                  range.start < range.total, range.end < range.total,
                  range.start % localTransferChunkSize == 0,
                  parsed.chunkIndex == range.start / localTransferChunkSize else {
                return .immediate(.badRequest("invalid content range"))
            }
            let fileHandle: FileHandle
            do {
                fileHandle = try FileHandle(forWritingTo: upload.tempURL)
                try fileHandle.seek(toOffset: UInt64(range.start))
            } catch {
                return .immediate(.serverError)
            }
            var chunkRange = range
            chunkRange = ByteRange(start: range.start, end: range.end, total: range.total, chunkIndex: parsed.chunkIndex)
            let sink = BodySink.file(fileHandle: fileHandle, expectedBytes: range.length, resumeToken: resumeToken)
            sink.metadata = .chunk(uploadID: parsed.uploadID, range: chunkRange)
            updateTransferSession(
                id: parsed.uploadID,
                receivedBytes: range.start,
                phase: .receiving,
                failureReason: nil
            )
            sink.onWrite = { [weak self] writtenBytes in
                self?.updateTransferSession(
                    id: parsed.uploadID,
                    receivedBytes: range.start + writtenBytes,
                    phase: .receiving,
                    failureReason: nil
                )
            }
            return sink
        }
        return .immediate(.notFound)
    }

    private func finish(_ request: HTTPRequest, sink: BodySink) -> HTTPResponse {
        if let immediate = sink.immediateResponse { return immediate }
        if let writeError = sink.writeError {
            markReceivingFailed(sink: sink, error: writeError)
            return .serverError
        }
        if request.method == "GET", request.path == "/" {
            return .html(uploadPage())
        }
        if request.method == "POST", request.path == "/api/uploads" {
            return createUpload(body: sink.data())
        }
        guard let resumeToken = sink.resumeToken else { return .unauthorized }
        if request.method == "GET", let id = uploadID(path: request.path) {
            return statusUpload(id: id, resumeToken: resumeToken)
        }
        if request.method == "DELETE", let id = uploadID(path: request.path) {
            return cancelUpload(id: id, resumeToken: resumeToken)
        }
        if request.method == "PUT", let metadata = sink.metadata, case .chunk(let id, let range) = metadata {
            return finishChunk(id: id, range: range, sink: sink, resumeToken: resumeToken)
        }
        if request.method == "POST", let id = completeUploadID(path: request.path) {
            return completeUpload(id: id, resumeToken: resumeToken)
        }
        return .notFound
    }

    private func createUpload(body: Data) -> HTTPResponse {
        struct Request: Decodable { let fileName: String; let sizeBytes: Int64 }
        guard let request = try? JSONDecoder().decode(Request.self, from: body), request.sizeBytes > 0,
              request.sizeBytes <= 16 * 1024 * 1024 * 1024,
              let safeName = sanitize(request.fileName), !safeName.isEmpty else {
            return .badRequest("invalid upload request")
        }
        if let contentStore {
            do { try contentStore.ensureCapacity(for: request.sizeBytes) }
            catch { return .badRequest("insufficient storage") }
        } else {
            return .serverError
        }
        let id = UUID().uuidString.lowercased()
        let resumeToken = randomToken(byteCount: 32)
        let url = uploadDirectory.appendingPathComponent("\(id).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return .serverError }
        let state = UploadState(id: id, fileName: safeName, sizeBytes: request.sizeBytes, tempURL: url, resumeTokenHash: transferResumeTokenHash(resumeToken))
        lock.lock()
        uploads[id] = state
        storeTransferSessionLocked(
            id: id,
            fileName: safeName,
            sizeBytes: request.sizeBytes,
            receivedBytes: 0,
            phase: .receiving,
            failureReason: nil
        )
        lock.unlock()
        persist(state)
        publishTransferSessions()
        return .json(["uploadId": id, "resumeToken": resumeToken, "fileName": safeName, "sizeBytes": request.sizeBytes, "receivedBytes": 0], status: 201)
    }

    private func statusUpload(id: String, resumeToken: String) -> HTTPResponse {
        guard let upload = lockedUpload(id, resumeToken: resumeToken) else { return .notFound }
        let received = upload.receivedBytes
        return .json(["uploadId": id, "fileName": upload.fileName, "sizeBytes": upload.sizeBytes, "receivedBytes": received, "completed": received == upload.sizeBytes])
    }

    private func finishChunk(id: String, range: ByteRange, sink: BodySink, resumeToken: String) -> HTTPResponse {
        guard let upload = lockedUpload(id, resumeToken: resumeToken), sink.writeError == nil, sink.receivedBytes == range.length else { return .badRequest("incomplete chunk") }
        sink.closeFile()
        upload.add(range: range)
        persist(upload)
        updateTransferSession(
            id: id,
            receivedBytes: upload.receivedBytes,
            phase: .receiving,
            failureReason: nil
        )
        return .json(["uploadId": id, "chunkIndex": range.chunkIndex, "receivedBytes": upload.receivedBytes])
    }

    private func completeUpload(id: String, resumeToken: String) -> HTTPResponse {
        guard let upload = lockedUpload(id, resumeToken: resumeToken), upload.receivedBytes == upload.sizeBytes else { return .conflict("upload is incomplete") }
        return completeKnownUpload(id: id)
    }

    /// Processes a file already known to the receiver. HTTP callers reach this
    /// only after token validation; the local retry action reaches it only for
    /// a fully received failed import.
    private func completeKnownUpload(id: String) -> HTTPResponse {
        guard let upload = beginImport(id: id) else { return .conflict("upload is unavailable") }
        guard let contentStore else {
            markImportFailed(id: id, upload: upload, reason: "本机书库不可用，无法导入该文件。")
            return .serverError
        }
        do {
            try FormatPolicy.validate(fileURL: upload.tempURL, fileName: upload.fileName)
            switch upload.fileName.lowercased().split(separator: ".").last.map(String.init) {
            case "epub", "kepub", "cbz":
                _ = try PapriaZipArchive(url: upload.tempURL)
            case "cbr", "cb7":
                try LibArchiveComic.validate(at: upload.tempURL)
            default:
                break
            }
            guard isStillProcessing(id: id, upload: upload) else {
                return .conflict("upload was cancelled")
            }
            updateTransferSession(
                id: id,
                receivedBytes: upload.receivedBytes,
                phase: .importing,
                failureReason: nil
            )
            let imported = try contentStore.importFile(at: upload.tempURL)
            try? FileManager.default.removeItem(at: upload.tempURL)
            let importedTransfer = ImportedTransfer(id: id, fileURL: imported.url, fileName: upload.fileName)
            lock.lock()
            uploads.removeValue(forKey: id)
            processingUploadIDs.remove(id)
            pendingLibraryImports[id] = importedTransfer
            if let record = transferSessionRecords[id] {
                transferSessionRecords[id] = LocalTransferSession(
                    id: record.id,
                    fileName: record.fileName,
                    sizeBytes: record.sizeBytes,
                    receivedBytes: record.sizeBytes,
                    phase: .importing,
                    failureReason: nil,
                    order: record.order
                )
            }
            lock.unlock()
            try? FileManager.default.removeItem(at: metadataURL(for: id))
            let callback = onImported
            DispatchQueue.main.async {
                callback?(importedTransfer)
            }
            publishTransferSessions()
            return .json(["uploadId": id, "hash": imported.hash, "sizeBytes": imported.sizeBytes], status: 201)
        } catch {
            markImportFailed(id: id, upload: upload, error: error)
            return .serverError
        }
    }

    private func cancelUpload(id: String, resumeToken: String) -> HTTPResponse {
        guard let upload = lockedUpload(id, resumeToken: resumeToken) else { return .notFound }
        try? FileManager.default.removeItem(at: upload.tempURL)
        try? FileManager.default.removeItem(at: metadataURL(for: id))
        lock.lock()
        uploads.removeValue(forKey: id)
        processingUploadIDs.remove(id)
        if let record = transferSessionRecords[id] {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: record.receivedBytes,
                phase: .cancelled,
                failureReason: nil,
                order: record.order
            )
        }
        lock.unlock()
        publishTransferSessions()
        return .empty(status: 204)
    }

    private func lockedUpload(_ id: String, resumeToken: String) -> UploadState? {
        lock.lock(); defer { lock.unlock() }
        guard let upload = uploads[id], transferResumeTokenMatches(upload.resumeTokenHash, resumeToken) else { return nil }
        return upload
    }

    private func beginImport(id: String) -> UploadState? {
        lock.lock()
        guard let upload = uploads[id], upload.receivedBytes == upload.sizeBytes,
              !processingUploadIDs.contains(id), let record = transferSessionRecords[id] else {
            lock.unlock()
            return nil
        }
        processingUploadIDs.insert(id)
        transferSessionRecords[id] = LocalTransferSession(
            id: record.id,
            fileName: record.fileName,
            sizeBytes: record.sizeBytes,
            receivedBytes: record.sizeBytes,
            phase: .validating,
            failureReason: nil,
            order: record.order
        )
        lock.unlock()
        publishTransferSessions()
        return upload
    }

    private func isStillProcessing(id: String, upload: UploadState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return processingUploadIDs.contains(id) && uploads[id] === upload
    }

    private func markImportFailed(id: String, upload: UploadState, error: Error) {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = detail.isEmpty ? "文件校验或导入失败，请重新导入或移除该文件。" : "文件校验或导入失败：\(detail)"
        markImportFailed(id: id, upload: upload, reason: reason)
    }

    private func markImportFailed(id: String, upload: UploadState, reason: String) {
        lock.lock()
        processingUploadIDs.remove(id)
        if uploads[id] === upload, let record = transferSessionRecords[id] {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: record.receivedBytes,
                phase: .failed,
                failureReason: reason,
                order: record.order
            )
        }
        lock.unlock()
        publishTransferSessions()
    }

    private func markReceivingFailed(sink: BodySink, error: Error) {
        guard let metadata = sink.metadata, case .chunk(let id, _) = metadata else { return }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = detail.isEmpty ? "本机无法继续写入文件，请在上传设备重试或移除该文件。" : "本机写入失败：\(detail)"
        lock.lock()
        if let record = transferSessionRecords[id], uploads[id] != nil {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: record.receivedBytes,
                phase: .failed,
                failureReason: reason,
                order: record.order
            )
        }
        lock.unlock()
        publishTransferSessions()
    }

    private func connectionInterrupted(_ request: HTTPRequest?, sink: BodySink?) {
        guard let request, request.method == "PUT",
              let metadata = sink?.metadata, case .chunk(let id, _) = metadata else { return }
        lock.lock()
        if let upload = uploads[id], let record = transferSessionRecords[id], record.phase == .receiving {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: upload.receivedBytes,
                phase: .waitingForResume,
                failureReason: nil,
                order: record.order
            )
        }
        lock.unlock()
        publishTransferSessions()
    }

    private func updateTransferSession(
        id: String,
        receivedBytes: Int64,
        phase: LocalTransferSessionPhase,
        failureReason: String?
    ) {
        lock.lock()
        if let record = transferSessionRecords[id], uploads[id] != nil {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: receivedBytes,
                phase: phase,
                failureReason: failureReason,
                order: record.order
            )
        }
        lock.unlock()
        publishTransferSessions()
    }

    private func storeTransferSessionLocked(
        id: String,
        fileName: String,
        sizeBytes: Int64,
        receivedBytes: Int64,
        phase: LocalTransferSessionPhase,
        failureReason: String?
    ) {
        if let record = transferSessionRecords[id] {
            transferSessionRecords[id] = LocalTransferSession(
                id: record.id,
                fileName: fileName,
                sizeBytes: sizeBytes,
                receivedBytes: receivedBytes,
                phase: phase,
                failureReason: failureReason,
                order: record.order
            )
            return
        }
        nextTransferSessionOrder += 1
        transferSessionRecords[id] = LocalTransferSession(
            id: id,
            fileName: fileName,
            sizeBytes: sizeBytes,
            receivedBytes: receivedBytes,
            phase: phase,
            failureReason: failureReason,
            order: nextTransferSessionOrder
        )
    }

    private func publishTransferSessions() {
        let update = { [weak self] in
            guard let self else { return }
            self.transferSessions = self.sessionSnapshot()
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func sessionSnapshot() -> [LocalTransferSession] {
        lock.lock(); defer { lock.unlock() }
        return transferSessionRecords.values.sorted { $0.order < $1.order }
    }

    private func parseChunkPath(_ path: String) -> (uploadID: String, chunkIndex: Int64)? {
        let components = path.split(separator: "/")
        guard components.count == 5, let index = Int64(components[4]) else { return nil }
        return (String(components[2]), index)
    }

    private func uploadID(path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == "api", components[1] == "uploads" else { return nil }
        return String(components[2])
    }

    private func completeUploadID(path: String) -> String? {
        guard path.hasSuffix("/complete") else { return nil }
        let components = path.split(separator: "/")
        guard components.count == 4, components[0] == "api", components[1] == "uploads", components[3] == "complete" else { return nil }
        return String(components[2])
    }

    private func parseContentRange(_ value: String?) -> ByteRange? {
        guard let value, let match = value.range(of: #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#, options: .regularExpression) else { return nil }
        let parts = value[match].split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        guard parts.count == 4,
              let start = Int64(parts[1]), let end = Int64(parts[2]), let total = Int64(parts[3]),
              total > 0, start >= 0, end >= start, end < total else { return nil }
        return ByteRange(start: start, end: end, total: total, chunkIndex: 0)
    }

    private func sanitize(_ value: String) -> String? {
        let base = URL(fileURLWithPath: value).lastPathComponent
        let filtered = base.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !"<>:\"/\\|?*".unicodeScalars.contains($0) }
        let result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        let device = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"].contains(device) || device.range(of: #"^(COM|LPT)[1-9]$"#, options: .regularExpression) != nil
        guard !result.isEmpty, result != ".", result != "..", !result.hasSuffix("."), !result.hasSuffix(" "), !reserved, result.utf8.count <= 255 else { return nil }
        return result
    }

    private func randomToken(byteCount: Int = 16) -> String {
        precondition(byteCount > 0)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator is still cryptographically seeded;
            // this branch is only for an unavailable Security RNG (e.g. a
            // severely damaged simulator environment).
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static let sessionTTL: TimeInterval = 10 * 60
    private static let resumeTokenHeader = "x-papria-resume-token"

    private func startCleanupTimer() {
        stopCleanupTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nz.papria.local-transfer-cleanup", qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60 * 60)
        timer.setEventHandler { [weak self] in self?.cleanupExpiredUploads() }
        cleanupTimer = timer
        timer.resume()
    }

    private func stopCleanupTimer() {
        cleanupTimer?.setEventHandler {}
        cleanupTimer?.cancel()
        cleanupTimer = nil
    }

    private func makeDisplayAddress() -> String {
        let host = localIPv4Address() ?? "127.0.0.1"
        return "http://\(host):\(port)/#\(token)"
    }

    private func localIPv4Address() -> String? {
        var fallbackAddress: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let interface = String(cString: item.pointee.ifa_name)
            guard let socketAddress = item.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                current = item.pointee.ifa_next
                continue
            }
            // Prefer the normal Wi-Fi interface, but keep simulator/enterprise
            // Wi-Fi interface names working when en0 is not present.
            if ["en0", "bridge100", "en1"].contains(interface) || fallbackAddress == nil {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let value = String(cString: host)
                if value != "127.0.0.1" {
                    if interface == "en0" || interface == "bridge100" || interface == "en1" { return value }
                    fallbackAddress = value
                }
            }
            current = item.pointee.ifa_next
        }
        return fallbackAddress
    }

    private func cleanupExpiredUploads() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(at: uploadDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var expiredIDs = Set<String>()
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                expiredIDs.insert(file.deletingPathExtension().lastPathComponent)
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard !expiredIDs.isEmpty else { return }
        lock.lock()
        expiredIDs.forEach {
            uploads.removeValue(forKey: $0)
            transferSessionRecords.removeValue(forKey: $0)
            processingUploadIDs.remove($0)
        }
        lock.unlock()
        publishTransferSessions()
    }

    private func metadataURL(for id: String) -> URL { uploadDirectory.appendingPathComponent("\(id).json") }

    private func persist(_ upload: UploadState) {
        let record = PersistedUpload(id: upload.id, fileName: upload.fileName, sizeBytes: upload.sizeBytes, receivedBytes: upload.receivedBytes, resumeTokenHash: upload.resumeTokenHash, modifiedAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(record) else { return }
        let temporary = uploadDirectory.appendingPathComponent(".\(upload.id).json.part")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: metadataURL(for: upload.id).path) { try FileManager.default.removeItem(at: metadataURL(for: upload.id)) }
            try FileManager.default.moveItem(at: temporary, to: metadataURL(for: upload.id))
        } catch { try? FileManager.default.removeItem(at: temporary) }
    }

    private func loadPersistedUploads() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: uploadDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(PersistedUpload.self, from: data),
                  record.sizeBytes > 0,
                  record.receivedBytes >= 0, record.receivedBytes <= record.sizeBytes,
                  !record.resumeTokenHash.isEmpty else {
                let part = uploadDirectory.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).part")
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: part)
                continue
            }
            let temp = uploadDirectory.appendingPathComponent("\(record.id).part")
            guard FileManager.default.fileExists(atPath: temp.path),
                  let actualSize = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value,
                  actualSize >= 0, actualSize <= record.sizeBytes else {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: temp)
                continue
            }
            // A crash may occur after the file write but before metadata is
            // persisted. Trust only complete 8 MiB chunks (or a complete
            // file), so we preserve durable bytes without ever resuming from
            // the middle of a chunk.
            guard let received = localTransferRecoveryOffset(actualSize: actualSize, totalSize: record.sizeBytes) else {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: temp)
                continue
            }
            if received < actualSize,
               let handle = try? FileHandle(forWritingTo: temp) {
                try? handle.truncate(atOffset: UInt64(received))
                try? handle.close()
            }
            let state = UploadState(id: record.id, fileName: record.fileName, sizeBytes: record.sizeBytes, tempURL: temp, resumeTokenHash: record.resumeTokenHash, receivedBytes: received)
            lock.lock()
            uploads[record.id] = state
            storeTransferSessionLocked(
                id: record.id,
                fileName: record.fileName,
                sizeBytes: record.sizeBytes,
                receivedBytes: received,
                phase: .waitingForResume,
                failureReason: nil
            )
            lock.unlock()
            if received != record.receivedBytes { persist(state) }
        }
    }

    private func uploadPage() -> String {
        // The QR bearer is only in the fragment and is sent as Authorization,
        // so it never appears in an HTTP request path. A separately generated
        // per-upload resume token is persisted only by the sender browser.
        """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Papria Wi-Fi 传书</title><style>body{font:17px -apple-system;padding:24px}button{font-size:18px;padding:10px}#drop{border:2px dashed #888;padding:2em;text-align:center}#status{white-space:pre-wrap}</style>
        <h1>Papria Wi-Fi 传书</h1><p id="drop">拖拽文件到这里，或点击选择文件</p><input id="files" type="file" multiple><button id="upload">开始上传</button><pre id="status"></pre>
        <script>
        const token=location.hash.slice(1), chunk=8388608, out=document.querySelector('#status'), drop=document.querySelector('#drop'), queue=[]; let running=false;
        const headers={'Authorization':'Bearer '+token};
        async function send(file){
          const key='papria-upload:'+file.name+':'+file.size+':'+file.lastModified; let u=null;
          try { const saved=JSON.parse(localStorage.getItem(key)||'null'); if(saved&&typeof saved.uploadId==='string'&&typeof saved.resumeToken==='string') u=saved; else if(saved) localStorage.removeItem(key); } catch (_) { localStorage.removeItem(key); }
          if(u){const state=await fetch('/api/uploads/'+encodeURIComponent(u.uploadId),{headers:{...headers,'X-Papria-Resume-Token':u.resumeToken}}); if(state.ok) u={...u,...await state.json()}; else {localStorage.removeItem(key);u=null;}}
          if(!u){const create=await fetch('/api/uploads',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({fileName:file.name,sizeBytes:file.size})});
            if(!create.ok) throw Error('create '+create.status); u=await create.json(); localStorage.setItem(key,JSON.stringify({uploadId:u.uploadId,resumeToken:u.resumeToken}));}
          for(let offset=u.receivedBytes;offset<file.size;offset+=chunk){const end=Math.min(file.size,offset+chunk)-1;
            const body=await file.slice(offset,end+1).arrayBuffer(); const r=await fetch('/api/uploads/'+u.uploadId+'/chunks/'+Math.floor(offset/chunk),{method:'PUT',headers:{...headers,'X-Papria-Resume-Token':u.resumeToken,'Content-Range':`bytes ${offset}-${end}/${file.size}`},body}); if(!r.ok) throw Error('chunk '+r.status); out.textContent=file.name+': '+(end+1)+'/'+file.size;}
          const done=await fetch('/api/uploads/'+u.uploadId+'/complete',{method:'POST',headers:{...headers,'X-Papria-Resume-Token':u.resumeToken}}); if(!done.ok) throw Error('complete '+done.status); localStorage.removeItem(key); out.textContent=file.name+' ✓';
        }
        async function drain(){if(running)return; running=true; while(queue.length){const f=queue.shift(); try{await send(f)}catch(e){out.textContent+='\n'+f.name+': '+e}} running=false;}
        function enqueue(files){queue.push(...files); out.textContent='队列 '+queue.length+' 个文件'; drain();}
        document.querySelector('#upload').onclick=()=>enqueue([...document.querySelector('#files').files]);
        drop.ondragover=e=>{e.preventDefault();drop.style.background='#eee'}; drop.ondragleave=()=>drop.style.background='';
        drop.ondrop=e=>{e.preventDefault();drop.style.background='';enqueue([...e.dataTransfer.files]);};
        </script>
        """
    }
}

private final class UploadState: @unchecked Sendable {
    let id: String
    let fileName: String
    let sizeBytes: Int64
    let tempURL: URL
    let resumeTokenHash: String
    private var ranges: [ClosedRange<Int64>] = []
    private let lock = NSLock()

    init(id: String, fileName: String, sizeBytes: Int64, tempURL: URL, resumeTokenHash: String, receivedBytes: Int64 = 0) {
        self.id = id; self.fileName = fileName; self.sizeBytes = sizeBytes; self.tempURL = tempURL; self.resumeTokenHash = resumeTokenHash
        if receivedBytes > 0 { ranges = [0...(receivedBytes - 1)] }
    }

    var receivedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        var merged: [ClosedRange<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged.reduce(0) { $0 + $1.upperBound - $1.lowerBound + 1 }
    }

    func add(range: ByteRange) {
        lock.lock(); ranges.append(range.start...range.end); lock.unlock()
    }
}

private struct PersistedUpload: Codable {
    let id: String
    let fileName: String
    let sizeBytes: Int64
    let receivedBytes: Int64
    let resumeTokenHash: String
    let modifiedAt: TimeInterval
}

private struct ByteRange: Sendable {
    let start: Int64
    let end: Int64
    let total: Int64
    let chunkIndex: Int64
    var length: Int64 { end - start + 1 }
}

private struct ChunkPath: Sendable {
    let uploadID: String
    let chunkIndex: Int64
}

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int
}

private struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    static let serverError = HTTPResponse(status: 500, reason: "Internal Server Error", headers: [:], body: Data("server error".utf8))
    static let unauthorized = HTTPResponse(status: 401, reason: "Unauthorized", headers: ["WWW-Authenticate": "Bearer"], body: Data("unauthorized".utf8))
    static let notFound = HTTPResponse(status: 404, reason: "Not Found", headers: [:], body: Data("not found".utf8))
    static func badRequest(_ value: String) -> HTTPResponse { HTTPResponse(status: 400, reason: "Bad Request", headers: [:], body: Data(value.utf8)) }
    static func conflict(_ value: String) -> HTTPResponse { HTTPResponse(status: 409, reason: "Conflict", headers: [:], body: Data(value.utf8)) }
    static func empty(status: Int) -> HTTPResponse { HTTPResponse(status: status, reason: "No Content", headers: [:], body: Data()) }
    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let reason = status == 201 ? "Created" : "OK"
        return (try? HTTPResponse(status: status, reason: reason, headers: ["Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: object))) ?? .serverError
    }
    static func html(_ value: String) -> HTTPResponse { HTTPResponse(status: 200, reason: "OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(value.utf8)) }
}

private final class BodySink: @unchecked Sendable {
    enum Metadata { case chunk(uploadID: String, range: ByteRange) }
    private var buffer = Data()
    private var fileHandle: FileHandle?
    private let expectedBytes: Int64?
    let resumeToken: String?
    private(set) var receivedBytes: Int64 = 0
    private var lastReportedBytes: Int64 = 0
    private(set) var writeError: Error?
    var metadata: Metadata?
    var onWrite: ((Int64) -> Void)?
    let immediateResponse: HTTPResponse?

    private init(fileHandle: FileHandle?, expectedBytes: Int64?, resumeToken: String?, immediateResponse: HTTPResponse?) {
        self.fileHandle = fileHandle; self.expectedBytes = expectedBytes; self.resumeToken = resumeToken; self.immediateResponse = immediateResponse
    }
    static var memory: BodySink { BodySink(fileHandle: nil, expectedBytes: nil, resumeToken: nil, immediateResponse: nil) }
    static func memory(resumeToken: String) -> BodySink { BodySink(fileHandle: nil, expectedBytes: nil, resumeToken: resumeToken, immediateResponse: nil) }
    static func file(fileHandle: FileHandle, expectedBytes: Int64, resumeToken: String) -> BodySink { BodySink(fileHandle: fileHandle, expectedBytes: expectedBytes, resumeToken: resumeToken, immediateResponse: nil) }
    static func immediate(_ response: HTTPResponse) -> BodySink { BodySink(fileHandle: nil, expectedBytes: nil, resumeToken: nil, immediateResponse: response) }
    func append(_ data: Data) {
        guard immediateResponse == nil else { return }
        if let fileHandle {
            do {
                try fileHandle.write(contentsOf: data)
                receivedBytes += Int64(data.count)
                if (expectedBytes.map { receivedBytes == $0 } ?? false)
                    || receivedBytes - lastReportedBytes >= 256 * 1024 {
                    lastReportedBytes = receivedBytes
                    onWrite?(receivedBytes)
                }
            } catch { writeError = error }
        } else {
            buffer.append(data)
            receivedBytes += Int64(data.count)
        }
    }
    func data() -> Data { buffer }
    func closeFile() { try? fileHandle?.close(); fileHandle = nil }
}

private final class TransferConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let begin: (HTTPRequest) -> BodySink
    private let finish: (HTTPRequest, BodySink) -> HTTPResponse
    private let interrupted: (HTTPRequest?, BodySink?) -> Void
    private var data = Data()
    private var request: HTTPRequest?
    private var sink: BodySink?
    private var remaining = 0

    init(
        connection: NWConnection,
        begin: @escaping (HTTPRequest) -> BodySink,
        finish: @escaping (HTTPRequest, BodySink) -> HTTPResponse,
        interrupted: @escaping (HTTPRequest?, BodySink?) -> Void
    ) {
        self.connection = connection; self.begin = begin; self.finish = finish; self.interrupted = interrupted
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.connection.cancel() } }
        connection.start(queue: DispatchQueue(label: "nz.papria.transfer.connection", qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let chunk { self.data.append(chunk) }
            if error != nil {
                self.interrupted(self.request, self.sink)
                self.connection.cancel()
                return
            }
            do { try self.consume() } catch { self.send(.badRequest("malformed request")); return }
            if isComplete && (self.request == nil || self.remaining > 0) {
                self.interrupted(self.request, self.sink)
                self.connection.cancel()
            } else if self.request == nil { self.receive() }
        }
    }

    private func consume() throws {
        if request == nil {
            guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { return }
            guard marker.lowerBound <= 16 * 1024 else { throw HTTPParseError.invalid }
            let headerData = data.subdata(in: 0..<marker.lowerBound)
            data.removeSubrange(0..<marker.upperBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { throw HTTPParseError.invalid }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let first = lines.first else { throw HTTPParseError.invalid }
            let parts = first.split(separator: " ")
            guard parts.count >= 2 else { throw HTTPParseError.invalid }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { headers[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 8 * 1024 * 1024 else { throw HTTPParseError.invalid }
            let parsed = HTTPRequest(method: String(parts[0]), path: String(parts[1].split(separator: "?").first ?? ""), headers: headers, contentLength: length)
            request = parsed; remaining = length
            sink = begin(parsed)
            if let immediate = sink?.immediateResponse { send(immediate); return }
        }
        guard let request, let sink else { return }
        if remaining > 0 {
            let count = min(remaining, data.count)
            if count > 0 {
                sink.append(data.subdata(in: 0..<count)); data.removeSubrange(0..<count); remaining -= count
            }
        }
        if remaining == 0 {
            sink.closeFile()
            send(finish(request, sink))
        } else { receive() }
    }

    private func send(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\nConnection: close\r\nContent-Length: \(response.body.count)\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var output = Data(head.utf8); output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
    }
}

private enum HTTPParseError: Error { case invalid }
