import Foundation
import XCTest
@testable import Papria

final class TransportAndTransferBoundaryTests: XCTestCase {
    func testHTTPSAcceptsOnlyNoConfirmationAndCanonicalSchemes() throws {
        let url = try BookOrbitServerURLPolicy.validate("  HTTPS://Books.Example.test///  ", httpConfirmationTarget: nil)
        XCTAssertEqual(url.scheme?.lowercased(), "https")
        XCTAssertEqual(url.host?.lowercased(), "books.example.test")

        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("https://books.example.test", httpConfirmationTarget: "books.example.test:443"))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("ws://192.168.1.8", httpConfirmationTarget: "192.168.1.8:80"))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("//192.168.1.8", httpConfirmationTarget: "192.168.1.8:80"))
        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("", httpConfirmationTarget: nil))
    }

    func testHTTPConfirmationTargetMaterializesDefaultAndBoundaryPorts() throws {
        XCTAssertEqual(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.8"), "192.168.1.8:80")
        XCTAssertEqual(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.8:1"), "192.168.1.8:1")
        XCTAssertEqual(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.8:65535"), "192.168.1.8:65535")
        XCTAssertEqual(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://[FD00::1]"), "[fd00::1]:80")
        XCTAssertEqual(BookOrbitServerURLPolicy.httpConfirmationTarget(for: " http://Reader.LOCAL.:8080/// "), "reader.local:8080")
        XCTAssertNil(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "https://192.168.1.8"))
        XCTAssertNil(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.8:0"))
        XCTAssertNil(BookOrbitServerURLPolicy.httpConfirmationTarget(for: "http://192.168.1.8:65536"))

        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://192.168.1.8", httpConfirmationTarget: "192.168.1.8:80"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://192.168.1.8:80", httpConfirmationTarget: "192.168.1.8:80"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://Reader.LOCAL.:8080", httpConfirmationTarget: "reader.local:8080"))
    }

    func testHTTPConfirmationIsExactAndPortBound() {
        let url = "http://192.168.1.8:8080"
        for target in [nil, "192.168.1.8", "192.168.1.8:80", "192.168.1.8:8081", "192.168.001.008:8080", " 192.168.1.8:8080 "] as [String?] {
            XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate(url, httpConfirmationTarget: target), String(describing: target))
        }

        XCTAssertThrowsError(try BookOrbitServerURLPolicy.validate("http://READER.local:8080", httpConfirmationTarget: "READER.local:8080"))
        XCTAssertNoThrow(try BookOrbitServerURLPolicy.validate("http://READER.local:8080", httpConfirmationTarget: "reader.local:8080"))
    }

    func testHTTPHostAllowlistBoundariesDoNotIncludeLoopbackOrPublicRanges() {
        let allowed = [
            "10.0.0.0", "10.255.255.255",
            "172.16.0.0", "172.31.255.255",
            "192.168.0.0", "192.168.255.255",
            "169.254.0.0", "169.254.255.255",
            "fd00::", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fe80::1", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "reader.local"
        ]
        let rejected = [
            "9.255.255.255", "11.0.0.0",
            "172.15.255.255", "172.32.0.0",
            "192.167.255.255", "192.169.0.0",
            "169.253.255.255", "169.255.0.0",
            "127.0.0.1", "0.0.0.0", "::1", "::",
            "reader.local.example", ".local", "local", ""
        ]

        for host in allowed {
            XCTAssertTrue(BookOrbitServerURLPolicy.isAllowedHTTPHost(host), host)
        }
        for host in rejected {
            XCTAssertFalse(BookOrbitServerURLPolicy.isAllowedHTTPHost(host), host)
        }
    }

    func testRecoveryOffsetUsesExactEightMiBCheckpoints() {
        let chunk = Int64(8 * 1024 * 1024)
        XCTAssertEqual(localTransferChunkSize, chunk)

        let matrix: [(actual: Int64, total: Int64, expected: Int64?)] = [
            (0, 1, 0),
            (1, chunk * 3, 0),
            (chunk - 1, chunk * 3, 0),
            (chunk, chunk * 3, chunk),
            (chunk + 1, chunk * 3, chunk),
            (chunk * 2 - 1, chunk * 3, chunk),
            (chunk * 2, chunk * 3, chunk * 2),
            (chunk * 2 + 17, chunk * 3, chunk * 2),
            (chunk - 1, chunk - 1, chunk - 1),
            (chunk + 17, chunk + 17, chunk + 17),
            (Int64.max, Int64.max, Int64.max),
            (-1, chunk, nil),
            (chunk + 1, chunk, nil),
            (0, 0, nil),
            (0, -1, nil)
        ]

        for row in matrix {
            XCTAssertEqual(
                localTransferRecoveryOffset(actualSize: row.actual, totalSize: row.total),
                row.expected,
                "actual=\(row.actual), total=\(row.total)"
            )
        }
    }

    func testResumeTokenDigestDistinguishesEmptyUnicodeAndMalformedHashes() {
        let empty = transferResumeTokenHash("")
        let unicode = transferResumeTokenHash("resume-token-cafe")
        let other = transferResumeTokenHash("resume-token-cafE")

        XCTAssertEqual(empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(empty.count, 64)
        XCTAssertEqual(unicode.count, 64)
        XCTAssertNotEqual(unicode, other)
        XCTAssertTrue(transferResumeTokenMatches(empty, ""))
        XCTAssertTrue(transferResumeTokenMatches(unicode, "resume-token-cafe"))
        XCTAssertFalse(transferResumeTokenMatches(unicode, "resume-token-cafE"))
        XCTAssertFalse(transferResumeTokenMatches(String(unicode.dropLast()), "resume-token-cafe"))
        XCTAssertFalse(transferResumeTokenMatches(unicode.uppercased(), "resume-token-cafe"))
    }
}
