import Foundation
import CryptoKit
import Security
import Network

enum BookOrbitServerURLPolicy {
    static func validate(_ value: String, httpConfirmationTarget: String?) throws -> URL {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw BookOrbitAPIError.invalidURL
        }

        switch scheme {
        case "https":
            guard httpConfirmationTarget == nil else { throw BookOrbitAPIError.httpConfirmationTargetMismatch }
        case "http":
            guard isAllowedHTTPHost(host) else { throw BookOrbitAPIError.httpHostNotAllowed }
            guard let target = Self.httpConfirmationTarget(for: url),
                  httpConfirmationTarget == target else {
                throw BookOrbitAPIError.httpConfirmationRequired
            }
        default:
            throw BookOrbitAPIError.invalidURL
        }
        return url
    }

    /// Returns the canonical, port-bound target that the user explicitly
    /// confirmed for a local cleartext BookOrbit server. The default HTTP
    /// port is materialized so `http://host` and `http://host:80` share the
    /// same transport target.
    static func httpConfirmationTarget(for value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: normalized),
              url.scheme?.lowercased() == "http" else { return nil }
        return httpConfirmationTarget(for: url)
    }

    private static func httpConfirmationTarget(for url: URL) -> String? {
        guard let host = url.host,
              !host.isEmpty else { return nil }
        let port = url.port ?? 80
        guard (1...65_535).contains(port) else { return nil }
        let normalized = normalizedHost(host)
        let renderedHost = normalized.contains(":") ? "[\(normalized)]" : normalized
        return "\(renderedHost):\(port)"
    }

    static func isAllowedHTTPHost(_ host: String) -> Bool {
        let value = normalizedHost(host)
        if value.hasSuffix(".local") && value.count > ".local".count { return true }

        if let address = IPv4Address(value) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
        }

        if let address = IPv6Address(value) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            return (bytes[0] & 0xfe) == 0xfc
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
        return false
    }

    static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

