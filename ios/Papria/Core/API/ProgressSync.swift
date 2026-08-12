import Foundation

/// Pull-before-push synchronisation for the local-first progress model.
/// Local Wi-Fi publications never receive an outbox item because they do not
/// have a remote file identifier.
actor ProgressSyncService {
    private let api: BookOrbitAPIClient
    private let store: LocalLibraryStore

    init(api: BookOrbitAPIClient, store: LocalLibraryStore) {
        self.api = api
        self.store = store
    }

    /// A missing baseline is fail-safe: a successful pull establishes it and
    /// an existing dirty local position remains eligible for first upload.
    func pullFileBeforeOpen(fileId: Int64) async -> FileProgressPayload? {
        let local = try? await store.loadProgress(fileId: fileId)
        guard let remote = try? await api.fetchProgress(fileId: fileId) else { return local }
        let baseline = try? await store.fileProgressRemoteBaseline(fileId: fileId)
        let remoteChanged = Self.fileRemoteChanged(since: baseline, remote: remote)
        do {
            try await store.saveFileProgressRemoteBaseline(fileId: fileId, progress: remote)
        } catch {
            return local
        }

        if let local, local.dirty,
           remoteChanged, Self.fileProgressDiffers(local, remote) {
            await saveFileConflict(fileId: fileId, local: local, remote: remote)
            return local
        }

        if local == nil || !local!.dirty {
            let clean = Self.fileSnapshot(remote)
            try? await store.saveProgress(fileId: fileId, progress: clean, enqueue: false)
            return clean
        }
        return local
    }

    /// Audio GETs can return no remote row. That absence is also persisted so
    /// the next local dirty upload is not mistaken for a conflict.
    func pullAudioBeforeOpen(bookId: Int64) async -> AudioProgressPayload? {
        let local = try? await store.loadAudioProgress(bookId: bookId)
        let remote: AudioProgressPayload?
        do {
            remote = try await api.fetchAudioProgress(bookId: bookId)
        } catch {
            return local
        }
        let baseline = try? await store.audioProgressRemoteBaseline(bookId: bookId)
        let remoteChanged = Self.audioRemoteChanged(since: baseline, remote: remote)
        do {
            try await store.saveAudioProgressRemoteBaseline(bookId: bookId, progress: remote)
        } catch {
            return local
        }

        if let local, local.dirty,
           remoteChanged, Self.audioProgressDiffers(local, remote) {
            await saveAudioConflict(bookId: bookId, local: local, remote: remote)
            return local
        }

        if local == nil || !local!.dirty {
            if let remote {
                let clean = Self.audioSnapshot(remote)
                try? await store.saveAudioProgress(bookId: bookId, progress: clean, enqueue: false)
                return clean
            }
            try? await store.clearAudioProgress(bookId: bookId)
        }
        return local
    }

    func syncPending() async {
        guard let items = try? await store.pendingOutbox() else { return }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                let forceUpload = item.retryCount < 0
                if try await store.hasConflict(kind: item.kind, resourceId: item.resourceId) { continue }

                switch item.kind {
                case "file_progress":
                    let payload = try JSONDecoder().decode(FileProgressPayload.self, from: Data(item.payload.utf8))
                    if !forceUpload {
                        let remote = try await api.fetchProgress(fileId: item.resourceId)
                        let baseline = try await store.fileProgressRemoteBaseline(fileId: item.resourceId)
                        let remoteChanged = Self.fileRemoteChanged(since: baseline, remote: remote)
                        try await store.saveFileProgressRemoteBaseline(fileId: item.resourceId, progress: remote)
                        if remoteChanged, Self.fileProgressDiffers(payload, remote) {
                            await saveFileConflict(fileId: item.resourceId, local: payload, remote: remote)
                            continue
                        }
                    }
                    try await api.saveProgress(fileId: item.resourceId, payload: payload)
                    let verified = try await api.fetchProgress(fileId: item.resourceId)
                    try await store.saveFileProgressRemoteBaseline(fileId: item.resourceId, progress: verified)
                    try await store.saveProgress(fileId: item.resourceId, progress: Self.fileSnapshot(verified), enqueue: false)

                case "audio_progress":
                    let payload = try JSONDecoder().decode(AudioProgressPayload.self, from: Data(item.payload.utf8))
                    if !forceUpload {
                        let remote = try await api.fetchAudioProgress(bookId: item.resourceId)
                        let baseline = try await store.audioProgressRemoteBaseline(bookId: item.resourceId)
                        let remoteChanged = Self.audioRemoteChanged(since: baseline, remote: remote)
                        try await store.saveAudioProgressRemoteBaseline(bookId: item.resourceId, progress: remote)
                        if remoteChanged, Self.audioProgressDiffers(payload, remote) {
                            await saveAudioConflict(bookId: item.resourceId, local: payload, remote: remote)
                            continue
                        }
                    }
                    try await api.saveAudioProgress(bookId: item.resourceId, payload: payload)
                    guard let verified = try await api.fetchAudioProgress(bookId: item.resourceId) else {
                        throw BookOrbitAPIError.invalidResponse
                    }
                    try await store.saveAudioProgressRemoteBaseline(bookId: item.resourceId, progress: verified)
                    try await store.saveAudioProgress(bookId: item.resourceId, progress: Self.audioSnapshot(verified), enqueue: false)

                default:
                    break
                }
                try await store.removeOutbox(id: item.id)
            } catch is CancellationError {
                return
            } catch {
                try? await store.bumpOutbox(id: item.id)
            }
        }
    }

    func conflicts() async -> [SyncConflict] { (try? await store.conflicts()) ?? [] }

    func resolve(_ conflict: SyncConflict, keepLocal: Bool) async {
        do {
            if keepLocal {
                if conflict.kind == "file_progress", let local = try await store.loadProgress(fileId: conflict.resourceId) {
                    try await store.saveProgress(fileId: conflict.resourceId, progress: local, enqueue: true)
                } else if conflict.kind == "audio_progress", let local = try await store.loadAudioProgress(bookId: conflict.resourceId) {
                    try await store.saveAudioProgress(bookId: conflict.resourceId, progress: local, enqueue: true)
                }
                if let item = try await store.pendingOutbox().first(where: { $0.kind == conflict.kind && $0.resourceId == conflict.resourceId }) {
                    try await store.forceOutbox(id: item.id)
                }
            } else {
                if conflict.kind == "file_progress" {
                    let remote = try JSONDecoder().decode(FileProgressPayload.self, from: Data(conflict.remotePayload.utf8))
                    try await store.saveFileProgressRemoteBaseline(fileId: conflict.resourceId, progress: remote)
                    try await store.saveProgress(fileId: conflict.resourceId, progress: Self.fileSnapshot(remote), enqueue: false)
                } else if conflict.kind == "audio_progress" {
                    let remote = try JSONDecoder().decode(AudioProgressPayload?.self, from: Data(conflict.remotePayload.utf8))
                    try await store.saveAudioProgressRemoteBaseline(bookId: conflict.resourceId, progress: remote)
                    if let remote {
                        try await store.saveAudioProgress(bookId: conflict.resourceId, progress: Self.audioSnapshot(remote), enqueue: false)
                    } else {
                        try await store.clearAudioProgress(bookId: conflict.resourceId)
                    }
                }
                if let item = try await store.pendingOutbox().first(where: { $0.kind == conflict.kind && $0.resourceId == conflict.resourceId }) {
                    try await store.removeOutbox(id: item.id)
                }
            }
            try await store.removeConflict(kind: conflict.kind, resourceId: conflict.resourceId)
        } catch {
            // Keep the conflict and outbox intact for the next explicit sync.
        }
    }

    private func saveFileConflict(fileId: Int64, local: FileProgressPayload, remote: FileProgressPayload) async {
        let localJSON = (try? String(data: JSONEncoder().encode(local), encoding: .utf8)) ?? "{}"
        let remoteJSON = (try? String(data: JSONEncoder().encode(remote), encoding: .utf8)) ?? "{}"
        try? await store.saveConflict(SyncConflict(kind: "file_progress", resourceId: fileId, localPayload: localJSON, remotePayload: remoteJSON, createdAt: ISO8601DateFormatter().string(from: Date())))
    }

    private func saveAudioConflict(bookId: Int64, local: AudioProgressPayload, remote: AudioProgressPayload?) async {
        let localJSON = (try? String(data: JSONEncoder().encode(local), encoding: .utf8)) ?? "{}"
        let remoteJSON = (try? String(data: JSONEncoder().encode(remote), encoding: .utf8)) ?? "null"
        try? await store.saveConflict(SyncConflict(kind: "audio_progress", resourceId: bookId, localPayload: localJSON, remotePayload: remoteJSON, createdAt: ISO8601DateFormatter().string(from: Date())))
    }

    private static func fileSnapshot(_ remote: FileProgressPayload) -> FileProgressPayload {
        FileProgressPayload(percentage: remote.percentage, cfi: remote.cfi, pageNumber: remote.pageNumber, positionSeconds: remote.positionSeconds, dirty: false,
                            koboLocationSource: remote.koboLocationSource, koboLocationType: remote.koboLocationType, koboLocationValue: remote.koboLocationValue,
                            koboContentSourceProgressPercent: remote.koboContentSourceProgressPercent, koreaderProgress: remote.koreaderProgress)
    }

    private static func audioSnapshot(_ remote: AudioProgressPayload) -> AudioProgressPayload {
        AudioProgressPayload(percentage: remote.percentage, currentFileId: remote.currentFileId, positionSeconds: remote.positionSeconds, dirty: false)
    }

    static func fileProgressDiffers(_ local: FileProgressPayload, _ remote: FileProgressPayload) -> Bool {
        abs(local.percentage - remote.percentage) > 0.1 || local.cfi != remote.cfi || local.pageNumber != remote.pageNumber || abs((local.positionSeconds ?? 0) - (remote.positionSeconds ?? 0)) > 1 || local.koboLocationSource != remote.koboLocationSource || local.koboLocationType != remote.koboLocationType || local.koboLocationValue != remote.koboLocationValue || local.koboContentSourceProgressPercent != remote.koboContentSourceProgressPercent || local.koreaderProgress != remote.koreaderProgress
    }

    static func fileRemoteChanged(since baseline: FileProgressPayload?, remote: FileProgressPayload) -> Bool {
        guard let baseline else { return false }
        return fileProgressDiffers(baseline, remote)
    }

    static func audioProgressDiffers(_ local: AudioProgressPayload, _ remote: AudioProgressPayload?) -> Bool {
        guard let remote else { return true }
        return abs(local.percentage - remote.percentage) > 0.1 || local.currentFileId != remote.currentFileId || abs(local.positionSeconds - remote.positionSeconds) > 1
    }

    static func audioBaselineDiffers(_ baseline: RemoteAudioProgressBaseline, _ remote: AudioProgressPayload?) -> Bool {
        switch (baseline, remote) {
        case (.noRemoteProgress, nil): return false
        case (.noRemoteProgress, .some): return true
        case (.remoteProgress, nil): return true
        case (.remoteProgress(let baseline), .some(let remote)): return audioProgressDiffers(baseline, remote)
        }
    }

    static func audioRemoteChanged(since baseline: RemoteAudioProgressBaseline?, remote: AudioProgressPayload?) -> Bool {
        guard let baseline else { return false }
        return audioBaselineDiffers(baseline, remote)
    }
}
