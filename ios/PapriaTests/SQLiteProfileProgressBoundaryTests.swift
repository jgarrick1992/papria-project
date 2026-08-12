import Foundation
import XCTest
@testable import Papria

final class SQLiteProfileProgressBoundaryTests: XCTestCase {
    func testServerProfileTrimsRequiredValuesDropsBlankCertificateAndRemainsSingleton() async throws {
        let harness = try makeStore(name: "profile-normalization")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try await harness.store.saveServerProfile(ServerProfile(
            serverURL: "  https://books.example.test  ",
            username: "  reader  ",
            certificateSha256: "  \n ",
            updatedAt: "2026-08-11T00:00:00Z"
        ))
        let storedFirst = try await harness.store.serverProfile()
        let first = try XCTUnwrap(storedFirst)
        XCTAssertEqual(first.serverURL, "https://books.example.test")
        XCTAssertEqual(first.username, "reader")
        XCTAssertNil(first.certificateSha256)
        XCTAssertNil(first.httpConfirmationTarget)

        let replacement = ServerProfile(
            serverURL: "http://192.168.1.9:8080",
            username: "other",
            certificateSha256: String(repeating: "ab", count: 32),
            httpConfirmationTarget: "192.168.1.9:8080",
            updatedAt: "2026-08-11T01:00:00Z"
        )
        try await harness.store.saveServerProfile(replacement)
        let storedReplacement = try await harness.store.serverProfile()
        XCTAssertEqual(storedReplacement, replacement)

        let database = await harness.store.database
        let count = try database.query("SELECT COUNT(*) AS count FROM server_profile;").first?.integer("count")
        XCTAssertEqual(count, 1)
    }

    func testServerProfileRejectsEmptyRequiredValuesWithoutReplacingExistingRow() async throws {
        let harness = try makeStore(name: "profile-invalid")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let original = ServerProfile(
            serverURL: "https://books.example.test",
            username: "reader",
            certificateSha256: nil,
            updatedAt: "2026-08-11T00:00:00Z"
        )
        try await harness.store.saveServerProfile(original)

        await assertAsyncThrows {
            try await harness.store.saveServerProfile(ServerProfile(
                serverURL: " \n ",
                username: "reader",
                certificateSha256: nil
            ))
        }
        await assertAsyncThrows {
            try await harness.store.saveServerProfile(ServerProfile(
                serverURL: "https://books.example.test",
                username: "\t",
                certificateSha256: nil
            ))
        }

        let storedOriginal = try await harness.store.serverProfile()
        XCTAssertEqual(storedOriginal, original)
    }