/// Strict BookOrbit v2.5.0 client.  Endpoint paths and JSON keys intentionally
/// mirror the published contract; no fallback aliases are attempted.
actor BookOrbitAPIClient {
    private let tokenStore: KeychainTokenStore
    private let session: URLSession
    private let pinningDelegate: CertificatePinningDelegate
    private var baseURL: URL?
    private var accessToken: String?

    init(tokenStore: KeychainTokenStore = KeychainTokenStore()) {
        self.tokenStore = tokenStore
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        pinningDelegate = CertificatePinningDelegate()
        session = URLSession(configuration: configuration, delegate: pinningDelegate, delegateQueue: nil)
    }

    /// Restores transport state from the non-secret local profile. The
    /// profile itself is owned by LocalLibraryStore; this actor only keeps the
    /// active URL in memory and retrieves bearer/cookie secrets from Keychain.
    func restore(profile: ServerProfile) async throws -> Bool {
        let url = try BookOrbitServerURLPolicy.validate(profile.serverURL, httpConfirmationTarget: profile.httpConfirmationTarget)
        pinningDelegate.setFingerprint(profile.certificateSha256)
        baseURL = url
        restoreRefreshCookie(for: url)
        accessToken = try tokenStore.load(account: tokenAccount(for: url))
        if accessToken == nil {
            // A process restart can discard the in-memory bearer while the
            // refresh cookie remains in Keychain. Re-establish the bearer
            // through the strict refresh endpoint before touching the library.
            guard try tokenStore.load(account: refreshCookieAccount(for: url)) != nil else { return false }
            try await refresh()
        }
        let version = try await appInfo()
        guard version == "v2.5.0" else { throw BookOrbitAPIError.unsupportedVersion(version) }
        _ = try await me()
        return true
    }

    func logout() {
        if let baseURL {
            tokenStore.delete(account: tokenAccount(for: baseURL))
            tokenStore.delete(account: refreshCookieAccount(for: baseURL))
        }
        accessToken = nil
        baseURL = nil
    }

    func login(serverURL: String, username: String, password: String, certificateSha256: String? = nil, httpConfirmationTarget: String?) async throws -> BookOrbitSession {
        let previousBaseURL = baseURL
        let previousAccessToken = accessToken
        let previousFingerprint = pinningDelegate.fingerprintValue()
        do {
            let url = try BookOrbitServerURLPolicy.validate(serverURL, httpConfirmationTarget: httpConfirmationTarget)
            pinningDelegate.setFingerprint(certificateSha256)
            // Keep the previous session intact until the replacement login
            // completes the strict app-info and /auth/me handshake.
            baseURL = url
            var request = URLRequest(url: endpoint(path: "/auth/login", base: url))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password))
            // Some v2.5.0 deployments establish the access/refresh cookies and
            // intentionally return an empty 204 body. Papria deliberately does
            // not support that cookie-only variant: the strict client requires
            // the same non-empty accessToken response field as Android.
            let response = try await sendLogin(request)
            accessToken = response.accessToken
            let version = try await appInfo()
            guard version == "v2.5.0" else {
                throw BookOrbitAPIError.unsupportedVersion(version)
            }
            _ = try await me()
            try tokenStore.save(response.accessToken, account: tokenAccount(for: url))
            persistRefreshCookie(for: url)
            return BookOrbitSession(serverURL: url.absoluteString, username: username, version: version)
        } catch {
            baseURL = previousBaseURL
            accessToken = previousAccessToken
            pinningDelegate.setFingerprint(previousFingerprint)
            if let previousBaseURL { restoreRefreshCookie(for: previousBaseURL) }
            throw error
        }
    }

    func refresh() async throws {
        guard let baseURL else { throw BookOrbitAPIError.notAuthenticated }
        var request = URLRequest(url: endpoint(path: "/auth/refresh", base: baseURL))
        request.httpMethod = "POST"
        let response: RefreshResponse = try await send(request, decode: RefreshResponse.self, authenticated: false)
        accessToken = response.accessToken
        try tokenStore.save(response.accessToken, account: tokenAccount(for: baseURL))
        persistRefreshCookie(for: baseURL)
    }

    func appInfo() async throws -> String {
        let response: AppInfoResponse = try await send(makeRequest(path: "/app-info", method: "GET"), decode: AppInfoResponse.self, authenticated: false)
        return response.version
    }

    func me() async throws -> BookOrbitUser {
        try await send(makeRequest(path: "/auth/me", method: "GET"), decode: BookOrbitUser.self)
    }

    func queryBooks(request query: BookQueryRequest) async throws -> BookQueryResponse {
        var request = makeRequest(path: "/books/query", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(query)
        return try await send(request, decode: BookQueryResponse.self)
    }

    func bookDetail(id: Int64) async throws -> BookOrbitBookDetail {
        try await send(makeRequest(path: "/books/\(id)", method: "GET"), decode: BookOrbitBookDetail.self)
    }

    /// Fetch an authenticated cover as bounded bytes. Covers are cached by
    /// the application layer and never treated as a remote URL in SwiftUI.
    func fetchCover(bookId: Int64) async throws -> Data {
        var request = makeRequest(path: "/books/\(bookId)/cover", method: "GET")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let cookie = HTTPCookieStorage.shared.cookies(for: request.url ?? URL(fileURLWithPath: "/"))?.first(where: { $0.name == "refresh_token" }) {
            request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
        }
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            try await refresh()
            request = makeRequest(path: "/books/\(bookId)/cover", method: "GET")
            if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 16 * 1024 * 1024 else {
            throw BookOrbitAPIError.invalidResponse
        }
        return data
    }

    func fileServeRequest(fileId: Int64, rangeStart: Int64? = nil) throws -> URLRequest {
        var request = makeRequest(path: "/books/files/\(fileId)/serve", method: "GET")
        if let rangeStart { request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range") }
        // Streaming APIs bypass `send(_:decode:)`, so attach the same bearer
        // and refresh-cookie credentials explicitly before URLSession.bytes.
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let cookie = HTTPCookieStorage.shared.cookies(for: request.url ?? URL(fileURLWithPath: "/"))?.first(where: { $0.name == "refresh_token" }) {
            request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// Request descriptor for AVPlayer's HTTP streaming asset. The caller
    /// copies the URL and headers into an AVURLAsset; no token is placed in a
    /// URL or persisted in the reader model.
    func audioStreamRequest(fileId: Int64) throws -> URLRequest {
        try fileServeRequest(fileId: fileId)
    }

    /// AVPlayer owns its follow-up Range requests and therefore cannot pass a
    /// 401 through `send(_:decode:)`. The audio service calls this once after
    /// a remote item failure to renew the bearer/cookie and rebuild the exact
    /// request without placing credentials in the URL.
    func refreshedAudioStreamRequest(fileId: Int64) async throws -> URLRequest {
        try await refresh()
        return try audioStreamRequest(fileId: fileId)
    }

    /// Streams a file into a `.part` file.  A server returning 200 for a
    /// resumed request is treated as a range failure and restarts from zero.
    func download(fileId: Int64, partURL: URL, expectedSize: Int64, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> DownloadResult {
        guard expectedSize >= 0 else { throw BookOrbitAPIError.invalidResponse }
        let fm = FileManager.default
        try fm.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offset: Int64 = 0
        if fm.fileExists(atPath: partURL.path) {
            offset = (try fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        if offset > expectedSize {
            // A stale/corrupt part can outlive a server-side replacement. It
            // must never be used to construct an invalid Range start.
            try? fm.removeItem(at: partURL)
            offset = 0
        }
        let values = try partURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let remaining = max(0, expectedSize - offset)
        guard available >= remaining + 8 * 1024 * 1024 else {
            throw BookOrbitAPIError.insufficientStorage
        }
        var request = try fileServeRequest(fileId: fileId, rangeStart: offset > 0 ? offset : nil)
        var (bytes, response) = try await session.bytes(for: request)
        guard var http = response as? HTTPURLResponse else { throw BookOrbitAPIError.invalidResponse }
        if http.statusCode == 401 {
            // URLSession.bytes does not pass through the Codable request path,
            // so its first response cannot be retried by send(_:decode:).
            // Refresh once and rebuild the request so the new bearer and
            // rotated refresh cookie are attached to the retry.
            try await refresh()
            request = try fileServeRequest(fileId: fileId, rangeStart: offset > 0 ? offset : nil)
            (bytes, response) = try await session.bytes(for: request)
            guard let refreshedHTTP = response as? HTTPURLResponse else { throw BookOrbitAPIError.invalidResponse }
            http = refreshedHTTP
        }
        if offset > 0 && http.statusCode == 200 {
            try? fm.removeItem(at: partURL)
            offset = 0
            request = try fileServeRequest(fileId: fileId)
            (bytes, response) = try await session.bytes(for: request)
        }
        guard let secondHTTP = response as? HTTPURLResponse, (200..<300).contains(secondHTTP.statusCode) || secondHTTP.statusCode == 206 else {
            throw BookOrbitAPIError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if secondHTTP.statusCode == 206 { try validatePartialResponse(secondHTTP, expectedStart: offset, expectedTotal: expectedSize) }
        if offset == 0 {
            if fm.fileExists(atPath: partURL.path) { try fm.removeItem(at: partURL) }
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var received = offset
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(received, expectedSize)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress?(received, expectedSize)
        }
        if received != expectedSize {
            throw BookOrbitAPIError.decoding(DownloadSizeError(expected: expectedSize, actual: received))
        }
        return DownloadResult(partURL: partURL, bytesWritten: received, contentLength: contentLength(from: secondHTTP, offset: offset))
    }

    func fetchProgress(fileId: Int64) async throws -> FileProgressPayload {
        let remote: RemoteFileProgressPayload = try await send(makeRequest(path: "/books/files/\(fileId)/progress", method: "GET"), decode: RemoteFileProgressPayload.self)
        return remote.local
    }

    func saveProgress(fileId: Int64, payload: FileProgressPayload) async throws {
        var request = makeRequest(path: "/books/files/\(fileId)/progress", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoteFileProgressPayload(local: payload))
        _ = try await send(request, decode: EmptyResponse.self)
    }

    func fetchAudioProgress(bookId: Int64) async throws -> AudioProgressPayload? {
        try await send(makeRequest(path: "/books/\(bookId)/audio-progress", method: "GET"), decode: AudioProgressPayload?.self)
    }

    func saveAudioProgress(bookId: Int64, payload: AudioProgressPayload) async throws {
        var request = makeRequest(path: "/books/\(bookId)/audio-progress", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoteAudioProgressPayload(local: payload))
        _ = try await send(request, decode: EmptyResponse.self)
    }

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type, authenticated: Bool = true, allowRefresh: Bool = true) async throws -> T {
        var request = request
        if authenticated, let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BookOrbitAPIError.invalidResponse }
        if http.statusCode == 401, authenticated, allowRefresh {
            try await refresh()
            return try await send(request, decode: type, authenticated: true, allowRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BookOrbitAPIError.httpStatus(http.statusCode)
        }
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw BookOrbitAPIError.decoding(error) }
    }

    private func sendLogin(_ request: URLRequest) async throws -> LoginResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BookOrbitAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BookOrbitAPIError.httpStatus(http.statusCode)
        }
        do { return try JSONDecoder().decode(LoginResponse.self, from: data) }
        catch { throw BookOrbitAPIError.decoding(error) }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint(path: path, base: baseURL!))
        request.httpMethod = method
        return request
    }

    private func endpoint(path: String, base: URL) -> URL {
        base.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func tokenAccount(for url: URL) -> String { "bookorbit:\(url.host ?? url.absoluteString)" }

    private func refreshCookieAccount(for url: URL) -> String { "bookorbit-refresh:\(url.host ?? url.absoluteString)" }

    private func persistRefreshCookie(for url: URL) {
        guard let cookie = HTTPCookieStorage.shared.cookies(for: url)?.first(where: { $0.name == "refresh_token" }) else { return }
        try? tokenStore.save("\(cookie.name)=\(cookie.value)", account: refreshCookieAccount(for: url))
    }

    private func restoreRefreshCookie(for url: URL) {
        let stored: String?
        do {
            stored = try tokenStore.load(account: refreshCookieAccount(for: url))
        } catch {
            return
        }
        guard let raw = stored,
              let separator = raw.firstIndex(of: Character("=")) else { return }
        let name = String(raw[..<separator])
        let value = String(raw[raw.index(after: separator)...])
        guard !name.isEmpty, !value.isEmpty,
              let cookie = HTTPCookie(properties: [
                  .domain: url.host ?? "",
                  .path: "/",
                  .name: name,
                  .value: value,
                  .secure: "TRUE",
              ]) else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
    }

    private func contentLength(from response: HTTPURLResponse, offset: Int64) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length"), let length = Int64(value) else { return nil }
        return offset + length
    }

    private func validatePartialResponse(_ response: HTTPURLResponse, expectedStart: Int64, expectedTotal: Int64) throws {
        guard response.statusCode == 206,
              let value = response.value(forHTTPHeaderField: "Content-Range"),
              let match = value.range(of: #"^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"#, options: .regularExpression) else {
            throw BookOrbitAPIError.invalidResponse
        }
        let parts = value[match].split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        guard parts.count == 4,
              let start = Int64(parts[1]), let end = Int64(parts[2]), let total = Int64(parts[3]),
              start == expectedStart, end >= start, expectedTotal == total else {
            throw BookOrbitAPIError.invalidResponse
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
            guard length == end - start + 1 else { throw BookOrbitAPIError.invalidResponse }
        }
    }
}

/// Certificate pinning is opt-in and scoped to the currently configured host.
/// Without a user-confirmed fingerprint URLSession keeps normal system trust;
/// with one, even a self-signed leaf is accepted only when its DER SHA-256
/// fingerprint exactly matches the stored value.
private final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: Data?

    func setFingerprint(_ value: String?) {
        let decoded = value.flatMap(Self.decode)
        lock.lock(); fingerprint = decoded; lock.unlock()
    }

    func fingerprintValue() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let fingerprint else { return nil }
        return fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lock.lock(); let expected = fingerprint; lock.unlock()
        guard let expected else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust), CFArrayGetCount(chain) > 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // SecTrustCopyCertificateChain is documented to contain SecCertificate
        // values; the count guard above makes this access bounded.
        let certificate = (chain as NSArray).object(at: 0) as! SecCertificate
        guard let bytes = SecCertificateCopyData(certificate) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actual = Data(SHA256.hash(data: bytes))
        completionHandler(actual == expected ? .useCredential : .cancelAuthenticationChallenge, actual == expected ? URLCredential(trust: trust) : nil)
    }

    private static func decode(_ value: String) -> Data? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "")
        guard normalized.count == 64, normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        var result = Data(capacity: 32)
        var index = normalized.startIndex
        for _ in 0..<32 {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
}

