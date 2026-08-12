import Foundation
import Combine
import BackgroundTasks
import UIKit
import CryptoKit
import Network

@MainActor
final class AppEnvironment: ObservableObject {
    enum DownloadPhase: Equatable, Sendable {
        case waitingForNetwork(received: Int64, total: Int64)
        case waitingForWiFi(received: Int64, total: Int64)
        case downloading(received: Int64, total: Int64)
        case paused(received: Int64, total: Int64)
        case failed(message: String, received: Int64, total: Int64)
        case completed
    }

    /// A task only exists after a user has started a download, a persisted
    /// unfinished download has been restored, or a downloaded local file is
    /// still present. Browsing a BookOrbit detail never creates one.
    struct DownloadTaskItem: Identifiable {
        let bookID: Int64
        let file: RemoteFileRecord
        let localPublication: LocalPublication?
        /// The order in which this task entered the active task model. For
        /// restored work this preserves the store's existing task order; for
        /// new work it is assigned when the user explicitly starts a download.
        let queueOrder: Int

        var id: Int64 { file.id }
    }

    /// Files returned by a successful BookOrbit detail request. The cache is
    /// intentionally separate from the live request result: it only contains
    /// values already written to the local SQLite store and is therefore safe
    /// to use while the device is offline.
    struct CachedBookOrbitDetail: Equatable, Sendable {
        let bookID: Int64
        let files: [RemoteFileRecord]
    }

    @Published var isRestoring = false
    @Published var isAuthenticated = false
    @Published var serverURL = ""
    @Published var username = ""
    @Published private(set) var serverCertificateSha256: String?
    @Published private(set) var publications: [LocalPublication] = []
    @Published private(set) var remoteBooks: [RemoteBookRecord] = []
    @Published private(set) var cachedBookOrbitDetails: [Int64: CachedBookOrbitDetail] = [:]
    @Published private(set) var coverURLs: [Int64: URL] = [:]
    @Published private(set) var nativeFormatCoreContractVersion: UInt32?
    @Published var isLoadingLibrary = false
    /// The latest real BookOrbit connection/catalog error. This is separate
    /// from `globalError` so a file import or another subsystem cannot make
    /// the BookOrbit status line report a connection failure it did not have.
    @Published private(set) var bookOrbitConnectionError: String?
    @Published var globalError: String?
    @Published private(set) var isNetworkAvailable = false
    @Published private(set) var downloadStates: [Int64: DownloadPhase] = [:]
    /// Measured from BookOrbit's real byte-progress callback. A value is
    /// transient by design: it becomes zero when no transfer is active and is
    /// never fabricated from an estimated file size or elapsed task time.
    @Published private(set) var downloadBytesPerSecond: [Int64: Int64] = [:]
    @Published private(set) var downloadTaskItems: [DownloadTaskItem] = []

    let apiClient = BookOrbitAPIClient()
    let localStore: LocalLibraryStore
    let transfer: LocalTransferReceiver
    let audioPlayback: AudioPlaybackService
    private let progressSync: ProgressSyncService
    private var backgroundTaskRegistered = false
    private var downloadTasks: [Int64: Task<Void, Never>] = [:]
    private var downloadFiles: [Int64: RemoteFileRecord] = [:]
    private var downloadBookIDs: [Int64: Int64] = [:]
    private var downloadQueueOrders: [Int64: Int] = [:]
    private var nextDownloadQueueOrder = 1
    private var cancelledDownloadIDs = Set<Int64>()
    private let pathMonitor = NWPathMonitor()
    private var isOnWiFi = false
    private let onlyWiFiDownloadsDefaultsKey = "papria.onlyWiFiDownloads"