    func testServerProfileCodableContainsMetadataOnlyAndNoSecretAliases() throws {
        let profile = ServerProfile(
            serverURL: "https://books.example.test",
            username: "reader",
            certificateSha256: nil,
            httpConfirmationTarget: nil,
            updatedAt: "2026-08-11T00:00:00Z"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["serverURL", "username", "updatedAt"])
        for forbidden in ["password", "accessToken", "access_token", "refreshCookie", "refresh_token", "token"] {
            XCTAssertNil(object[forbidden], forbidden)
        }
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testBookOrbitCatalogCacheCanBeReplacedAndClearedWithoutRemovingLocalData() async throws {
        let harness = try makeStore(name: "bookorbit-cache")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let book = RemoteBookRecord(id: 7, title: "缓存书", author: "作者", coverURL: nil)
        let file = RemoteFileRecord(id: 70, fileName: "缓存书.epub", format: "epub", sizeBytes: 123, role: nil, durationSeconds: nil)
        try await harness.store.replaceRemoteBooks([book])
        try await harness.store.saveRemoteFiles(bookId: book.id, files: [file])
        let savedBooks = try await harness.store.remoteBooks()
        let savedFiles = try await harness.store.remoteFiles(bookId: book.id)
        XCTAssertEqual(savedBooks, [book])
        XCTAssertEqual(savedFiles, [file])

        try await harness.store.replaceRemoteBooks([])
        let replacedBooks = try await harness.store.remoteBooks()
        XCTAssertEqual(replacedBooks, [])
        // A detail row without a local publication or download task is safe to
        // evict when the user chooses “clear remote cache”.
        try await harness.store.clearBookOrbitCatalogCache()
        let clearedFiles = try await harness.store.remoteFiles(bookId: book.id)
        XCTAssertEqual(clearedFiles, [])
    }

    func testFileProgressRoundTripsNilEmptyAndExtremeLocationFields() async throws {
        let harness = try makeStore(name: "file-progress")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let empty = FileProgressPayload(percentage: 0)
        try await harness.store.saveProgress(fileId: 0, progress: empty, enqueue: false)
        let storedEmpty = try await harness.store.loadProgress(fileId: 0)
        let loadedEmpty = try XCTUnwrap(storedEmpty)
        XCTAssertEqual(loadedEmpty.percentage, 0)
        XCTAssertNil(loadedEmpty.cfi)
        XCTAssertNil(loadedEmpty.pageNumber)
        XCTAssertNil(loadedEmpty.positionSeconds)
        XCTAssertFalse(loadedEmpty.dirty)
        let emptyOutbox = try await harness.store.pendingOutbox()
        XCTAssertEqual(emptyOutbox, [])

        let extreme = FileProgressPayload(
            percentage: 100,
            cfi: "",
            pageNumber: Int.max,
            positionSeconds: Double.greatestFiniteMagnitude,
            updatedAt: "",
            dirty: false,
            koboLocationSource: "",
            koboLocationType: "progress",
            koboLocationValue: String(repeating: "9", count: 1_024),
            koboContentSourceProgressPercent: 100,
            koreaderProgress: "1"
        )
        try await harness.store.saveProgress(fileId: Int64.max, progress: extreme, enqueue: true)
        let storedExtreme = try await harness.store.loadProgress(fileId: Int64.max)
        let loaded = try XCTUnwrap(storedExtreme)
        XCTAssertEqual(loaded.percentage, extreme.percentage)
        XCTAssertEqual(loaded.cfi, "")
        XCTAssertEqual(loaded.pageNumber, Int.max)
        XCTAssertEqual(loaded.positionSeconds, Double.greatestFiniteMagnitude)
        XCTAssertEqual(loaded.koboLocationSource, "")
        XCTAssertEqual(loaded.koboLocationValue, extreme.koboLocationValue)
        XCTAssertTrue(loaded.dirty)

        let outbox = try await harness.store.pendingOutbox()
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.first?.kind, "file_progress")
        XCTAssertEqual(outbox.first?.resourceId, Int64.max)
    }

    func testProgressOutboxCoalescesLatestValuePerResource() async throws {
        let harness = try makeStore(name: "progress-outbox")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        try await harness.store.saveProgress(fileId: 7, progress: FileProgressPayload(percentage: 10), enqueue: true)
        try await harness.store.saveProgress(fileId: 7, progress: FileProgressPayload(percentage: 20, pageNumber: 2), enqueue: true)
        try await harness.store.saveAudioProgress(bookId: 8, progress: AudioProgressPayload(percentage: 30, currentFileId: 9, positionSeconds: 1), enqueue: true)
        try await harness.store.saveAudioProgress(bookId: 8, progress: AudioProgressPayload(percentage: 40, currentFileId: 10, positionSeconds: 2), enqueue: true)

        let outbox = try await harness.store.pendingOutbox()
        XCTAssertEqual(outbox.count, 2)
        let fileItem = try XCTUnwrap(outbox.first { $0.kind == "file_progress" })
        let filePayload = try JSONDecoder().decode(FileProgressPayload.self, from: Data(fileItem.payload.utf8))
        XCTAssertEqual(filePayload.percentage, 20)
        XCTAssertEqual(filePayload.pageNumber, 2)

        let audioItem = try XCTUnwrap(outbox.first { $0.kind == "audio_progress" })
        let audioPayload = try JSONDecoder().decode(AudioProgressPayload.self, from: Data(audioItem.payload.utf8))
        XCTAssertEqual(audioPayload.percentage, 40)
        XCTAssertEqual(audioPayload.currentFileId, 10)
        XCTAssertEqual(audioPayload.positionSeconds, 2)
    }

    func testAudioProgressClearAndPlaybackRateClampBoundaries() async throws {
        let harness = try makeStore(name: "audio-progress")
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let progress = AudioProgressPayload(
            percentage: 0,
            currentFileId: Int64.min,
            positionSeconds: 0,
            updatedAt: "2026-08-11T00:00:00Z",
            dirty: false
        )
        try await harness.store.saveAudioProgress(bookId: Int64.min, progress: progress, enqueue: false)
        let storedProgress = try await harness.store.loadAudioProgress(bookId: Int64.min)
        XCTAssertEqual(storedProgress, progress)
        let emptyOutbox = try await harness.store.pendingOutbox()
        XCTAssertEqual(emptyOutbox, [])
        try await harness.store.clearAudioProgress(bookId: Int64.min)
        let clearedProgress = try await harness.store.loadAudioProgress(bookId: Int64.min)
        XCTAssertNil(clearedProgress)

        try await harness.store.saveAudioSettings(bookId: 1, rate: -Double.greatestFiniteMagnitude, sleepUntil: nil)
        let minimumRate = try await harness.store.loadAudioSettings(bookId: 1)?.rate
        XCTAssertEqual(minimumRate, 0.5)
        try await harness.store.saveAudioSettings(bookId: 2, rate: Double.greatestFiniteMagnitude, sleepUntil: nil)
        let maximumRate = try await harness.store.loadAudioSettings(bookId: 2)?.rate
        XCTAssertEqual(maximumRate, 3)
    }