struct DownloadResult: Sendable {
    let partURL: URL
    let bytesWritten: Int64
    let contentLength: Int64?
}

private struct DownloadSizeError: LocalizedError {
    let expected: Int64
    let actual: Int64
    var errorDescription: String? { "下载长度不匹配：期望 \(expected)，收到 \(actual)" }
}

private struct RemoteFileProgressPayload: Codable, Sendable {
    let percentage: Double
    let cfi: String?
    let pageNumber: Int?
    let positionSeconds: Double?
    let koboLocationSource: String?
    let koboLocationType: String?
    let koboLocationValue: String?
    let koboContentSourceProgressPercent: Double?
    let koreaderProgress: String?

    init(local: FileProgressPayload) {
        percentage = local.percentage; cfi = local.cfi; pageNumber = local.pageNumber; positionSeconds = local.positionSeconds
        koboLocationSource = local.koboLocationSource; koboLocationType = local.koboLocationType; koboLocationValue = local.koboLocationValue
        koboContentSourceProgressPercent = local.koboContentSourceProgressPercent; koreaderProgress = local.koreaderProgress
    }

    var local: FileProgressPayload {
        FileProgressPayload(percentage: percentage, cfi: cfi, pageNumber: pageNumber, positionSeconds: positionSeconds, koboLocationSource: koboLocationSource, koboLocationType: koboLocationType, koboLocationValue: koboLocationValue, koboContentSourceProgressPercent: koboContentSourceProgressPercent, koreaderProgress: koreaderProgress)
    }
}

