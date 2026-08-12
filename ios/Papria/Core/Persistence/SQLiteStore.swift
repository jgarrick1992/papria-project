import Foundation
import CryptoKit
import SQLite3

/// A small, dependency-free SQLite wrapper used by the iOS client.
///
/// The wrapper intentionally exposes only the operations Papria needs.  All
/// mutations are performed by `LocalLibraryStore`'s actor, so SQLite remains
/// single-writer while reads can still be awaited from SwiftUI tasks.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    enum Value: Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    struct Row: Sendable {
        private let values: [String: Value]

        init(values: [String: Value]) { self.values = values }

        func text(_ key: String) -> String? {
            guard case .text(let value) = values[key] else { return nil }
            return value
        }

        func integer(_ key: String) -> Int64? {
            guard case .integer(let value) = values[key] else { return nil }
            return value
        }

        func real(_ key: String) -> Double? {
            switch values[key] {
            case .real(let value): return value
            case .integer(let value): return Double(value)
            default: return nil
            }
        }

        func data(_ key: String) -> Data? {
            guard case .blob(let value) = values[key] else { return nil }
            return value
        }
    }

    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "sqlite3_open_v2 failed"
            defer { if let db { sqlite3_close(db) } }
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    @discardableResult
    func execute(_ sql: String, values: [Value] = []) throws -> Int32 {
        guard let handle else { throw SQLiteError.closed }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error()
        }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
        return sqlite3_changes(handle)
    }

    func query(_ sql: String, values: [Value] = []) throws -> [Row] {
        guard let handle else { throw SQLiteError.closed }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error()
        }
        try bind(values, to: statement)
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error() }
            var row: [String: Value] = [:]
            let count = sqlite3_column_count(statement)
            for index in 0..<count {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                let key = String(cString: name)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, index))
                    if let pointer = sqlite3_column_blob(statement, index), length > 0 {
                        row[key] = .blob(Data(bytes: pointer, count: length))
                    } else {
                        row[key] = .blob(Data())
                    }
                case SQLITE_NULL:
                    row[key] = .null
                default:
                    if let pointer = sqlite3_column_text(statement, index) {
                        row[key] = .text(String(cString: pointer))
                    } else {
                        row[key] = .null
                    }
                }
            }
            rows.append(Row(values: row))
        }
        return rows
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .blob(let value):
                result = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw error() }
        }
    }

    private func error() -> SQLiteError {
        guard let handle, let message = sqlite3_errmsg(handle) else { return .unknown }
        return .query(String(cString: message))
    }
}

enum SQLiteError: LocalizedError {
    case open(String)
    case query(String)
    case invalidValue(String)
    case closed
    case unknown

    var errorDescription: String? {
        switch self {
        case .open(let message): return "无法打开本地数据库：\(message)"
        case .query(let message): return "本地数据库错误：\(message)"
        case .invalidValue(let message): return "本地数据无效：\(message)"
        case .closed: return "本地数据库已关闭"
        case .unknown: return "未知本地数据库错误"
        }
    }
}