    init() {
        AudioPlaybackService.installAudioFallbackFactory(
            provider: "MobileVLCKit 3.7.2",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: true,
                supportsPlaybackRate: true,
            ),
        ) { track in
            guard track.url.isFileURL, track.headers.isEmpty else { return nil }
            return MobileVLCAudioFallback()
        }
        nativeFormatCoreContractVersion = FormatCoreRuntime.linkedContractVersion()
        do {
            localStore = try LocalLibraryStore()
        } catch {
            // Application Support is expected to be writable on iOS.  Keep a
            // deterministic temporary fallback so Wi-Fi/local reading still
            // works if a simulator has a damaged container.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("Papria", isDirectory: true)
            localStore = try! LocalLibraryStore(databaseURL: fallback.appendingPathComponent("papria.sqlite3"), contentURL: fallback.appendingPathComponent("Content", isDirectory: true))
        }
        transfer = LocalTransferReceiver(contentStore: try? ContentAddressedStore())
        audioPlayback = AudioPlaybackService()
        audioPlayback.refreshRemoteTrack = { [apiClient] track in
            let request = try await apiClient.refreshedAudioStreamRequest(fileId: track.fileId)
            guard let url = request.url else { throw BookOrbitAPIError.invalidResponse }
            return AudioPlaybackService.Track(url: url, title: track.title, fileId: track.fileId, headers: request.allHTTPHeaderFields ?? [:], durationHint: track.durationHint)
        }
        progressSync = ProgressSyncService(api: apiClient, store: localStore)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isNetworkAvailable = path.status == .satisfied
                self.isOnWiFi = self.isNetworkAvailable && path.usesInterfaceType(.wifi)
                guard self.isNetworkAvailable, self.isAuthenticated else { return }
                // A foreground network transition is the fastest safe retry;
                // the BGProcessingTask remains the fallback when the app is
                // suspended before this callback can run.
                await self.syncPendingProgress()
                self.scheduleBackgroundSync()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "nz.papria.network-monitor"))
        transfer.onImported = { [weak self] imported in
            guard let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.localStore.importLocalFile(at: imported.fileURL, title: imported.fileName, source: "wifi")
                    await self.reloadLocalLibrary()
                    self.transfer.markLibraryImportCompleted(id: imported.id)
                } catch {
                    self.transfer.markLibraryImportFailed(id: imported.id, reason: error.localizedDescription)
                    self.globalError = error.localizedDescription
                }
            }
        }
    }

    func registerBackgroundSync() {
        guard !backgroundTaskRegistered else { return }
        backgroundTaskRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "nz.papria.app.progress-sync", using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task { @MainActor in
                await self?.syncPendingProgress()
            }
            task.expirationHandler = { work.cancel() }
            Task { @MainActor in
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
                self?.scheduleBackgroundSync()
            }
        }
    }

    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: "nz.papria.app.progress-sync")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func restoreSession() async {
        isRestoring = true
        defer { isRestoring = false }
        let profile = await loadServerProfile()
        serverURL = profile?.serverURL ?? ""
        username = profile?.username ?? ""
        serverCertificateSha256 = profile?.certificateSha256
        if let profile {
            do {
                isAuthenticated = try await apiClient.restore(profile: profile)
                bookOrbitConnectionError = nil
            } catch {
                isAuthenticated = false
                bookOrbitConnectionError = error.localizedDescription
            }
            // The saved catalog and file details are local, non-secret data.
            // Restore them even when a cold launch cannot restore the network
            // session, so offline BookOrbit detail pages retain the exact
            // files from their last successful fetch.
            await restoreCachedBookOrbitCatalog()
        }
        // A user may explicitly keep the non-secret catalog cache while
        // logged out. It remains browseable from the BookOrbit tab.
        if profile == nil {
            await restoreCachedBookOrbitCatalog()
        }
        await reloadLocalLibrary()
        if isAuthenticated {
            if isNetworkAvailable {
                await refreshRemoteLibrary()
            }
            await restorePendingDownloads()
        }
    }

    func connect(serverURL: String, username: String, password: String, certificateSha256: String? = nil, httpConfirmationTarget: String? = nil) async {
        do {
            let session = try await apiClient.login(serverURL: serverURL, username: username, password: password,
                                                    certificateSha256: certificateSha256,
                                                    httpConfirmationTarget: httpConfirmationTarget)
            let profile = ServerProfile(serverURL: session.serverURL, username: session.username,
                                        certificateSha256: certificateSha256,
                                        httpConfirmationTarget: httpConfirmationTarget)
            do {
                try await localStore.saveServerProfile(profile)
            } catch {
                // Do not leave a live session without durable endpoint
                // metadata. Keychain cleanup remains owned by APIClient.
                await apiClient.logout()
                throw error
            }
            self.serverURL = profile.serverURL
            self.username = profile.username
            self.serverCertificateSha256 = profile.certificateSha256
            isAuthenticated = true
            bookOrbitConnectionError = nil
            await restoreCachedBookOrbitCatalog()
            if isNetworkAvailable {
                await refreshRemoteLibrary()
            }
            await restorePendingDownloads()
            await progressSync.syncPending()
        } catch {
            bookOrbitConnectionError = error.localizedDescription
            globalError = error.localizedDescription
        }
    }

    func disconnect(keepOfflineCache: Bool) async {
        await apiClient.logout()
        do {
            try await localStore.deleteServerProfile()
        } catch {
            // The network session is still cleared even if the local profile
            // could not be removed; surface the persistence error so the user
            // can retry instead of silently retaining stale metadata.
            globalError = error.localizedDescription
        }
        isAuthenticated = false
        bookOrbitConnectionError = nil
        serverURL = ""
        username = ""
        serverCertificateSha256 = nil
        remoteBooks = []
        cachedBookOrbitDetails = [:]
        coverURLs = [:]
        if keepOfflineCache {
            // Re-read precisely the persisted cache after clearing transient
            // state so the logged-out BookOrbit tab stays available offline.
            await restoreCachedBookOrbitCatalog()
        } else {
            do {
                try await localStore.clearBookOrbitCatalogCache()
            } catch {
                globalError = error.localizedDescription
            }
            clearCachedCovers()
        }
    }

    private func clearCachedCovers() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria/Covers", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// SQLite is the sole source of truth for the non-secret server profile.
    private func loadServerProfile() async -> ServerProfile? {
        try? await localStore.serverProfile()
    }

    /// Loads the last successfully persisted BookOrbit catalog before any
    /// network request. This is deliberately a local-store read, so a cold
    /// launch with an unavailable path still exposes only real cached data.
    private func restoreCachedBookOrbitCatalog() async {
        do {
            let cachedBooks = try await localStore.remoteBooks()
            remoteBooks = cachedBooks
            await restoreCachedBookOrbitDetails(for: cachedBooks)
        } catch {
            globalError = error.localizedDescription
        }
    }

    private func restoreCachedBookOrbitDetails(for books: [RemoteBookRecord]) async {
        var restored: [Int64: CachedBookOrbitDetail] = [:]
        for book in books {
            do {
                let files = try await localStore.remoteFiles(bookId: book.id)
                guard !files.isEmpty else { continue }
                restored[book.id] = CachedBookOrbitDetail(bookID: book.id, files: files)
            } catch {
                // Keep the catalog readable when one stale detail row is
                // malformed. The next successful detail request will replace
                // that book's cache.
                continue
            }
        }
        cachedBookOrbitDetails = restored
    }

    /// The state-layer accessor for an offline BookOrbit detail. It never
    /// invokes the API and is nil when no successful detail was cached.
    func cachedBookOrbitDetail(bookID: Int64) -> CachedBookOrbitDetail? {
        cachedBookOrbitDetails[bookID]
    }

    private func updateCachedBookOrbitFiles(bookID: Int64, files: [RemoteFileRecord]) {
        let existing = cachedBookOrbitDetails[bookID]?.files ?? []
        var values = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for file in files { values[file.id] = file }
        let resolved = values.values.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
        cachedBookOrbitDetails[bookID] = CachedBookOrbitDetail(bookID: bookID, files: resolved)
    }

    private func replaceCachedBookOrbitFiles(bookID: Int64, files: [RemoteFileRecord]) {
        cachedBookOrbitDetails[bookID] = CachedBookOrbitDetail(bookID: bookID, files: files)
    }

    /// All BookOrbit download entry points flow through this method. The
    /// Wi-Fi policy is read from the same AppStorage-backed UserDefaults key
    /// as SettingsView each time a queued task checks connectivity.
    func startDownload(file: RemoteFileRecord, bookId: Int64) {
        downloadTasks[file.id]?.cancel()
        cancelledDownloadIDs.remove(file.id)
        downloadFiles[file.id] = file
        downloadBookIDs[file.id] = bookId
        _ = queueOrder(for: file.id)
        downloadBytesPerSecond.removeValue(forKey: file.id)
        downloadStates[file.id] = waitingPhase(received: currentDownloadedBytes(for: file.id), total: file.sizeBytes)
        rebuildDownloadTaskItems()
        downloadTasks[file.id] = Task { [weak self] in
            await self?.performDownload(file: file, bookId: bookId)
        }
    }

    private func performDownload(file: RemoteFileRecord, bookId: Int64) async {
        let part = downloadPartURL(for: file.id)
        let progressBox = DownloadProgressBox()
        var retryCount = 0

        do {
            try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await localStore.saveRemoteFiles(bookId: bookId, files: [file])
            updateCachedBookOrbitFiles(bookID: bookId, files: [file])
            try await localStore.beginDownload(fileId: file.id, partURL: part, totalBytes: file.sizeBytes)
            progressBox.reset(received: currentDownloadedBytes(for: file.id))

            while retryCount < 3 {
                try Task.checkCancellation()

                if let waiting = waitingPhaseIfNeeded(received: progressBox.get(), total: file.sizeBytes) {
                    downloadStates[file.id] = waiting
                    try? await localStore.setDownloadState(fileId: file.id, state: "queued")
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                do {
                    try await localStore.beginDownload(fileId: file.id, partURL: part, totalBytes: file.sizeBytes)
                    let existingSize = currentDownloadedBytes(for: file.id)
                    progressBox.reset(received: existingSize)
                    if existingSize == file.sizeBytes {
                        // A process may have been killed after the final byte
                        // was written but before the import was committed.
                        try Task.checkCancellation()
                        _ = try await localStore.importDownloadedFile(
                            at: part,
                            title: file.fileName,
                            format: file.format,
                            remoteBookId: bookId,
                            remoteFileId: file.id
                        )
                        try await localStore.finishDownload(fileId: file.id)
                        try? FileManager.default.removeItem(at: part)
                        downloadStates[file.id] = .completed
                        downloadBytesPerSecond.removeValue(forKey: file.id)
                        downloadTasks.removeValue(forKey: file.id)
                        await reloadLocalLibrary()
                        return
                    }

                    downloadStates[file.id] = .downloading(received: existingSize, total: file.sizeBytes)
                    downloadBytesPerSecond[file.id] = 0
                    let result = try await apiClient.download(fileId: file.id, partURL: part, expectedSize: file.sizeBytes) { [weak self] received, total in
                        let bytesPerSecond = progressBox.record(received: received)
                        Task { @MainActor in
                            self?.downloadStates[file.id] = .downloading(received: received, total: total)
                            self?.downloadBytesPerSecond[file.id] = bytesPerSecond
                            try? await self?.localStore.updateDownload(fileId: file.id, offset: received, totalBytes: total)
                        }
                    }
                    try Task.checkCancellation()
                    _ = try await localStore.importDownloadedFile(
                        at: result.partURL,
                        title: file.fileName,
                        format: file.format,
                        remoteBookId: bookId,
                        remoteFileId: file.id
                    )
                    try await localStore.finishDownload(fileId: file.id)
                    try? FileManager.default.removeItem(at: result.partURL)
                    downloadStates[file.id] = .completed
                    downloadBytesPerSecond.removeValue(forKey: file.id)
                    downloadTasks.removeValue(forKey: file.id)
                    await reloadLocalLibrary()
                    return
                } catch is CancellationError {
                    await finishCancelledOrPausedDownload(fileId: file.id, received: progressBox.get(), total: file.sizeBytes)
                    return
                } catch {
                    let received = progressBox.get()
                    if !isNetworkAvailable {
                        downloadStates[file.id] = .waitingForNetwork(received: received, total: file.sizeBytes)
                        downloadBytesPerSecond[file.id] = 0
                        try? await localStore.setDownloadState(fileId: file.id, state: "queued")
                        continue
                    }
                    retryCount += 1
                    if retryCount < 3 {
                        // NWPath still reports a usable network. Do not label
                        // a server/transport retry as "等待网络"; that label is
                        // reserved for an actual unsatisfied network path.
                        downloadStates[file.id] = .downloading(received: received, total: file.sizeBytes)
                        downloadBytesPerSecond[file.id] = 0
                        try? await localStore.setDownloadState(fileId: file.id, state: "queued")
                        try await Task.sleep(nanoseconds: UInt64(retryCount) * 1_000_000_000)
                    } else {
                        let message = error.localizedDescription
                        try? await localStore.updateDownload(fileId: file.id, offset: received, totalBytes: file.sizeBytes, error: message)
                        downloadStates[file.id] = .failed(message: message, received: received, total: file.sizeBytes)
                        downloadBytesPerSecond[file.id] = 0
                    }
                }
            }
        } catch is CancellationError {
            await finishCancelledOrPausedDownload(fileId: file.id, received: progressBox.get(), total: file.sizeBytes)
            return
        } catch {
            let received = progressBox.get()
            let message = error.localizedDescription
            try? await localStore.updateDownload(fileId: file.id, offset: received, totalBytes: file.sizeBytes, error: message)
            downloadStates[file.id] = .failed(message: message, received: received, total: file.sizeBytes)
            downloadBytesPerSecond[file.id] = 0
        }

        downloadTasks.removeValue(forKey: file.id)
        rebuildDownloadTaskItems()
    }

    /// Persist file metadata whenever a detail response is opened so a
    /// resumable task can be reconstructed after a process restart.
    func rememberRemoteFiles(bookId: Int64, files: [RemoteFileRecord]) async {
        do {
            try await localStore.saveRemoteFiles(bookId: bookId, files: files)
            replaceCachedBookOrbitFiles(bookID: bookId, files: files)
        } catch {
            globalError = error.localizedDescription
        }
    }

    private func restorePendingDownloads() async {
        guard let tasks = try? await localStore.pendingDownloads() else { return }
        for task in tasks {
            guard task.state != "cancelled" else { continue }
            guard let lookup = try? await localStore.remoteFileWithBook(fileId: task.fileId) else { continue }
            downloadFiles[task.fileId] = lookup.file
            downloadBookIDs[task.fileId] = lookup.bookId
            _ = queueOrder(for: task.fileId)
            switch task.state {
            case "paused":
                downloadStates[task.fileId] = .paused(received: task.offsetBytes, total: task.totalBytes)
            case "failed":
                downloadStates[task.fileId] = .failed(message: task.error ?? "下载失败", received: task.offsetBytes, total: task.totalBytes)
            case "queued", "downloading":
                startDownload(file: lookup.file, bookId: lookup.bookId)
            default:
                break
            }
        }
        rebuildDownloadTaskItems()
    }

    func pauseDownload(fileId: Int64) {
        let progress = downloadProgress(for: fileId)
        downloadStates[fileId] = .paused(received: progress.received, total: progress.total)
        downloadBytesPerSecond[fileId] = 0
        Task { [localStore] in
            try? await localStore.setDownloadState(fileId: fileId, state: "paused")
        }
        downloadTasks[fileId]?.cancel()
    }

    func resumeDownload(fileId: Int64, bookId: Int64) {
        guard let file = downloadFiles[fileId] else { return }
        startDownload(file: file, bookId: bookId)
    }

    /// Cancel removes the partial data and hides the task permanently until a
    /// user explicitly starts the same file again. The database row is kept in
    /// its existing schema with a terminal state so a process restart cannot
    /// resurrect a cancelled task.
    func cancelDownload(fileId: Int64) {
        cancelledDownloadIDs.insert(fileId)
        downloadTasks[fileId]?.cancel()
        downloadTasks.removeValue(forKey: fileId)
        downloadStates.removeValue(forKey: fileId)
        downloadBytesPerSecond.removeValue(forKey: fileId)
        downloadFiles.removeValue(forKey: fileId)
        downloadBookIDs.removeValue(forKey: fileId)
        downloadQueueOrders.removeValue(forKey: fileId)
        let part = downloadPartURL(for: fileId)
        Task { [localStore] in
            try? await localStore.setDownloadState(fileId: fileId, state: "cancelled")
            try? FileManager.default.removeItem(at: part)
        }
        rebuildDownloadTaskItems()
    }

    func deleteFailedDownload(fileId: Int64) {
        cancelDownload(fileId: fileId)
    }

    func removeDownloadedFile(_ publication: LocalPublication) async {
        await deletePublication(publication)
        if let fileId = publication.remoteFileId {
            downloadStates.removeValue(forKey: fileId)
            downloadBytesPerSecond.removeValue(forKey: fileId)
            downloadFiles.removeValue(forKey: fileId)
            downloadBookIDs.removeValue(forKey: fileId)
            rebuildDownloadTaskItems()
        }
    }

    func clearCompletedDownloadTasks() {
        let completed = downloadTaskItems.compactMap { item -> Int64? in
            guard downloadStates[item.id] == .completed else { return nil }
            return item.id
        }
        guard !completed.isEmpty else { return }
        // Completed rows are the existing persistent task model. Deleting
        // them only clears task history; it deliberately leaves the local
        // publication/content object in the library.
        Task { [weak self, localStore] in
            do {
                try await localStore.clearCompletedDownloads()
                guard let self else { return }
                for fileID in completed {
                    guard self.downloadStates[fileID] == .completed else { continue }
                    self.downloadStates.removeValue(forKey: fileID)
                    self.downloadBytesPerSecond.removeValue(forKey: fileID)
                    self.downloadFiles.removeValue(forKey: fileID)
                    self.downloadBookIDs.removeValue(forKey: fileID)
                    self.downloadQueueOrders.removeValue(forKey: fileID)
                }
                self.rebuildDownloadTaskItems()
            } catch {
                self?.globalError = error.localizedDescription
            }
        }
    }

    private var onlyWiFiDownloads: Bool {
        UserDefaults.standard.bool(forKey: onlyWiFiDownloadsDefaultsKey)
    }

    private func downloadPartURL(for fileId: Int64) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria/Downloads/\(fileId).part")
    }

    private func currentDownloadedBytes(for fileId: Int64) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: downloadPartURL(for: fileId).path)
        return max(0, (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private func downloadProgress(for fileId: Int64) -> (received: Int64, total: Int64) {
        let fallback = max(0, downloadFiles[fileId]?.sizeBytes ?? 0)
        switch downloadStates[fileId] {
        case .waitingForNetwork(let received, let total),
             .waitingForWiFi(let received, let total),
             .downloading(let received, let total),
             .paused(let received, let total),
             .failed(_, let received, let total):
            return (received, max(total, fallback))
        case .completed, .none:
            return (currentDownloadedBytes(for: fileId), fallback)
        }
    }

    private func waitingPhase(received: Int64, total: Int64) -> DownloadPhase {
        if !isNetworkAvailable {
            return .waitingForNetwork(received: received, total: total)
        }
        if onlyWiFiDownloads && !isOnWiFi {
            return .waitingForWiFi(received: received, total: total)
        }
        // The transfer can start immediately. Showing "等待网络" while a
        // satisfied path is already available would make the state untrue.
        return .downloading(received: received, total: total)
    }

    private func waitingPhaseIfNeeded(received: Int64, total: Int64) -> DownloadPhase? {
        guard !isNetworkAvailable else {
            if onlyWiFiDownloads && !isOnWiFi {
                return .waitingForWiFi(received: received, total: total)
            }
            return nil
        }
        return .waitingForNetwork(received: received, total: total)
    }

    private func finishCancelledOrPausedDownload(fileId: Int64, received: Int64, total: Int64) async {
        downloadTasks.removeValue(forKey: fileId)
        if cancelledDownloadIDs.contains(fileId) {
            return
        }
        try? await localStore.setDownloadState(fileId: fileId, state: "paused")
        downloadStates[fileId] = .paused(received: received, total: total)
        downloadBytesPerSecond[fileId] = 0
        rebuildDownloadTaskItems()
    }

    /// Uses only the existing task model's ordering. It is intentionally not
    /// derived from a filename, file size, or a synthesized priority.
    private func queueOrder(for fileId: Int64) -> Int {
        if let existing = downloadQueueOrders[fileId] { return existing }
        let assigned = nextDownloadQueueOrder
        nextDownloadQueueOrder += 1
        downloadQueueOrders[fileId] = assigned
        return assigned
    }

    /// Rebuilds the visible task list exclusively from a real in-memory
    /// download, a persisted unfinished row, or a local BookOrbit publication.
    /// Remote file metadata saved while browsing is deliberately not enough.
    private func rebuildDownloadTaskItems() {
        var items: [Int64: DownloadTaskItem] = [:]

        var localPublicationsByFileID: [Int64: LocalPublication] = [:]
        for publication in publications {
            if let fileID = publication.remoteFileId {
                localPublicationsByFileID[fileID] = publication
            }
        }

        for (fileId, file) in downloadFiles where !cancelledDownloadIDs.contains(fileId) {
            guard downloadStates[fileId] != nil, let bookID = downloadBookIDs[fileId] else { continue }
            items[fileId] = DownloadTaskItem(
                bookID: bookID,
                file: file,
                localPublication: localPublicationsByFileID[fileId],
                queueOrder: queueOrder(for: fileId)
            )
        }

        downloadTaskItems = items.values.sorted {
            if $0.queueOrder != $1.queueOrder { return $0.queueOrder < $1.queueOrder }
            return $0.id < $1.id
        }
    }

    /// Restores the task center before network work begins. Paused and failed
    /// rows therefore remain actionable after an app relaunch, including when
    /// the device is currently offline.
    private func restoreDownloadTaskSnapshot() async {
        let pending = (try? await localStore.pendingDownloads()) ?? []
        let completed = (try? await localStore.completedDownloads()) ?? []

        for task in pending + completed {
            guard task.state != "cancelled",
                  let lookup = try? await localStore.remoteFileWithBook(fileId: task.fileId) else { continue }
            downloadFiles[task.fileId] = lookup.file
            downloadBookIDs[task.fileId] = lookup.bookId
            _ = queueOrder(for: task.fileId)
            guard downloadStates[task.fileId] == nil else { continue }
            switch task.state {
            case "completed":
                downloadStates[task.fileId] = .completed
                downloadBytesPerSecond.removeValue(forKey: task.fileId)
            case "paused":
                downloadStates[task.fileId] = .paused(received: task.offsetBytes, total: task.totalBytes)
                downloadBytesPerSecond[task.fileId] = 0
            case "failed":
                downloadStates[task.fileId] = .failed(
                    message: task.error ?? "下载失败",
                    received: task.offsetBytes,
                    total: task.totalBytes
                )
                downloadBytesPerSecond[task.fileId] = 0
            case "queued", "downloading":
                downloadStates[task.fileId] = waitingPhase(received: task.offsetBytes, total: task.totalBytes)
                downloadBytesPerSecond[task.fileId] = 0
            default:
                break
            }
        }
        rebuildDownloadTaskItems()
    }

    func reloadLocalLibrary() async {
        do {
            publications = try await localStore.publications()
            await restoreDownloadTaskSnapshot()
        }
        catch { globalError = error.localizedDescription }
    }

    /// Deletes a local reference/content object only. No BookOrbit delete
    /// endpoint is called, so a later refresh can download the remote file.
    func deletePublication(_ publication: LocalPublication) async {
        do {
            try await localStore.deletePublication(publication)
            await reloadLocalLibrary()
            if let fileId = publication.remoteFileId {
                downloadStates.removeValue(forKey: fileId)
                downloadBytesPerSecond.removeValue(forKey: fileId)
                downloadFiles.removeValue(forKey: fileId)
                downloadBookIDs.removeValue(forKey: fileId)
                downloadQueueOrders.removeValue(forKey: fileId)
                rebuildDownloadTaskItems()
            }
        } catch { globalError = error.localizedDescription }
    }

    func refreshRemoteLibrary() async {
        guard isAuthenticated, isNetworkAvailable else { return }
        isLoadingLibrary = true
        bookOrbitConnectionError = nil
        defer { isLoadingLibrary = false }
        do {
            var page = 0
            var allBooks: [RemoteBookRecord] = []
            var total = Int.max
            while allBooks.count < total && page < 10_000 {
                let query = BookQueryRequest(sort: [BookSort(field: "updatedAt", dir: "desc")], pagination: Pagination(page: page, size: 100), collapseSeries: false, q: nil)
                let response = try await apiClient.queryBooks(request: query)
                total = response.total
                allBooks.append(contentsOf: response.items)
                if response.items.isEmpty { break }
                page += 1
            }
            var seen = Set<Int64>()
            remoteBooks = allBooks.filter { seen.insert($0.id).inserted }
            try await localStore.replaceRemoteBooks(remoteBooks)
            await restoreCachedBookOrbitDetails(for: remoteBooks)
            // Covers are intentionally best-effort: a book without a cover
            // remains fully readable and does not make the library request fail.
            for book in remoteBooks.prefix(50) { await loadCover(bookId: book.id) }
        } catch {
            bookOrbitConnectionError = error.localizedDescription
            globalError = error.localizedDescription
        }
    }

    func loadCover(bookId: Int64) async {
        guard coverURLs[bookId] == nil, isAuthenticated, isNetworkAvailable else { return }
        do {
            let bytes = try await apiClient.fetchCover(bookId: bookId)
            guard let image = UIImage(data: bytes), let png = image.pngData() else { return }
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Papria/Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let destination = directory.appendingPathComponent("\(bookId)-\(digest).png")
            if !FileManager.default.fileExists(atPath: destination.path) { try png.write(to: destination, options: .atomic) }
            coverURLs[bookId] = destination
        } catch {
            // Covers are optional; do not surface a failed image request as a
            // failed library refresh.
        }
    }

    func saveReadingPosition(fileId: Int64, progress: FileProgressPayload) async {
        do {
            try await localStore.saveProgress(fileId: fileId, progress: progress)
        } catch { globalError = error.localizedDescription }
    }

    /// Only a publication backed by a BookOrbit file may use the remote
    /// progress endpoint.  Wi‑Fi/local imports deliberately keep their
    /// negative, content-addressed progress key local even while another
    /// BookOrbit account is signed in.
    func progressForOpening(fileId: Int64, remoteFileId: Int64?) async -> FileProgressPayload? {
        if isAuthenticated, let remoteFileId {
            return await progressSync.pullFileBeforeOpen(fileId: remoteFileId)
        }
        return try? await localStore.loadProgress(fileId: fileId)
    }

    /// Audio progress follows the same local/remote boundary as document
    /// progress. `remoteBookId` is intentionally explicit at call sites so a
    /// local Wi‑Fi book can never trigger a BookOrbit request by accident.
    func audioProgressForOpening(bookId: Int64, remoteBookId: Int64?) async -> AudioProgressPayload? {
        if isAuthenticated, let remoteBookId {
            return await progressSync.pullAudioBeforeOpen(bookId: remoteBookId)
        }
        return try? await localStore.loadAudioProgress(bookId: bookId)
    }

    func audioSettingsForOpening(bookId: Int64) async -> AudioPlaybackSettings? {
        try? await localStore.loadAudioSettings(bookId: bookId)
    }

    func saveAudioSettings(bookId: Int64, rate: Double, sleepUntil: Date?) async {
        try? await localStore.saveAudioSettings(bookId: bookId, rate: rate, sleepUntil: sleepUntil)
    }

    /// Flush the application-owned player before the scene is suspended. The
    /// player remains alive for lock-screen/background playback; this only
    /// snapshots the current position and lets the local outbox sync while a
    /// short foreground/background grace period is available.
    func flushForBackground() async {
        audioPlayback.persistCurrentState()
        await Task.yield()
        await syncPendingProgress()
        scheduleBackgroundSync()
    }

    func playRemoteAudio(bookId: Int64, file: RemoteFileRecord, playlist: [RemoteFileRecord] = []) async {
        guard isAuthenticated, ["m4b", "m4a", "mp3", "opus", "ogg", "flac"].contains(file.format.lowercased()) else { return }
        do {
            let saved = await audioProgressForOpening(bookId: bookId, remoteBookId: bookId)
            let settings = await audioSettingsForOpening(bookId: bookId)
            let candidates = (playlist.isEmpty ? [file] : playlist).filter { ["m4b", "m4a", "mp3", "opus", "ogg", "flac"].contains($0.format.lowercased()) }
            var tracks: [AudioPlaybackService.Track] = []
            for candidate in candidates {
                let request = try await apiClient.audioStreamRequest(fileId: candidate.id)
                guard let url = request.url else { continue }
                tracks.append(AudioPlaybackService.Track(url: url, title: candidate.fileName, fileId: candidate.id, headers: request.allHTTPHeaderFields ?? [:], durationHint: candidate.durationSeconds))
            }
            guard !tracks.isEmpty else { return }
            let validFileIds = Set(tracks.map(\.fileId))
            audioPlayback.onProgress = { [weak self] fileId, position, percentage in
                guard let self, validFileIds.contains(fileId) else { return }
                let payload = AudioProgressPayload(percentage: percentage, currentFileId: fileId, positionSeconds: position, updatedAt: ISO8601DateFormatter().string(from: Date()), dirty: true)
                Task { try? await self.localStore.saveAudioProgress(bookId: bookId, progress: payload, enqueue: true) }
            }
            let startIndex = tracks.firstIndex { $0.fileId == (saved?.currentFileId ?? file.id) } ?? 0
            var restoredSleepUntil: Date?
            if let settings {
                audioPlayback.rate = min(max(Float(settings.rate), 0.5), 3.0)
                restoredSleepUntil = settings.sleepUntil
            }
            audioPlayback.play(tracks: tracks, startIndex: startIndex, startAt: saved?.currentFileId == tracks[startIndex].fileId ? (saved?.positionSeconds ?? 0) : 0)
            audioPlayback.setSleepTimer(until: restoredSleepUntil)
        } catch {
            globalError = error.localizedDescription
        }
    }

    func syncPendingProgress() async {
        guard isAuthenticated else { return }
        await progressSync.syncPending()
    }

    func pendingProgressConflicts() async -> [SyncConflict] {
        await progressSync.conflicts()
    }

    func resolveProgressConflict(_ conflict: SyncConflict, keepLocal: Bool) async {
        await progressSync.resolve(conflict, keepLocal: keepLocal)
    }
}

/// `BookOrbitAPIClient.download` reports progress from a URLSession bytes
/// callback. Keeping the latest offset and callback timestamp in a tiny locked
/// box avoids mutating captured local state across executors. The emitted rate
/// is strictly the byte delta between two real callbacks divided by their
/// monotonic elapsed time; no estimated throughput is produced.
private final class DownloadProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var timestamp = DispatchTime.now().uptimeNanoseconds

    func reset(received newValue: Int64) {
        lock.lock()
        received = max(0, newValue)
        timestamp = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func record(received newValue: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        let value = max(0, newValue)
        let elapsed = now >= timestamp ? now - timestamp : 0
        let delta = value >= received ? value - received : 0
        received = value
        timestamp = now

        guard delta > 0, elapsed > 0 else { return 0 }
        let bytesPerSecond = (Double(delta) * 1_000_000_000) / Double(elapsed)
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return 0 }
        return min(Int64.max, Int64(bytesPerSecond.rounded(.down)))
    }

    func get() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}