private struct RemoteAudioProgressPayload: Codable, Sendable {
    let percentage: Double
    let currentFileId: Int64
    let positionSeconds: Double

    init(local: AudioProgressPayload) {
        percentage = local.percentage; currentFileId = local.currentFileId; positionSeconds = local.positionSeconds
    }
}

struct BookOrbitSession: Codable, Equatable, Sendable {
    let serverURL: String
    let username: String
    let version: String
}

private struct AppInfoResponse: Decodable, Sendable {
    let version: String
}

struct BookQueryResponse: Codable, Equatable, Sendable {
    let items: [RemoteBookRecord]
    let total: Int
    let page: Int
    let size: Int
}

struct BookOrbitBookDetail: Decodable, Equatable, Sendable {
    let id: Int64
    let title: String
    let author: String?
    let files: [RemoteFileRecord]

    private enum CodingKeys: String, CodingKey { case id, title, authors, files }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        let decodedTitle = try values.decode(String.self, forKey: .title)
        guard !decodedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: values, debugDescription: "title must not be blank")
        }
        title = decodedTitle
        let records = try values.decode([DetailAuthor].self, forKey: .authors)
        let names = records.map(\.name).filter { !$0.isEmpty }
        author = names.first
        files = try values.decode([RemoteFileRecord].self, forKey: .files)
    }
}