/// Content-addressed storage.  A downloaded/imported file is named by its
/// SHA-256 digest, so BookOrbit copies and Wi-Fi imports automatically dedupe.
final class ContentAddressedStore: @unchecked Sendable {
    let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL? = nil) throws {
        let base = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria", isDirectory: true)
            .appendingPathComponent("Content", isDirectory: true)
        self.rootURL = base
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func contains(hash: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: hash).path)
    }

    func fileURL(for hash: String) -> URL {
        rootURL.appendingPathComponent(hash, isDirectory: false)
    }

    func ensureCapacity(for additionalBytes: Int64) throws {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard additionalBytes >= 0, available >= additionalBytes + 8 * 1024 * 1024 else {
            throw ContentStoreError.insufficientStorage(required: additionalBytes, available: available)
        }
    }

    /// Imports a complete file without reading it into memory.  The temporary
    /// move is atomic on the same volume and leaves the source untouched.
    func importFile(at sourceURL: URL) throws -> ContentImportResult {
        let (hash, size) = try hashFile(at: sourceURL)
        let destination = fileURL(for: hash)
        if !fileManager.fileExists(atPath: destination.path) {
            try ensureCapacity(for: size)
            let temporary = rootURL.appendingPathComponent(".\(hash).part")
            if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: sourceURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return ContentImportResult(hash: hash, sizeBytes: size, url: destination)
    }

    func remove(hash: String) throws {
        let url = fileURL(for: hash)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func hashFile(at url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var size: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
            size += Int64(data.count)
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

enum ContentStoreError: LocalizedError {
    case insufficientStorage(required: Int64, available: Int64)
    var errorDescription: String? {
        switch self {
        case .insufficientStorage(let required, let available):
            return "存储空间不足：需要 \(required) bytes，可用 \(available) bytes"
        }
    }
}

struct ContentImportResult: Sendable {
    let hash: String
    let sizeBytes: Int64
    let url: URL
}

/// The local source of truth for the library, progress and sync outbox.
actor LocalLibraryStore {
    let database: SQLiteDatabase
    let content: ContentAddressedStore

    init(databaseURL: URL? = nil, contentURL: URL? = nil) throws {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papria", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let dbURL = databaseURL ?? support.appendingPathComponent("papria.sqlite3")
        database = try SQLiteDatabase(url: dbURL)
        content = try ContentAddressedStore(rootURL: contentURL)
        try Self.createSchema(in: database)
    }

    private static func createSchema(in database: SQLiteDatabase) throws {
        // Keep schema changes explicit. The first version of the iOS store
        // pre-dated a migration ledger and created all tables with
        // CREATE TABLE IF NOT EXISTS. A ledger lets later releases add
        // tables/columns without guessing whether an existing database is
        // old, while retaining all user-owned local publications and
        // progress rows.
        try database.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS publications (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          format TEXT NOT NULL,
          file_hash TEXT NOT NULL,
          file_path TEXT NOT NULL,
          source TEXT NOT NULL,
          remote_book_id INTEGER,
          remote_file_id INTEGER,
          size_bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS remote_books (
          id INTEGER PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          cover_url TEXT,
          updated_at TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS remote_files (
          id INTEGER PRIMARY KEY,
          book_id INTEGER NOT NULL,
          file_name TEXT NOT NULL,
          format TEXT NOT NULL,
          size_bytes INTEGER NOT NULL,
          downloaded_hash TEXT,
          updated_at TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS reading_progress (
          scope_id TEXT PRIMARY KEY,
          file_id INTEGER,
          percentage REAL NOT NULL,
          cfi TEXT,
          page_number INTEGER,
          position_seconds REAL,
          kobo_location_source TEXT,
          kobo_location_type TEXT,
          kobo_location_value TEXT,
          kobo_content_source_progress_percent REAL,
          koreader_progress TEXT,
          updated_at TEXT NOT NULL,
          dirty INTEGER NOT NULL DEFAULT 0
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS audio_progress (
          book_id INTEGER PRIMARY KEY,
          percentage REAL NOT NULL,
          current_file_id INTEGER NOT NULL,
          position_seconds REAL NOT NULL,
          updated_at TEXT NOT NULL,
          dirty INTEGER NOT NULL DEFAULT 0
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS audio_playback_settings (
          book_id INTEGER PRIMARY KEY,
          rate REAL NOT NULL DEFAULT 1.0,
          sleep_until TEXT
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS download_tasks (
          file_id INTEGER PRIMARY KEY,
          part_path TEXT NOT NULL,
          offset_bytes INTEGER NOT NULL DEFAULT 0,
          total_bytes INTEGER NOT NULL,
          state TEXT NOT NULL,
          error TEXT,
          updated_at TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sync_outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,
          resource_id INTEGER NOT NULL,
          payload TEXT NOT NULL,
          created_at TEXT NOT NULL,
          retry_count INTEGER NOT NULL DEFAULT 0
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sync_conflicts (
          kind TEXT NOT NULL,
          resource_id INTEGER NOT NULL,
          local_payload TEXT NOT NULL,
          remote_payload TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY(kind, resource_id)
        );
        """)

        // Server profile data is deliberately non-secret. Access tokens and
        // refresh cookies remain Keychain-only in BookOrbitAPIClient; this
        // table stores just the endpoint, account name and an optional
        // user-confirmed certificate fingerprint. The CHECK constraint makes
        // the table a true singleton for the one supported BookOrbit account.
        try database.execute("""
        CREATE TABLE IF NOT EXISTS server_profile (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          server_url TEXT NOT NULL,
          username TEXT NOT NULL,
          certificate_sha256 TEXT,
          http_confirmation_target TEXT,
          updated_at TEXT NOT NULL
        );
        """)

        let migrationRows = try database.query("SELECT version FROM schema_migrations;")
        let appliedMigrations = Set(migrationRows.compactMap { $0.integer("version") })
        if !appliedMigrations.contains(1) {
            // Migration 1 adds the singleton server profile table to stores
            // created before profile persistence was introduced. The CREATE
            // above is idempotent so a partially migrated database is safe
            // to reopen.
            try database.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES (?,?);",
                                 values: [.integer(1), .text(ISO8601DateFormatter().string(from: Date()))])
        }

        if !appliedMigrations.contains(2) {
            // A prior schema allowed missing download sizes. Such rows cannot
            // be resumed safely because the final length check has no
            // expected value, so reject them instead of inventing a value or
            // applying a compatibility mapping.
            try database.execute("DELETE FROM remote_files WHERE size_bytes IS NULL;")
            try database.execute("DELETE FROM download_tasks WHERE total_bytes IS NULL;")
            try database.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES (?,?);",
                                 values: [.integer(2), .text(ISO8601DateFormatter().string(from: Date()))])
        }

        if !appliedMigrations.contains(3) {
            // Kept as a ledger-only historical migration. The former host-only
            // HTTP confirmation is deliberately not materialized for new
            // databases because it is not a complete transport target.
            try database.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES (?,?);",
                                 values: [.integer(3), .text(ISO8601DateFormatter().string(from: Date()))])
        }

        if !appliedMigrations.contains(4) {
            // Host-only confirmations are intentionally not copied into the
            // new target field. Their missing port binding makes them invalid,
            // so the user must explicitly re-confirm the exact HTTP endpoint.
            let profileColumns = try database.query("PRAGMA table_info(server_profile);")
                .compactMap { $0.text("name") }
            if !profileColumns.contains("http_confirmation_target") {
                try database.execute("ALTER TABLE server_profile ADD COLUMN http_confirmation_target TEXT;")
            }
            try database.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES (?,?);",
                                 values: [.integer(4), .text(ISO8601DateFormatter().string(from: Date()))])
        }

        if !appliedMigrations.contains(5) {
            // Remote progress has no contract-defined revision or updatedAt
            // value. Do not infer a baseline from a local row: an existing
            // dirty position may be the first local upload. A baseline is
            // created only by an actual successful remote GET.
            try database.execute("""
            CREATE TABLE IF NOT EXISTS file_progress_remote_baseline (
              file_id INTEGER PRIMARY KEY,
              percentage REAL NOT NULL,
              cfi TEXT,
              page_number INTEGER,
              position_seconds REAL,
              kobo_location_source TEXT,
              kobo_location_type TEXT,
              kobo_location_value TEXT,
              kobo_content_source_progress_percent REAL,
              koreader_progress TEXT,
              pulled_at TEXT NOT NULL
            );
            """)
            try database.execute("""
            CREATE TABLE IF NOT EXISTS audio_progress_remote_baseline (
              book_id INTEGER PRIMARY KEY,
              remote_present INTEGER NOT NULL CHECK(remote_present IN (0, 1)),
              percentage REAL,
              current_file_id INTEGER,
              position_seconds REAL,
              pulled_at TEXT NOT NULL,
              CHECK((remote_present = 0 AND percentage IS NULL AND current_file_id IS NULL AND position_seconds IS NULL)
                 OR (remote_present = 1 AND percentage IS NOT NULL AND current_file_id IS NOT NULL AND position_seconds IS NOT NULL))
            );
            """)
            try database.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES (?,?);",
                                 values: [.integer(5), .text(ISO8601DateFormatter().string(from: Date()))])
        }

        // Additive migration for databases created before Kobo/KOReader
        // progress fields were persisted. No local publication is discarded.
        let columns = try database.query("PRAGMA table_info(reading_progress);")
            .compactMap { $0.text("name") }
        let additions: [(String, String)] = [
            ("kobo_location_source", "TEXT"),
            ("kobo_location_type", "TEXT"),
            ("kobo_location_value", "TEXT"),
            ("kobo_content_source_progress_percent", "REAL"),
            ("koreader_progress", "TEXT")
        ]
        for (name, type) in additions where !columns.contains(name) {
            try database.execute("ALTER TABLE reading_progress ADD COLUMN \(name) \(type);")
        }
    }

    func publications() throws -> [LocalPublication] {
        try database.query("SELECT id,title,author,format,file_hash,file_path,source,remote_book_id,remote_file_id,size_bytes,created_at,updated_at FROM publications ORDER BY updated_at DESC;").compactMap { row in
            guard let id = row.text("id"), let title = row.text("title"), let format = row.text("format"),
                  let hash = row.text("file_hash"), let path = row.text("file_path"), let source = row.text("source"),
                  let size = row.integer("size_bytes"), let created = row.text("created_at"), let updated = row.text("updated_at") else { return nil }
            return LocalPublication(id: id, title: title, author: row.text("author"), format: format, fileHash: hash,
                                    filePath: path, source: source, remoteBookId: row.integer("remote_book_id"),
                                    remoteFileId: row.integer("remote_file_id"), sizeBytes: size, createdAt: created, updatedAt: updated)
        }
    }

    func upsertPublication(_ publication: LocalPublication) throws {
        try database.execute("""
        INSERT INTO publications (id,title,author,format,file_hash,file_path,source,remote_book_id,remote_file_id,size_bytes,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title,author=excluded.author,format=excluded.format,file_hash=excluded.file_hash,file_path=excluded.file_path,source=excluded.source,remote_book_id=excluded.remote_book_id,remote_file_id=excluded.remote_file_id,size_bytes=excluded.size_bytes,updated_at=excluded.updated_at;
        """, values: publicationValues(publication))
    }

    /// Removes only the local publication reference. The remote BookOrbit file
    /// is never touched; shared content is deleted only when no other local
    /// publication still references its SHA-256 object.
    func deletePublication(_ publication: LocalPublication) throws {
        try database.execute("DELETE FROM publications WHERE id=?;", values: [.text(publication.id)])
        if let remoteFileId = publication.remoteFileId {
            try database.execute("DELETE FROM download_tasks WHERE file_id=?;", values: [.integer(remoteFileId)])
        }
        let references = try database.query("SELECT 1 FROM publications WHERE file_hash=? LIMIT 1;", values: [.text(publication.fileHash)])
        if references.isEmpty { try content.remove(hash: publication.fileHash) }
    }

    func importLocalFile(at url: URL, title: String? = nil, source: String = "local") throws -> LocalPublication {
        try FormatPolicy.validate(fileURL: url, fileName: title ?? url.lastPathComponent)
        let imported = try content.importFile(at: url)
        let filename = url.deletingPathExtension().lastPathComponent
        let format = url.pathExtension.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())
        let publication = LocalPublication(id: "\(source)-\(imported.hash)", title: title ?? filename,
                                           author: nil, format: format, fileHash: imported.hash,
                                           filePath: imported.url.path, source: source, remoteBookId: nil,
                                           remoteFileId: nil, sizeBytes: imported.sizeBytes,
                                           createdAt: now, updatedAt: now)
        try upsertPublication(publication)
        return publication
    }

    func importDownloadedFile(at url: URL, title: String, format: String, remoteBookId: Int64, remoteFileId: Int64) throws -> LocalPublication {
        try FormatPolicy.validate(fileURL: url, fileName: title)
        let imported = try content.importFile(at: url)
        let now = ISO8601DateFormatter().string(from: Date())
        let publication = LocalPublication(id: "remote-file-\(remoteFileId)", title: title,
                                           author: nil, format: format, fileHash: imported.hash,
                                           filePath: imported.url.path, source: "bookorbit", remoteBookId: remoteBookId,
                                           remoteFileId: remoteFileId, sizeBytes: imported.sizeBytes,
                                           createdAt: now, updatedAt: now)
        try upsertPublication(publication)
        return publication
    }

    func saveProgress(fileId: Int64, progress: FileProgressPayload, enqueue: Bool = true) throws {
        let scope = "file:\(fileId)"
        try database.execute("""
        INSERT INTO reading_progress(scope_id,file_id,percentage,cfi,page_number,position_seconds,kobo_location_source,kobo_location_type,kobo_location_value,kobo_content_source_progress_percent,koreader_progress,updated_at,dirty)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(scope_id) DO UPDATE SET percentage=excluded.percentage,cfi=excluded.cfi,page_number=excluded.page_number,position_seconds=excluded.position_seconds,kobo_location_source=excluded.kobo_location_source,kobo_location_type=excluded.kobo_location_type,kobo_location_value=excluded.kobo_location_value,kobo_content_source_progress_percent=excluded.kobo_content_source_progress_percent,koreader_progress=excluded.koreader_progress,updated_at=excluded.updated_at,dirty=excluded.dirty;
        """, values: [.text(scope), .integer(fileId), .real(progress.percentage), progress.cfi.map(SQLiteDatabase.Value.text) ?? .null,
                        progress.pageNumber.map { .integer(Int64($0)) } ?? .null, progress.positionSeconds.map(SQLiteDatabase.Value.real) ?? .null,
                        progress.koboLocationSource.map(SQLiteDatabase.Value.text) ?? .null,
                        progress.koboLocationType.map(SQLiteDatabase.Value.text) ?? .null,
                        progress.koboLocationValue.map(SQLiteDatabase.Value.text) ?? .null,
                        progress.koboContentSourceProgressPercent.map(SQLiteDatabase.Value.real) ?? .null,
                        progress.koreaderProgress.map(SQLiteDatabase.Value.text) ?? .null,
                        .text(progress.updatedAt ?? ISO8601DateFormatter().string(from: Date())), .integer(progress.dirty || enqueue ? 1 : 0)])
        if enqueue {
            let payload = try String(data: JSONEncoder().encode(progress), encoding: .utf8) ?? "{}"
            try database.execute("DELETE FROM sync_outbox WHERE kind=? AND resource_id=?;", values: [.text("file_progress"), .integer(fileId)])
            try database.execute("INSERT INTO sync_outbox(kind,resource_id,payload,created_at) VALUES (?,?,?,?);",
                                 values: [.text("file_progress"), .integer(fileId), .text(payload), .text(ISO8601DateFormatter().string(from: Date()))])
        }
    }

    func loadProgress(fileId: Int64) throws -> FileProgressPayload? {
        guard let row = try database.query("SELECT percentage,cfi,page_number,position_seconds,kobo_location_source,kobo_location_type,kobo_location_value,kobo_content_source_progress_percent,koreader_progress,updated_at,dirty FROM reading_progress WHERE scope_id=? LIMIT 1;", values: [.text("file:\(fileId)")]).first,
              let percentage = row.real("percentage") else { return nil }
        return FileProgressPayload(percentage: percentage, cfi: row.text("cfi"), pageNumber: row.integer("page_number").map(Int.init), positionSeconds: row.real("position_seconds"), updatedAt: row.text("updated_at"), dirty: row.integer("dirty") == 1,
                                   koboLocationSource: row.text("kobo_location_source"), koboLocationType: row.text("kobo_location_type"), koboLocationValue: row.text("kobo_location_value"), koboContentSourceProgressPercent: row.real("kobo_content_source_progress_percent"), koreaderProgress: row.text("koreader_progress"))
    }

    /// Persists exactly the last remote file-progress response that was read
    /// successfully. This is intentionally separate from local progress: a
    /// dirty local row may be a user's first upload and therefore cannot be
    /// treated as a remote conflict baseline.
    func saveFileProgressRemoteBaseline(fileId: Int64, progress: FileProgressPayload) throws {
        try database.execute("""
        INSERT INTO file_progress_remote_baseline(file_id,percentage,cfi,page_number,position_seconds,kobo_location_source,kobo_location_type,kobo_location_value,kobo_content_source_progress_percent,koreader_progress,pulled_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET percentage=excluded.percentage,cfi=excluded.cfi,page_number=excluded.page_number,position_seconds=excluded.position_seconds,kobo_location_source=excluded.kobo_location_source,kobo_location_type=excluded.kobo_location_type,kobo_location_value=excluded.kobo_location_value,kobo_content_source_progress_percent=excluded.kobo_content_source_progress_percent,koreader_progress=excluded.koreader_progress,pulled_at=excluded.pulled_at;
        """, values: [.integer(fileId), .real(progress.percentage), progress.cfi.map(SQLiteDatabase.Value.text) ?? .null,
                       progress.pageNumber.map { .integer(Int64($0)) } ?? .null, progress.positionSeconds.map(SQLiteDatabase.Value.real) ?? .null,
                       progress.koboLocationSource.map(SQLiteDatabase.Value.text) ?? .null,
                       progress.koboLocationType.map(SQLiteDatabase.Value.text) ?? .null,
                       progress.koboLocationValue.map(SQLiteDatabase.Value.text) ?? .null,
                       progress.koboContentSourceProgressPercent.map(SQLiteDatabase.Value.real) ?? .null,
                       progress.koreaderProgress.map(SQLiteDatabase.Value.text) ?? .null,
                       .text(ISO8601DateFormatter().string(from: Date()))])
    }

    func fileProgressRemoteBaseline(fileId: Int64) throws -> FileProgressPayload? {
        guard let row = try database.query("SELECT percentage,cfi,page_number,position_seconds,kobo_location_source,kobo_location_type,kobo_location_value,kobo_content_source_progress_percent,koreader_progress FROM file_progress_remote_baseline WHERE file_id=? LIMIT 1;", values: [.integer(fileId)]).first,
              let percentage = row.real("percentage") else { return nil }
        return FileProgressPayload(percentage: percentage, cfi: row.text("cfi"), pageNumber: row.integer("page_number").map(Int.init), positionSeconds: row.real("position_seconds"), dirty: false,
                                   koboLocationSource: row.text("kobo_location_source"), koboLocationType: row.text("kobo_location_type"), koboLocationValue: row.text("kobo_location_value"), koboContentSourceProgressPercent: row.real("kobo_content_source_progress_percent"), koreaderProgress: row.text("koreader_progress"))
    }

    func saveAudioProgress(bookId: Int64, progress: AudioProgressPayload, enqueue: Bool = true) throws {
        let updated = progress.updatedAt ?? ISO8601DateFormatter().string(from: Date())
        try database.execute("""
        INSERT INTO audio_progress(book_id,percentage,current_file_id,position_seconds,updated_at,dirty)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(book_id) DO UPDATE SET percentage=excluded.percentage,current_file_id=excluded.current_file_id,position_seconds=excluded.position_seconds,updated_at=excluded.updated_at,dirty=excluded.dirty;
        """, values: [.integer(bookId), .real(progress.percentage), .integer(progress.currentFileId), .real(progress.positionSeconds), .text(updated), .integer(progress.dirty || enqueue ? 1 : 0)])
        if enqueue {
            let payload = try String(data: JSONEncoder().encode(progress), encoding: .utf8) ?? "{}"
            try database.execute("DELETE FROM sync_outbox WHERE kind=? AND resource_id=?;", values: [.text("audio_progress"), .integer(bookId)])
            try database.execute("INSERT INTO sync_outbox(kind,resource_id,payload,created_at) VALUES (?,?,?,?);", values: [.text("audio_progress"), .integer(bookId), .text(payload), .text(updated)])
        }
    }

    func loadAudioProgress(bookId: Int64) throws -> AudioProgressPayload? {
        guard let row = try database.query("SELECT percentage,current_file_id,position_seconds,updated_at,dirty FROM audio_progress WHERE book_id=? LIMIT 1;", values: [.integer(bookId)]).first,
              let percentage = row.real("percentage"), let currentFileId = row.integer("current_file_id"), let seconds = row.real("position_seconds") else { return nil }
        return AudioProgressPayload(percentage: percentage, currentFileId: currentFileId, positionSeconds: seconds, updatedAt: row.text("updated_at"), dirty: row.integer("dirty") == 1)
    }

    func clearAudioProgress(bookId: Int64) throws {
        try database.execute("DELETE FROM audio_progress WHERE book_id=?;", values: [.integer(bookId)])
    }

    /// Records the result of a successful audio-progress GET, including an
    /// explicit absence. The distinction between an absent row and an absent
    /// remote value lets first local uploads establish a fail-safe baseline.
    func saveAudioProgressRemoteBaseline(bookId: Int64, progress: AudioProgressPayload?) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        if let progress {
            try database.execute("""
            INSERT INTO audio_progress_remote_baseline(book_id,remote_present,percentage,current_file_id,position_seconds,pulled_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(book_id) DO UPDATE SET remote_present=excluded.remote_present,percentage=excluded.percentage,current_file_id=excluded.current_file_id,position_seconds=excluded.position_seconds,pulled_at=excluded.pulled_at;
            """, values: [.integer(bookId), .integer(1), .real(progress.percentage), .integer(progress.currentFileId), .real(progress.positionSeconds), .text(now)])
        } else {
            try database.execute("""
            INSERT INTO audio_progress_remote_baseline(book_id,remote_present,percentage,current_file_id,position_seconds,pulled_at)
            VALUES (?,?,NULL,NULL,NULL,?)
            ON CONFLICT(book_id) DO UPDATE SET remote_present=excluded.remote_present,percentage=NULL,current_file_id=NULL,position_seconds=NULL,pulled_at=excluded.pulled_at;
            """, values: [.integer(bookId), .integer(0), .text(now)])
        }
    }

    func audioProgressRemoteBaseline(bookId: Int64) throws -> RemoteAudioProgressBaseline? {
        guard let row = try database.query("SELECT remote_present,percentage,current_file_id,position_seconds FROM audio_progress_remote_baseline WHERE book_id=? LIMIT 1;", values: [.integer(bookId)]).first,
              let present = row.integer("remote_present") else { return nil }
        switch present {
        case 0:
            guard row.real("percentage") == nil, row.integer("current_file_id") == nil, row.real("position_seconds") == nil else {
                throw SQLiteError.invalidValue("音频远端基线无效")
            }
            return .noRemoteProgress
        case 1:
            guard let percentage = row.real("percentage"), let currentFileId = row.integer("current_file_id"), let positionSeconds = row.real("position_seconds") else {
                throw SQLiteError.invalidValue("音频远端基线无效")
            }
            return .remoteProgress(AudioProgressPayload(percentage: percentage, currentFileId: currentFileId, positionSeconds: positionSeconds, dirty: false))
        default:
            throw SQLiteError.invalidValue("音频远端基线无效")
        }
    }

    func saveAudioSettings(bookId: Int64, rate: Double, sleepUntil: Date?) throws {
        let boundedRate = min(3.0, max(0.5, rate))
        let value = sleepUntil.map { ISO8601DateFormatter().string(from: $0) }
        try database.execute("""
        INSERT INTO audio_playback_settings(book_id,rate,sleep_until) VALUES (?,?,?)
        ON CONFLICT(book_id) DO UPDATE SET rate=excluded.rate,sleep_until=excluded.sleep_until;
        """, values: [.integer(bookId), .real(boundedRate), value.map(SQLiteDatabase.Value.text) ?? .null])
    }

    func loadAudioSettings(bookId: Int64) throws -> AudioPlaybackSettings? {
        guard let row = try database.query("SELECT rate,sleep_until FROM audio_playback_settings WHERE book_id=? LIMIT 1;", values: [.integer(bookId)]).first,
              let rate = row.real("rate") else { return nil }
        let sleep = row.text("sleep_until").flatMap { ISO8601DateFormatter().date(from: $0) }
        return AudioPlaybackSettings(rate: rate, sleepUntil: sleep)
    }

    func pendingOutbox() throws -> [SyncOutboxItem] {
        try database.query("SELECT id,kind,resource_id,payload,created_at,retry_count FROM sync_outbox ORDER BY id ASC;").compactMap { row in
            guard let id = row.integer("id"), let kind = row.text("kind"), let resource = row.integer("resource_id"), let payload = row.text("payload"), let created = row.text("created_at") else { return nil }
            return SyncOutboxItem(id: id, kind: kind, resourceId: resource, payload: payload, createdAt: created, retryCount: row.integer("retry_count") ?? 0)
        }
    }

    func removeOutbox(id: Int64) throws {
        try database.execute("DELETE FROM sync_outbox WHERE id=?;", values: [.integer(id)])
    }

    func bumpOutbox(id: Int64) throws {
        // A negative retry count is the local "keep local" force-upload
        // marker. Preserve it across transient failures until the verified
        // upload succeeds.
        try database.execute("UPDATE sync_outbox SET retry_count=CASE WHEN retry_count < 0 THEN retry_count ELSE retry_count+1 END WHERE id=?;", values: [.integer(id)])
    }

    func forceOutbox(id: Int64) throws {
        try database.execute("UPDATE sync_outbox SET retry_count=-1 WHERE id=?;", values: [.integer(id)])
    }

    func saveConflict(_ conflict: SyncConflict) throws {
        try database.execute("""
        INSERT INTO sync_conflicts(kind,resource_id,local_payload,remote_payload,created_at)
        VALUES (?,?,?,?,?) ON CONFLICT(kind,resource_id) DO UPDATE SET local_payload=excluded.local_payload,remote_payload=excluded.remote_payload,created_at=excluded.created_at;
        """, values: [.text(conflict.kind), .integer(conflict.resourceId), .text(conflict.localPayload), .text(conflict.remotePayload), .text(conflict.createdAt)])
    }

    func conflicts() throws -> [SyncConflict] {
        try database.query("SELECT kind,resource_id,local_payload,remote_payload,created_at FROM sync_conflicts ORDER BY created_at ASC;").compactMap { row in
            guard let kind = row.text("kind"), let resource = row.integer("resource_id"), let local = row.text("local_payload"), let remote = row.text("remote_payload"), let created = row.text("created_at") else { return nil }
            return SyncConflict(kind: kind, resourceId: resource, localPayload: local, remotePayload: remote, createdAt: created)
        }
    }

    func hasConflict(kind: String, resourceId: Int64) throws -> Bool {
        !(try database.query("SELECT 1 FROM sync_conflicts WHERE kind=? AND resource_id=? LIMIT 1;", values: [.text(kind), .integer(resourceId)])).isEmpty
    }

    func removeConflict(kind: String, resourceId: Int64) throws {
        try database.execute("DELETE FROM sync_conflicts WHERE kind=? AND resource_id=?;", values: [.text(kind), .integer(resourceId)])
    }

    func saveRemoteBooks(_ books: [RemoteBookRecord]) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        for book in books {
            try database.execute("INSERT INTO remote_books(id,title,author,cover_url,updated_at) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,author=excluded.author,cover_url=excluded.cover_url,updated_at=excluded.updated_at;", values: [.integer(book.id), .text(book.title), book.author.map(SQLiteDatabase.Value.text) ?? .null, book.coverURL.map(SQLiteDatabase.Value.text) ?? .null, .text(now)])
        }
    }

    /// Returns the locally persisted BookOrbit catalog without issuing any
    /// network request. Rows are ordered by their last successful refresh so
    /// an offline launch sees the same catalog ordering as the saved cache.
    func remoteBooks() throws -> [RemoteBookRecord] {
        try database.query("SELECT id,title,author,cover_url FROM remote_books ORDER BY updated_at DESC, id ASC;").compactMap { row in
            guard let id = row.integer("id"),
                  let title = row.text("title"),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return RemoteBookRecord(id: id, title: title, author: row.text("author"), coverURL: row.text("cover_url"))
        }
    }

    /// Replaces the cached remote catalog after a complete successful refresh.
    /// Detail/file metadata is kept separately because active downloads and
    /// local BookOrbit publications still depend on those rows.
    func replaceRemoteBooks(_ books: [RemoteBookRecord]) throws {
        try database.execute("DELETE FROM remote_books;")
        let now = ISO8601DateFormatter().string(from: Date())
        for book in books {
            try database.execute(
                "INSERT INTO remote_books(id,title,author,cover_url,updated_at) VALUES (?,?,?,?,?);",
                values: [.integer(book.id), .text(book.title),
                         book.author.map(SQLiteDatabase.Value.text) ?? .null,
                         book.coverURL.map(SQLiteDatabase.Value.text) ?? .null,
                         .text(now)]
            )
        }
        try database.execute(
            "DELETE FROM remote_files WHERE book_id NOT IN (SELECT id FROM remote_books) AND id NOT IN (SELECT remote_file_id FROM publications WHERE remote_file_id IS NOT NULL) AND id NOT IN (SELECT file_id FROM download_tasks);"
        )
    }

    /// Removes only remote catalog/detail metadata that is not needed by a
    /// downloaded publication or an unfinished/completed task. Local books,
    /// progress, task rows and content-addressed files are never deleted.
    func clearBookOrbitCatalogCache() throws {
        try database.execute(
            "DELETE FROM remote_files WHERE id NOT IN (SELECT remote_file_id FROM publications WHERE remote_file_id IS NOT NULL) AND id NOT IN (SELECT file_id FROM download_tasks);"
        )
        try database.execute("DELETE FROM remote_books;")
    }

    /// Returns the one persisted BookOrbit endpoint/account profile. Secrets
    /// are intentionally absent: access tokens and refresh cookies live in
    /// Keychain and are never copied into SQLite or Codable profile payloads.
    func serverProfile() throws -> ServerProfile? {
        guard let row = try database.query("SELECT server_url,username,certificate_sha256,http_confirmation_target,updated_at FROM server_profile WHERE id=1 LIMIT 1;").first,
              let serverURL = row.text("server_url"),
              let username = row.text("username"),
              let updatedAt = row.text("updated_at") else { return nil }
        return ServerProfile(serverURL: serverURL, username: username,
                             certificateSha256: row.text("certificate_sha256"),
                             httpConfirmationTarget: row.text("http_confirmation_target"), updatedAt: updatedAt)
    }

    /// Atomically replaces the singleton server profile. The caller must
    /// provide a URL that has already passed APIClient's strict HTTPS
    /// validation; this store does not widen the transport security policy.
    func saveServerProfile(_ profile: ServerProfile) throws {
        let serverURL = profile.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty else { throw SQLiteError.invalidValue("服务器地址不能为空") }
        guard !username.isEmpty else { throw SQLiteError.invalidValue("账号不能为空") }
        let trimmedCertificate = profile.certificateSha256?.trimmingCharacters(in: .whitespacesAndNewlines)
        let certificate = trimmedCertificate?.isEmpty == false ? trimmedCertificate : nil
        let updatedAt = profile.updatedAt.isEmpty ? ISO8601DateFormatter().string(from: Date()) : profile.updatedAt
        try database.execute("""
        INSERT INTO server_profile(id,server_url,username,certificate_sha256,http_confirmation_target,updated_at)
        VALUES (1,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET server_url=excluded.server_url,
          username=excluded.username,certificate_sha256=excluded.certificate_sha256,
          http_confirmation_target=excluded.http_confirmation_target,
          updated_at=excluded.updated_at;
        """, values: [.text(serverURL), .text(username),
                       certificate.map(SQLiteDatabase.Value.text) ?? .null,
                       profile.httpConfirmationTarget.map(SQLiteDatabase.Value.text) ?? .null,
                       .text(updatedAt)])
    }

    /// Removes the endpoint/account profile while leaving local publications,
    /// downloaded files and progress untouched. Keychain session cleanup is
    /// owned by BookOrbitAPIClient.logout().
    func deleteServerProfile() throws {
        try database.execute("DELETE FROM server_profile WHERE id=1;")
    }

    func beginDownload(fileId: Int64, partURL: URL, totalBytes: Int64) throws {
        guard totalBytes >= 0 else { throw SQLiteError.invalidValue("下载大小无效") }
        let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path)
        let current = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let now = ISO8601DateFormatter().string(from: Date())
        try database.execute("INSERT INTO download_tasks(file_id,part_path,offset_bytes,total_bytes,state,error,updated_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET part_path=excluded.part_path,offset_bytes=excluded.offset_bytes,total_bytes=excluded.total_bytes,state=excluded.state,error=NULL,updated_at=excluded.updated_at;", values: [.integer(fileId), .text(partURL.path), .integer(current), .integer(totalBytes), .text("downloading"), .null, .text(now)])
    }

    func updateDownload(fileId: Int64, offset: Int64, totalBytes: Int64, error: String? = nil) throws {
        guard totalBytes >= 0 else { throw SQLiteError.invalidValue("下载大小无效") }
        try database.execute("UPDATE download_tasks SET offset_bytes=?,total_bytes=?,state=?,error=?,updated_at=? WHERE file_id=?;", values: [.integer(offset), .integer(totalBytes), .text(error == nil ? "downloading" : "failed"), error.map(SQLiteDatabase.Value.text) ?? .null, .text(ISO8601DateFormatter().string(from: Date())), .integer(fileId)])
    }

    func setDownloadState(fileId: Int64, state: String, error: String? = nil) throws {
        try database.execute("UPDATE download_tasks SET state=?,error=?,updated_at=? WHERE file_id=?;", values: [.text(state), error.map(SQLiteDatabase.Value.text) ?? .null, .text(ISO8601DateFormatter().string(from: Date())), .integer(fileId)])
    }

    func finishDownload(fileId: Int64) throws {
        try database.execute("UPDATE download_tasks SET state='completed',error=NULL,updated_at=? WHERE file_id=?;", values: [.text(ISO8601DateFormatter().string(from: Date())), .integer(fileId)])
    }

    /// Completed rows are task-center history, not the downloaded publication
    /// itself. They remain available until the user clears completed tasks.
    func completedDownloads() throws -> [DownloadTaskRecord] {
        try downloadTasks(where: "state = 'completed'")
    }

    /// Clearing completed task history must survive a process restart. This
    /// only removes terminal `download_tasks` rows; local publications and
    /// content-addressed files are intentionally untouched.
    func clearCompletedDownloads() throws {
        try database.execute("DELETE FROM download_tasks WHERE state='completed';")
    }

    /// Returns resumable download rows after an app relaunch. Paused and
    /// failed rows remain visible to the UI; queued/downloading rows are
    /// eligible for automatic foreground recovery.
    func pendingDownloads() throws -> [DownloadTaskRecord] {
        try downloadTasks(where: "state <> 'completed'")
    }

    private func downloadTasks(where predicate: String) throws -> [DownloadTaskRecord] {
        try database.query("SELECT file_id,part_path,offset_bytes,total_bytes,state,error,updated_at FROM download_tasks WHERE \(predicate) ORDER BY updated_at ASC;").compactMap { row in
            guard let fileId = row.integer("file_id"), let partPath = row.text("part_path"),
                  let offset = row.integer("offset_bytes"), let state = row.text("state"),
                  let totalBytes = row.integer("total_bytes"), let updatedAt = row.text("updated_at") else { return nil }
            return DownloadTaskRecord(fileId: fileId, partPath: partPath, offsetBytes: offset,
                                      totalBytes: totalBytes, state: state,
                                      error: row.text("error"), updatedAt: updatedAt)
        }
    }

    func saveRemoteFiles(bookId: Int64, files: [RemoteFileRecord]) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        for file in files {
            try database.execute("""
            INSERT INTO remote_files(id,book_id,file_name,format,size_bytes,downloaded_hash,updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET book_id=excluded.book_id,file_name=excluded.file_name,format=excluded.format,size_bytes=excluded.size_bytes,updated_at=excluded.updated_at;
            """, values: [.integer(file.id), .integer(bookId), .text(file.fileName), .text(file.format),
                            .integer(file.sizeBytes), .null, .text(now)])
        }
    }

    /// Cached detail entries for one BookOrbit book. `role` and
    /// `durationSeconds` were intentionally not persisted in the pre-existing
    /// table, so they are nil here rather than inferred from another source.
    func remoteFiles(bookId: Int64) throws -> [RemoteFileRecord] {
        try database.query("SELECT id,file_name,format,size_bytes FROM remote_files WHERE book_id=? ORDER BY updated_at ASC, id ASC;", values: [.integer(bookId)]).compactMap { row in
            guard let id = row.integer("id"),
                  let fileName = row.text("file_name"),
                  let format = row.text("format"),
                  let sizeBytes = row.integer("size_bytes"),
                  !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sizeBytes >= 0 else { return nil }
            return RemoteFileRecord(id: id, fileName: fileName, format: format, sizeBytes: sizeBytes, role: nil, durationSeconds: nil)
        }
    }

    func remoteFile(fileId: Int64) throws -> RemoteFileRecord? {
        guard let value = try remoteFileWithBook(fileId: fileId) else { return nil }
        return value.file
    }

    func remoteFileWithBook(fileId: Int64) throws -> (file: RemoteFileRecord, bookId: Int64)? {
        guard let row = try database.query("SELECT id,book_id,file_name,format,size_bytes FROM remote_files WHERE id=? LIMIT 1;", values: [.integer(fileId)]).first,
              let bookId = row.integer("book_id"),
              let id = row.integer("id"), let fileName = row.text("file_name"), let format = row.text("format"),
              let sizeBytes = row.integer("size_bytes"), sizeBytes >= 0 else { return nil }
        return (RemoteFileRecord(id: id, fileName: fileName, format: format, sizeBytes: sizeBytes, role: nil, durationSeconds: nil), bookId)
    }

    private func publicationValues(_ value: LocalPublication) -> [SQLiteDatabase.Value] {
        [.text(value.id), .text(value.title), value.author.map(SQLiteDatabase.Value.text) ?? .null, .text(value.format), .text(value.fileHash), .text(value.filePath), .text(value.source), value.remoteBookId.map(SQLiteDatabase.Value.integer) ?? .null, value.remoteFileId.map(SQLiteDatabase.Value.integer) ?? .null, .integer(value.sizeBytes), .text(value.createdAt), .text(value.updatedAt)]
    }
}

struct LocalPublication: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let author: String?
    let format: String
    let fileHash: String
    let filePath: String
    let source: String
    let remoteBookId: Int64?
    let remoteFileId: Int64?
    let sizeBytes: Int64
    let createdAt: String
    let updatedAt: String

    /// Local-only publications use a stable negative key for the same
    /// `reading_progress` table without ever creating a BookOrbit outbox item.
    var progressFileId: Int64 {
        if let remoteFileId { return remoteFileId }
        let prefix = String(fileHash.prefix(15))
        let value = UInt64(prefix, radix: 16) ?? 1
        let magnitude = Int64(value & 0x7fff_ffff_ffff_ffff)
        return magnitude == 0 ? -1 : -magnitude
    }
}

/// Non-secret BookOrbit connection metadata persisted by LocalLibraryStore.
/// Access tokens, passwords and refresh cookies must never be added here.
struct ServerProfile: Codable, Equatable, Sendable {
    let serverURL: String
    let username: String
    let certificateSha256: String?
    let httpConfirmationTarget: String?
    let updatedAt: String

    init(serverURL: String, username: String, certificateSha256: String?, httpConfirmationTarget: String? = nil, updatedAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.serverURL = serverURL
        self.username = username
        self.certificateSha256 = certificateSha256
        self.httpConfirmationTarget = httpConfirmationTarget
        self.updatedAt = updatedAt
    }
}

struct DownloadTaskRecord: Codable, Equatable, Sendable {
    let fileId: Int64
    let partPath: String
    let offsetBytes: Int64
    let totalBytes: Int64
    let state: String
    let error: String?
    let updatedAt: String
}

struct AudioPlaybackSettings: Sendable, Equatable {
    let rate: Double
    let sleepUntil: Date?
}

enum RemoteAudioProgressBaseline: Equatable, Sendable {
    case noRemoteProgress
    case remoteProgress(AudioProgressPayload)
}

struct RemoteBookRecord: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let author: String?
    let coverURL: String?

    private enum CodingKeys: String, CodingKey { case id, title, authors, coverURL }

    init(id: Int64, title: String, author: String?, coverURL: String?) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        let decodedTitle = try values.decode(String.self, forKey: .title)
        guard !decodedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: values, debugDescription: "title must not be blank")
        }
        title = decodedTitle
        let authors = try values.decode([String].self, forKey: .authors)
        author = authors.first
        coverURL = nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(author.map { [$0] } ?? [], forKey: .authors)
        try values.encodeIfPresent(coverURL, forKey: .coverURL)
    }
}

struct SyncOutboxItem: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let kind: String
    let resourceId: Int64
    let payload: String
    let createdAt: String
    let retryCount: Int64
}

struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(kind):\(resourceId)" }
    let kind: String
    let resourceId: Int64
    let localPayload: String
    let remotePayload: String
    let createdAt: String
}
