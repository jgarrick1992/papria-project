import Foundation

/// Backwards-compatible façade for features that only need reading progress.
/// The actual source of truth is SQLite (`LocalLibraryStore`), not an in-memory
/// dictionary, so progress survives force quit and device restart.
actor DraftStore {
    private let store: LocalLibraryStore

    init(store: LocalLibraryStore) {
        self.store = store
    }

    func save(fileId: Int64, progress: FileProgressPayload) async throws {
        try await store.saveProgress(fileId: fileId, progress: progress)
    }

    func load(fileId: Int64) async throws -> FileProgressPayload? {
        try await store.loadProgress(fileId: fileId)
    }
}