private struct DetailAuthor: Decodable {
    let name: String

    private enum CodingKeys: String, CodingKey { case name }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try values.decode(String.self, forKey: .name)
        guard !decodedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: values, debugDescription: "author name must not be blank")
        }
        name = decodedName
    }
}

struct RemoteFileRecord: Decodable, Equatable, Identifiable, Sendable {
    let id: Int64
    let fileName: String
    let format: String
    let sizeBytes: Int64
    let role: String?
    let durationSeconds: Double?

    private enum CodingKeys: String, CodingKey { case id, format, role, sizeBytes, filename, durationSeconds }

    init(id: Int64, fileName: String, format: String, sizeBytes: Int64, role: String?, durationSeconds: Double?) {
        self.id = id
        self.fileName = fileName
        self.format = format
        self.sizeBytes = sizeBytes
        self.role = role
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        let decodedFormat = try values.decode(String.self, forKey: .format)
        guard !decodedFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: values, debugDescription: "format must not be blank")
        }
        format = decodedFormat
        let decodedFileName = try values.decode(String.self, forKey: .filename)
        guard !decodedFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .filename, in: values, debugDescription: "filename must not be blank")
        }
        fileName = decodedFileName
        sizeBytes = try values.decode(Int64.self, forKey: .sizeBytes)
        guard sizeBytes >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .sizeBytes, in: values, debugDescription: "sizeBytes must not be negative")
        }
        role = try values.decodeIfPresent(String.self, forKey: .role)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        if let durationSeconds, durationSeconds < 0 {
            throw DecodingError.dataCorruptedError(forKey: .durationSeconds, in: values, debugDescription: "durationSeconds must not be negative")
        }
    }
}

struct BookOrbitUser: Codable, Equatable, Sendable {
    let id: Int64?
    let username: String
}

private struct EmptyResponse: Decodable {
    init() {}
}

enum BookOrbitAPIError: LocalizedError {
    case invalidURL
    case httpConfirmationRequired
    case httpConfirmationTargetMismatch
    case httpHostNotAllowed
    case invalidResponse
    case notAuthenticated
    case insufficientStorage
    case httpStatus(Int)
    case unsupportedVersion(String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "BookOrbit 服务器地址无效"
        case .httpConfirmationRequired: return "连接局域网 HTTP 服务器前必须明确确认该主机和端口"
        case .httpConfirmationTargetMismatch: return "局域网 HTTP 确认不能用于 HTTPS 服务器"
        case .httpHostNotAllowed: return "HTTP 仅允许私网 IP 或 .local 主机"
        case .invalidResponse: return "BookOrbit 返回了无效响应"
        case .notAuthenticated: return "尚未连接 BookOrbit"
        case .insufficientStorage: return "设备存储空间不足"
        case .httpStatus(let status): return "BookOrbit 请求失败：HTTP \(status)"
        case .unsupportedVersion(let version): return "暂不支持 BookOrbit 版本：\(version)"
        case .decoding(let error): return "BookOrbit 数据格式错误：\(error.localizedDescription)"
        }
    }
}
