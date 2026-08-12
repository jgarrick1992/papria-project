import XCTest
@testable import Papria

final class PapriaTests: XCTestCase {
    @MainActor
    func testAudioTrackDurationHintIsValidated() {
        let valid = AudioPlaybackService.Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "A", fileId: 1, durationHint: 123.5)
        XCTAssertEqual(valid.durationHint, 123.5)

        let negative = AudioPlaybackService.Track(url: URL(fileURLWithPath: "/tmp/b.opus"), title: "B", fileId: 2, durationHint: -1)
        XCTAssertNil(negative.durationHint)
        let nan = AudioPlaybackService.Track(url: URL(fileURLWithPath: "/tmp/c.ogg"), title: "C", fileId: 3, durationHint: .nan)
        XCTAssertNil(nan.durationHint)
    }

    @MainActor
    func testAudioPlaybackPolicyBoundsRateAndComputesWholeBookProgress() {
        XCTAssertEqual(AudioPlaybackService.normalizedRate(0.1), 0.5)
        XCTAssertEqual(AudioPlaybackService.normalizedRate(1.25), 1.25)
        XCTAssertEqual(AudioPlaybackService.normalizedRate(9), 3)
        XCTAssertEqual(AudioPlaybackService.normalizedRate(.nan), 1)

        // 100 seconds of track one plus 150/300 seconds of track two is
        // 250/400 seconds through the audiobook, not 50% of only track two.
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 1, positionSeconds: 150, trackDurations: [100, 300]),
            62.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 0, positionSeconds: .nan, trackDurations: [100]),
            0
        )
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 4, positionSeconds: 10, trackDurations: [100]),
            0
        )
    }

    func testNativeFormatCoreIsLinked() throws {
        XCTAssertGreaterThan(try XCTUnwrap(FormatCoreRuntime.linkedContractVersion()), 0)
    }

    func testEpubCFILocatorUsesStandardSpineAndContentPaths() throws {
        let value = EpubCFILocator.make(spineIndex: 0, idref: "chapter", contentPath: [4, 2, 1], textOffset: 7)
        XCTAssertEqual(value, "epubcfi(/6/4[chapter]!/4/2/1:7)")
        let parsed = try XCTUnwrap(EpubCFILocator.parse(value))
        XCTAssertEqual(parsed.spineIndex, 0)
        XCTAssertEqual(parsed.idref, "chapter")
        XCTAssertEqual(parsed.contentPath, [4, 2, 1])
        XCTAssertEqual(parsed.textOffset, 7)
        XCTAssertNil(EpubCFILocator.parse("chapter:0/page:1/offset:7"))
    }

    func testEpubCFILocatorParsesAssertionsAndRejectsRanges() throws {
        let external = "epubcfi(/6/4[chap^]ter]!/4/2/10[para]/1:12)"
        let parsed = try XCTUnwrap(EpubCFILocator.parse(external))
        XCTAssertEqual(parsed.spineIndex, 0)
        XCTAssertEqual(parsed.idref, "chap]ter")
        XCTAssertEqual(parsed.contentID, "para")
        XCTAssertEqual(parsed.textOffset, 12)
        XCTAssertNil(EpubCFILocator.parse("epubcfi(/6/2!/4/2,/1:3,/1:9)"))
    }

    func testEpubContentCFIIndexRoundTripsUnicodeTextOffset() throws {
        let markup = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>x</title></head><body><p id=\"p\">你好 😀 world</p></body></html>"
        let index = EpubContentCFIIndex(markup: markup)
        XCTAssertTrue(index.text.contains("你好 😀 world"))
        let location = try XCTUnwrap(index.location(forDisplayOffset: 4))
        XCTAssertEqual(location.path, [4, 2, 1])
        XCTAssertEqual(location.utf16Offset, 5)
        XCTAssertEqual(index.displayOffset(forPath: location.path, utf16Offset: location.utf16Offset), 4)
        XCTAssertEqual(index.anchors["p"], 0)
    }

    func testReaderSettingsPersistEPUBPaperToneAndPDFZoomMode() {
        let epubKey = "reader-test-epub-\(UUID().uuidString)"
        let pdfKey = "reader-test-pdf-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: EpubReaderPreferences.key(epubKey))
            UserDefaults.standard.removeObject(forKey: PDFReaderPreferences.key(pdfKey))
        }

        EpubReaderPreferences(paperTone: .night).save(storageKey: epubKey)
        XCTAssertEqual(EpubReaderPreferences.load(storageKey: epubKey), EpubReaderPreferences(paperTone: .night))

        let pdf = PDFReaderPreferences(zoomMode: .manual, zoomScale: 1.8, rotation: 90, continuous: false, horizontal: true)
        pdf.save(storageKey: pdfKey)
        XCTAssertEqual(PDFReaderPreferences.load(storageKey: pdfKey), pdf)
    }

    func testEpubBookRestoresForeignPointCFI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-reader-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = root.appendingPathComponent("reader.epub")
        let container = "<?xml version=\"1.0\"?><container><rootfiles><rootfile full-path=\"OPS/content.opf\"/></rootfiles></container>"
        let opf = "<?xml version=\"1.0\"?><package><metadata><dc:title xmlns:dc=\"x\">Reader</dc:title></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Reader</title></head><body><p>第一段</p><p id=\"second\">第二段 😀</p></body></html>"
        try makeStoredZip(entries: [
            ("META-INF/container.xml", Data(container.utf8)),
            ("OPS/content.opf", Data(opf.utf8)),
            ("OPS/chapter.xhtml", Data(xhtml.utf8))
        ], at: epub)

        let book = try EpubBookModel(url: epub)
        let generated = book.cfiForOffset(chapter: 0, offset: 4)
        XCTAssertTrue(generated.hasPrefix("epubcfi(/6/4[chapter]!/"))
        XCTAssertEqual(book.page(forCFI: generated, fontSize: 18)?.chapter, 0)
        let foreign = "epubcfi(/6/4[chapter]!/4/4/1:0)"
        let restored = try XCTUnwrap(book.page(forCFI: foreign, fontSize: 18))
        XCTAssertEqual(restored.chapter, 0)
        XCTAssertEqual(restored.page, 0)
    }

    func testProgressPayloadUsesExactFields() throws {
        let payload = FileProgressPayload(percentage: 42, cfi: "epubcfi(/6/4)", pageNumber: 3)
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["percentage"] as? Double, 42)
        XCTAssertEqual(json["cfi"] as? String, "epubcfi(/6/4)")
        XCTAssertEqual(json["pageNumber"] as? Int, 3)
    }

    func testBookOrbitQueryAndDetailDecodeExactServerShapes() throws {
        let query = Data("""
        {"items":[{"id":7,"title":"书","authors":["作者"],"files":[{"id":9,"format":"epub","role":"primary","sizeBytes":123}]}],"total":1,"page":0,"size":20}
        """.utf8)
        let page = try JSONDecoder().decode(BookQueryResponse.self, from: query)
        XCTAssertEqual(page.page, 0)
        XCTAssertEqual(page.items.first?.author, "作者")

        let detail = Data("""
        {"id":7,"title":"书","authors":[{"name":"作者"}],"files":[{"id":9,"format":"epub","role":"primary","sizeBytes":123,"absolutePath":"/server/book.epub","createdAt":"2026-01-01T00:00:00.000Z","filename":"book.epub","durationSeconds":null}]}
        """.utf8)
        let book = try JSONDecoder().decode(BookOrbitBookDetail.self, from: detail)
        XCTAssertEqual(book.author, "作者")
        XCTAssertEqual(book.files.first?.fileName, "book.epub")
        XCTAssertEqual(book.files.first?.sizeBytes, 123)
    }

    func testBookOrbitResponsesRequirePublishedFieldsAndIgnoreExtensions() throws {
        let unknown = Data("""
        {"id":7,"title":"书","authors":[{"name":"作者"}],"files":[],"unexpected":true}
        """.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(BookOrbitBookDetail.self, from: unknown))

        let missingTitle = Data("""
        {"id":7,"authors":[{"name":"作者"}],"files":[]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BookOrbitBookDetail.self, from: missingTitle))

        let nestedUnknown = Data("""
        {"items":[{"id":7,"title":"书","authors":["作者"],"files":[{"id":9,"format":"epub","role":"primary","sizeBytes":123,"unexpected":true}]}],"total":1,"page":0,"size":20}
        """.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(BookQueryResponse.self, from: nestedUnknown))
    }

    func testRemoteFileRecordRejectsMissingOrNullSizeBytes() {
        let missing = Data("""
        {"id":9,"format":"epub","filename":"book.epub"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: missing))

        let null = Data("""
        {"id":9,"format":"epub","filename":"book.epub","sizeBytes":null}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: null))
    }

    func testLoginResponseRequiresNonEmptyAccessToken() throws {
        let valid = try JSONDecoder().decode(LoginResponse.self, from: Data("{\"accessToken\":\"token\"}".utf8))
        XCTAssertEqual(valid.accessToken, "token")
        XCTAssertThrowsError(try JSONDecoder().decode(LoginResponse.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(LoginResponse.self, from: Data("{\"accessToken\":null}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(LoginResponse.self, from: Data("{\"accessToken\":\" \"}".utf8)))
    }

    func testLocalHTTPServerPolicyRequiresExactPortBoundConfirmation() throws {
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("http://192.168.1.12:8080", httpConfirmationTarget: nil))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("http://192.168.1.12:8080", httpConfirmationTarget: "192.168.1.12:80"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://192.168.1.12:8080", httpConfirmationTarget: "192.168.1.12:8080"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://[fd00::1]:8080", httpConfirmationTarget: "[fd00::1]:8080"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://192.168.1.12", httpConfirmationTarget: "192.168.1.12:80"))
        XCTAssertNil(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.12:0"))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("http://books.example.test", httpConfirmationTarget: "books.example.test:80"))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("https://books.example.test", httpConfirmationTarget: "books.example.test:443"))
    }

    func testLocalTransferResumeCredentialDoesNotAuthorizeAnotherToken() {
        let original = transferResumeTokenHash("first-local-transfer-resume-token")
        XCTAssertTrue(transferResumeTokenMatches(original, "first-local-transfer-resume-token"))
        XCTAssertFalse(transferResumeTokenMatches(original, "second-local-transfer-resume-token"))
    }

    func testLocalTransferCrashRecoveryTruncatesPartialChunkButKeepsCompleteTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-transfer-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func prepareUpload(id: String, actualSize: Int64, persistedOffset: Int64, totalSize: Int64) throws -> URL {
            let part = root.appendingPathComponent("\(id).part")
            XCTAssertTrue(FileManager.default.createFile(atPath: part.path, contents: nil))
            let handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(actualSize))
            try handle.close()
            let metadata: [String: Any] = [
                "id": id,
                "fileName": "book.epub",
                "sizeBytes": totalSize,
                "receivedBytes": persistedOffset,
                "resumeTokenHash": transferResumeTokenHash("resume-\(id)"),
                "modifiedAt": Date().timeIntervalSince1970
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(
                to: root.appendingPathComponent("\(id).json"),
                options: .atomic
            )
            return part
        }

        let interruptedSize = localTransferChunkSize + 123
        let interrupted = try prepareUpload(
            id: "interrupted",
            actualSize: interruptedSize,
            persistedOffset: 0,
            totalSize: localTransferChunkSize * 2
        )
        let completeSize = localTransferChunkSize + 321
        let complete = try prepareUpload(
            id: "complete",
            actualSize: completeSize,
            persistedOffset: localTransferChunkSize,
            totalSize: completeSize
        )

        let receiver = LocalTransferReceiver(contentStore: nil, uploadDirectory: root)
        XCTAssertEqual(try fileSize(at: interrupted), localTransferChunkSize)
        XCTAssertEqual(try fileSize(at: complete), completeSize)
        withExtendedLifetime(receiver) {}
    }

    func testDownloadRejectsInvalidExpectedSizeBeforeStarting() async {
        let client = BookOrbitAPIClient()
        let part = FileManager.default.temporaryDirectory.appendingPathComponent("papria-invalid-size-\(UUID().uuidString).part")
        do {
            _ = try await client.download(fileId: 9, partURL: part, expectedSize: -1)
            XCTFail("negative expected sizes must be rejected before a request starts")
        } catch {
            XCTAssertEqual((error as? BookOrbitAPIError)?.localizedDescription, BookOrbitAPIError.invalidResponse.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testSQLiteStoreAndContentAddressedImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chapter.txt")
        try Data("Papria test book".utf8).write(to: source)
        let store = try LocalLibraryStore(databaseURL: root.appendingPathComponent("library.sqlite3"), contentURL: root.appendingPathComponent("content"))

        let remoteFileColumns = try await store.database.query("PRAGMA table_info(remote_files);")
        XCTAssertEqual(remoteFileColumns.first(where: { $0.text("name") == "size_bytes" })?.integer("notnull"), 1)
        let downloadColumns = try await store.database.query("PRAGMA table_info(download_tasks);")
        XCTAssertEqual(downloadColumns.first(where: { $0.text("name") == "total_bytes" })?.integer("notnull"), 1)

        let publication = try await store.importLocalFile(at: source)
        XCTAssertEqual(publication.source, "local")
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.filePath))
        let publications = try await store.publications()
        XCTAssertEqual(publications.count, 1)

        let progress = FileProgressPayload(percentage: 0.5, cfi: "epubcfi(/6/4)", updatedAt: "2026-01-01T00:00:00Z", dirty: true)
        try await store.saveProgress(fileId: 9, progress: progress)
        let loaded = try await store.loadProgress(fileId: 9)
        XCTAssertEqual(loaded?.percentage, 0.5)
        let outbox = try await store.pendingOutbox()
        XCTAssertEqual(outbox.count, 1)

        let sleepUntil = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveAudioSettings(bookId: 9, rate: 1.5, sleepUntil: sleepUntil)
        let settings = try await store.loadAudioSettings(bookId: 9)
        XCTAssertEqual(settings?.rate ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(settings?.sleepUntil, sleepUntil)
    }

    func testServerProfileCRUDUsesSingletonSchemaWithoutSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalLibraryStore(databaseURL: root.appendingPathComponent("library.sqlite3"), contentURL: root.appendingPathComponent("content"))
        let profile = ServerProfile(serverURL: "http://192.168.1.12:8080", username: "reader", certificateSha256: String(repeating: "AA", count: 32), httpConfirmationTarget: "192.168.1.12:8080", updatedAt: "2026-08-10T00:00:00Z")
        try await store.saveServerProfile(profile)
        let loaded = try await store.serverProfile()
        XCTAssertEqual(loaded, profile)

        // The migration ledger is present for an upgraded pre-profile store,
        // and the profile table contains metadata only—not password/token
        // columns that could accidentally persist credentials.
        let migrations = try await store.database.query("SELECT version FROM schema_migrations;")
        XCTAssertTrue(migrations.contains { $0.integer("version") == 1 })
        XCTAssertTrue(migrations.contains { $0.integer("version") == 5 })
        let columns = try await store.database.query("PRAGMA table_info(server_profile);")
            .compactMap { $0.text("name") }
        XCTAssertEqual(Set(columns), Set(["id", "server_url", "username", "certificate_sha256", "http_confirmation_target", "updated_at"]))
        XCTAssertFalse(columns.contains("password"))
        XCTAssertFalse(columns.contains("access_token"))
        XCTAssertFalse(columns.contains("refresh_cookie"))

        try await store.deleteServerProfile()
        let deleted = try await store.serverProfile()
        XCTAssertNil(deleted)
    }

    func testRemoteProgressBaselinesPersistAndIgnoreUpdatedAt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-progress-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalLibraryStore(databaseURL: root.appendingPathComponent("library.sqlite3"), contentURL: root.appendingPathComponent("content"))
        let missingFileBaseline = try await store.fileProgressRemoteBaseline(fileId: 7)
        let missingAudioBaseline = try await store.audioProgressRemoteBaseline(bookId: 8)
        XCTAssertNil(missingFileBaseline)
        XCTAssertNil(missingAudioBaseline)

        let baseline = FileProgressPayload(percentage: 20, cfi: "epubcfi(/6/4)", updatedAt: "2099-01-01T00:00:00Z", dirty: false)
        try await store.saveFileProgressRemoteBaseline(fileId: 7, progress: baseline)
        let storedBaseline = try await store.fileProgressRemoteBaseline(fileId: 7)
        let loaded = try XCTUnwrap(storedBaseline)
        XCTAssertNil(loaded.updatedAt)
        XCTAssertFalse(ProgressSyncService.fileRemoteChanged(since: nil, remote: baseline))
        XCTAssertFalse(ProgressSyncService.fileProgressDiffers(loaded, FileProgressPayload(percentage: 20, cfi: "epubcfi(/6/4)", updatedAt: "1970-01-01T00:00:00Z")))
        XCTAssertFalse(ProgressSyncService.fileProgressDiffers(loaded, FileProgressPayload(percentage: 20.05, cfi: "epubcfi(/6/4)")))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(loaded, FileProgressPayload(percentage: 21, cfi: "epubcfi(/6/4)")))

        try await store.saveAudioProgressRemoteBaseline(bookId: 8, progress: nil)
        let absentAudioBaseline = try await store.audioProgressRemoteBaseline(bookId: 8)
        XCTAssertEqual(absentAudioBaseline, .noRemoteProgress)
        let audio = AudioProgressPayload(percentage: 40, currentFileId: 11, positionSeconds: 12, updatedAt: "2099-01-01T00:00:00Z")
        try await store.saveAudioProgressRemoteBaseline(bookId: 8, progress: audio)
        let storedAudioBaseline = try await store.audioProgressRemoteBaseline(bookId: 8)
        XCTAssertEqual(storedAudioBaseline, .remoteProgress(AudioProgressPayload(percentage: 40, currentFileId: 11, positionSeconds: 12)))
        XCTAssertFalse(ProgressSyncService.audioRemoteChanged(since: nil, remote: audio))
        XCTAssertTrue(ProgressSyncService.audioBaselineDiffers(.noRemoteProgress, audio))
        XCTAssertTrue(ProgressSyncService.audioProgressDiffers(audio, AudioProgressPayload(percentage: 40, currentFileId: 12, positionSeconds: 12)))
    }

    func testLegacyHostOnlyHTTPConfirmationExpiresWithoutTargetMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-legacy-http-confirmation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let legacy = try SQLiteDatabase(url: databaseURL)
        try legacy.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);")
        for version in 1...3 {
            try legacy.execute("INSERT INTO schema_migrations(version,applied_at) VALUES (?,?);", values: [.integer(Int64(version)), .text("2026-08-10T00:00:00Z")])
        }
        try legacy.execute("""
        CREATE TABLE server_profile (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          server_url TEXT NOT NULL,
          username TEXT NOT NULL,
          certificate_sha256 TEXT,
          http_confirmation_host TEXT,
          updated_at TEXT NOT NULL
        );
        """)
        try legacy.execute("INSERT INTO server_profile(id,server_url,username,http_confirmation_host,updated_at) VALUES (1,?,?,?,?);", values: [.text("http://192.168.1.12:8080"), .text("reader"), .text("192.168.1.12"), .text("2026-08-10T00:00:00Z")])

        let store = try LocalLibraryStore(databaseURL: databaseURL, contentURL: root.appendingPathComponent("content"))
        let storedProfile = try await store.serverProfile()
        let profile = try XCTUnwrap(storedProfile)
        XCTAssertNil(profile.httpConfirmationTarget)
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate(profile.serverURL, httpConfirmationTarget: profile.httpConfirmationTarget))
        let columns = try await store.database.query("PRAGMA table_info(server_profile);").compactMap { $0.text("name") }
        XCTAssertTrue(columns.contains("http_confirmation_target"))
    }

    func testZipArchiveRejectsUnsafeAndDuplicateMembers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let safe = root.appendingPathComponent("safe.cbz")
        try makeStoredZip(entries: [("01.jpg", Data([1, 2, 3]))], at: safe)
        let archive = try PapriaZipArchive(url: safe)
        XCTAssertEqual(archive.entries.map(\.name), ["01.jpg"])
        XCTAssertEqual(try archive.data(for: archive.entries[0]), Data([1, 2, 3]))

        let traversal = root.appendingPathComponent("traversal.cbz")
        try makeStoredZip(entries: [("../escape.jpg", Data([1]))], at: traversal)
        XCTAssertThrowsError(try PapriaZipArchive(url: traversal))

        let duplicate = root.appendingPathComponent("duplicate.cbz")
        try makeStoredZip(entries: [("01.jpg", Data([1])), ("01.jpg", Data([2]))], at: duplicate)
        XCTAssertThrowsError(try PapriaZipArchive(url: duplicate))

        let checksumMismatch = root.appendingPathComponent("checksum-mismatch.cbz")
        try makeStoredZip(entries: [("01.jpg", Data([1, 2, 3]))], at: checksumMismatch)
        var checksumBytes = try Data(contentsOf: checksumMismatch)
        let localNameLength = Int(checksumBytes[26]) | Int(checksumBytes[27]) << 8
        checksumBytes[30 + localNameLength] ^= 0xff
        try checksumBytes.write(to: checksumMismatch, options: .atomic)
        let checksumArchive = try PapriaZipArchive(url: checksumMismatch)
        XCTAssertThrowsError(try checksumArchive.data(for: checksumArchive.entries[0]))

        let localNameMismatch = root.appendingPathComponent("local-name-mismatch.cbz")
        try makeStoredZip(entries: [("01.jpg", Data([1, 2, 3]))], at: localNameMismatch)
        var nameBytes = try Data(contentsOf: localNameMismatch)
        nameBytes[30] = 0x78
        try nameBytes.write(to: localNameMismatch, options: .atomic)
        let nameArchive = try PapriaZipArchive(url: localNameMismatch)
        XCTAssertThrowsError(try nameArchive.data(for: nameArchive.entries[0]))
    }

    func testBookOrbitHTTPHostPolicyCanonicalizesLocalTargetsAndRejectsPublicNetworks() {
        XCTAssertEqual(BookOrbitServerURLPolicy.normalizedHost("  Reader.LOCAL...  "), "reader.local")

        for host in ["10.0.0.8", "172.16.0.1", "172.31.255.254", "192.168.1.44", "169.254.8.9", "fd00::1", "fe80::1", "Reader.LOCAL."] {
            XCTAssertTrue(BookOrbitServerURLPolicy.isAllowedHTTPHost(host), "Expected local HTTP host to be permitted: \(host)")
        }
        for host in ["127.0.0.1", "172.15.0.1", "172.32.0.1", "8.8.8.8", "books.example", "reader.local.evil", "local"] {
            XCTAssertFalse(BookOrbitServerURLPolicy.isAllowedHTTPHost(host), "Unexpected non-local HTTP host permission: \(host)")
        }
    }

    func testBookOrbitServerURLPolicyRejectsCredentialsQueriesAndFragments() {
        let invalidURLs = [
            "https://reader:secret@books.example",
            "https://books.example?debug=true",
            "https://books.example#fragment",
            "ftp://192.168.1.2",
            "http://127.0.0.1:8080"
        ]
        for value in invalidURLs {
            XCTAssertThrowsError(
                try BookOrbitServerURLPolicy.validate(value, httpConfirmationTarget: "127.0.0.1:8080"),
                "Unsafe server URL must be rejected: \(value)"
            )
        }
    }

    func testRefreshResponseRequiresNonBlankAccessTokenAndIgnoresExtensions() throws {
        let valid = try JSONDecoder().decode(RefreshResponse.self, from: Data("{\"accessToken\":\"fresh-token\"}".utf8))
        XCTAssertEqual(valid.accessToken, "fresh-token")

        let extended = try JSONDecoder().decode(
            RefreshResponse.self,
            from: Data("{\"accessToken\":\"fresh-token\",\"tokenType\":\"Bearer\"}".utf8)
        )
        XCTAssertEqual(extended.accessToken, "fresh-token")

        for payload in [
            "{}",
            "{\"accessToken\":null}",
            "{\"accessToken\":\" \"}"
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(RefreshResponse.self, from: Data(payload.utf8)), "Refresh payload must contain a non-blank accessToken: \(payload)")
        }
    }

    func testLoginRequestUsesOnlyThePublishedCredentialKeys() throws {
        let request = LoginRequest(username: "reader", password: "p@ss word")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(Set(object.keys), Set(["username", "password"]))
        XCTAssertEqual(object["username"], "reader")
        XCTAssertEqual(object["password"], "p@ss word")
    }

    func testBookOrbitWireModelsRejectBlankAndInvalidFileValues() {
        func filePayload(format: String = "epub", fileName: String = "book.epub", sizeBytes: Int = 12, durationSeconds: String = "null") -> Data {
            Data("""
            {"id":9,"format":"\(format)","filename":"\(fileName)","sizeBytes":\(sizeBytes),"absolutePath":"/server/book.epub","createdAt":"2026-01-01T00:00:00Z","durationSeconds":\(durationSeconds)}
            """.utf8)
        }

        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: filePayload(format: " ")))
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: filePayload(fileName: " ")))
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: filePayload(sizeBytes: -1)))
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteFileRecord.self, from: filePayload(durationSeconds: "-0.1")))

        let blankAuthor = Data("""
        {"id":7,"title":"Book","authors":[{"name":"  "}],"files":[]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BookOrbitBookDetail.self, from: blankAuthor))
    }

    func testLocalTransferRecoveryOffsetHonorsChunkBoundariesAndInvalidSizes() {
        XCTAssertEqual(localTransferRecoveryOffset(actualSize: 0, totalSize: 1), 0)
        XCTAssertEqual(localTransferRecoveryOffset(actualSize: localTransferChunkSize - 1, totalSize: localTransferChunkSize * 2), 0)
        XCTAssertEqual(localTransferRecoveryOffset(actualSize: localTransferChunkSize, totalSize: localTransferChunkSize * 2), localTransferChunkSize)
        XCTAssertEqual(localTransferRecoveryOffset(actualSize: localTransferChunkSize * 2, totalSize: localTransferChunkSize * 2), localTransferChunkSize * 2)
        XCTAssertEqual(localTransferRecoveryOffset(actualSize: localTransferChunkSize + 1, totalSize: localTransferChunkSize + 1), localTransferChunkSize + 1)
        XCTAssertNil(localTransferRecoveryOffset(actualSize: -1, totalSize: 1))
        XCTAssertNil(localTransferRecoveryOffset(actualSize: 2, totalSize: 1))
        XCTAssertNil(localTransferRecoveryOffset(actualSize: 0, totalSize: 0))
    }

    func testContentAddressedStoreDeduplicatesIdenticalFilesWithoutMutatingSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-content-addressed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstSource = root.appendingPathComponent("first.epub")
        let secondSource = root.appendingPathComponent("second.epub")
        let contents = Data("the same publication bytes".utf8)
        try contents.write(to: firstSource)
        try contents.write(to: secondSource)

        let store = try ContentAddressedStore(rootURL: root.appendingPathComponent("content"))
        let first = try store.importFile(at: firstSource)
        let second = try store.importFile(at: secondSource)

        XCTAssertEqual(first.hash, second.hash)
        XCTAssertEqual(first.sizeBytes, Int64(contents.count))
        XCTAssertEqual(first.url, second.url)
        XCTAssertTrue(store.contains(hash: first.hash))
        XCTAssertEqual(try Data(contentsOf: firstSource), contents)
        XCTAssertEqual(try Data(contentsOf: secondSource), contents)
        XCTAssertEqual(try Data(contentsOf: first.url), contents)
    }

    func testSQLiteValueBindingKeepsUntrustedTextAsData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-sql-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try SQLiteDatabase(url: root.appendingPathComponent("library.sqlite3"))
        try database.execute("CREATE TABLE notes (value TEXT NOT NULL);")
        let untrusted = "reading'); DROP TABLE notes; --"
        try database.execute("INSERT INTO notes(value) VALUES (?);", values: [.text(untrusted)])

        XCTAssertEqual(try database.query("SELECT value FROM notes;").first?.text("value"), untrusted)
        XCTAssertEqual(try database.query("SELECT COUNT(*) AS count FROM notes;").first?.integer("count"), 1)
    }

    func testFormatPolicyRejectsUnsafeNamesAndMismatchedContainerSignatures() throws {
        XCTAssertNoThrow(try FormatPolicy.validateName("Readable.EPUB"))
        for name in ["../book.epub", "book\\\\name.epub", "CON.pdf", "book.pdf ", "book.exe", "book\u{0000}.epub"] {
            XCTAssertThrowsError(try FormatPolicy.validateName(name), "Unsafe or unsupported import name must be rejected: \(name)")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papria-format-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disguisedPDF = root.appendingPathComponent("book.pdf")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: disguisedPDF)
        XCTAssertThrowsError(try FormatPolicy.validate(fileURL: disguisedPDF))
    }

    func testTransferResumeTokenHashUsesStableOneWayDigest() {
        let digest = transferResumeTokenHash("abc")
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotEqual(digest, "abc")
        XCTAssertTrue(transferResumeTokenMatches(digest, "abc"))
        XCTAssertFalse(transferResumeTokenMatches(digest, "ABC"))
    }

    @MainActor
    func testAudiobookProgressClampsOverrunAndUsesTrackFallbackForUnknownDurations() {
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 0, positionSeconds: 999, trackDurations: [100]),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 0, positionSeconds: -1, trackDurations: [100]),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioPlaybackService.audiobookPercentage(trackIndex: 2, positionSeconds: 50, trackDurations: [100, nil, 100]),
            83.333_333,
            accuracy: 0.001
        )
    }

    private func makeStoredZip(entries: [(String, Data)], at url: URL) throws {
        var output = Data()
        var central = Data()
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let offset = output.count
            let crc = crc32(data)
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(crc); output.appendLE(UInt32(data.count)); output.appendLE(UInt32(data.count)); output.appendLE(UInt16(nameData.count)); output.appendLE(UInt16(0)); output.append(nameData); output.append(data)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(crc); central.appendLE(UInt32(data.count)); central.appendLE(UInt32(data.count)); central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(UInt32(offset)); central.append(nameData)
        }
        let centralOffset = output.count
        output.append(central)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt32(central.count)); output.appendLE(UInt32(centralOffset)); output.appendLE(UInt16(0))
        try output.write(to: url, options: .atomic)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

private func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