    func testCorruptAudioRemoteBaselinesAreRejected() async throws {
        let harness = try makeStore(name: "audio-baseline-corrupt")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let database = await harness.store.database
        try database.execute("PRAGMA ignore_check_constraints = ON;")
        defer { _ = try? database.execute("PRAGMA ignore_check_constraints = OFF;") }

        try database.execute("INSERT INTO audio_progress_remote_baseline(book_id,remote_present,pulled_at) VALUES (1,2,'now');")
        await assertAsyncThrows { _ = try await harness.store.audioProgressRemoteBaseline(bookId: 1) }

        try database.execute("DELETE FROM audio_progress_remote_baseline;")
        try database.execute("INSERT INTO audio_progress_remote_baseline(book_id,remote_present,percentage,pulled_at) VALUES (1,0,1,'now');")
        await assertAsyncThrows { _ = try await harness.store.audioProgressRemoteBaseline(bookId: 1) }

        try database.execute("DELETE FROM audio_progress_remote_baseline;")
        try database.execute("INSERT INTO audio_progress_remote_baseline(book_id,remote_present,percentage,current_file_id,pulled_at) VALUES (1,1,1,2,'now');")
        await assertAsyncThrows { _ = try await harness.store.audioProgressRemoteBaseline(bookId: 1) }
    }

    func testDownloadRowsAcceptZeroTotalRejectNegativeTotalAndHideCompletion() async throws {
        let harness = try makeStore(name: "download-boundary")
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let part = harness.root.appendingPathComponent("download.part")

        try await harness.store.beginDownload(fileId: 1, partURL: part, totalBytes: 0)
        let pending = try await harness.store.pendingDownloads()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.offsetBytes, 0)
        XCTAssertEqual(pending.first?.totalBytes, 0)

        await assertAsyncThrows {
            try await harness.store.beginDownload(fileId: 2, partURL: part, totalBytes: -1)
        }
        await assertAsyncThrows {
            try await harness.store.updateDownload(fileId: 1, offset: 0, totalBytes: -1)
        }

        try await harness.store.finishDownload(fileId: 1)
        let completed = try await harness.store.pendingDownloads()
        XCTAssertEqual(completed, [])
    }

    func testLocalPublicationProgressIdentifierIsStableNegativeAndNeverZero() {
        func publication(hash: String) -> LocalPublication {
            LocalPublication(
                id: "local",
                title: "Book",
                author: nil,
                format: "epub",
                fileHash: hash,
                filePath: "/tmp/book.epub",
                source: "local",
                remoteBookId: nil,
                remoteFileId: nil,
                sizeBytes: 0,
                createdAt: "now",
                updatedAt: "now"
            )
        }

        XCTAssertEqual(publication(hash: "").progressFileId, -1)
        XCTAssertEqual(publication(hash: String(repeating: "0", count: 64)).progressFileId, -1)
        let first = publication(hash: "0123456789abcdef" + String(repeating: "0", count: 48)).progressFileId
        let second = publication(hash: "0123456789abcdef" + String(repeating: "f", count: 48)).progressFileId
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first, 0)

        let remote = LocalPublication(
            id: "remote",
            title: "Book",
            author: nil,
            format: "pdf",
            fileHash: "0",
            filePath: "/tmp/book.pdf",
            source: "remote",
            remoteBookId: 1,
            remoteFileId: Int64.max,
            sizeBytes: 0,
            createdAt: "now",
            updatedAt: "now"
        )
        XCTAssertEqual(remote.progressFileId, Int64.max)
    }

    private func makeStore(name: String) throws -> (root: URL, store: LocalLibraryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("papria-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root,
            try LocalLibraryStore(
                databaseURL: root.appendingPathComponent("library.sqlite3"),
                contentURL: root.appendingPathComponent("content", isDirectory: true)
            )
        )
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }
}
