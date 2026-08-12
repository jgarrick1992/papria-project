import Foundation
import XCTest
@testable import Papria

final class BookOrbitCodableBoundaryTests: XCTestCase {
    func testQueryAcceptsExactEmptyAndPopulatedShapes() throws {
        let empty = try decodeQuery(#"{"items":[],"total":0,"page":0,"size":0}"#)
        XCTAssertEqual(empty.items, [])
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.page, 0)
        XCTAssertEqual(empty.size, 0)

        let populated = try decodeQuery(#"{"items":[{"id":9223372036854775807,"title":"Book","authors":[],"files":[{"id":0,"format":"epub","role":null,"sizeBytes":0}]}],"total":1,"page":2147483647,"size":1}"#)
        XCTAssertEqual(populated.items.first?.id, Int64.max)
        XCTAssertNil(populated.items.first?.author)
        XCTAssertEqual(populated.page, Int(Int32.max))
    }

    func testQueryIgnoresExtensionFieldsAtEveryObjectLevel() {
        let payloads = [
            #"{"items":[],"total":0,"page":0,"size":20,"unknown":true}"#,
            #"{"items":[{"id":1,"title":"Book","authors":[],"files":[],"unknown":true}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":"Book","authors":[],"files":[{"id":2,"format":"epub","role":null,"sizeBytes":0,"unknown":true}]}],"total":1,"page":0,"size":20}"#
        ]

        for payload in payloads {
            XCTAssertNoThrow(try decodeQuery(payload), payload)
        }
    }

    func testQueryRejectsMissingRequiredFieldsAtEveryObjectLevel() {
        let payloads = [
            #"{"total":0,"page":0,"size":20}"#,
            #"{"items":[],"page":0,"size":20}"#,
            #"{"items":[],"total":0,"size":20}"#,
            #"{"items":[],"total":0,"page":0}"#,
            #"{"items":[{"title":"Book","authors":[],"files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"authors":[],"files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":"Book","files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":"Book","files":[]}],"total":1,"page":0,"size":20}"#
        ]

        for payload in payloads {
            XCTAssertThrowsError(try decodeQuery(payload), payload)
        }
    }

    func testQueryRejectsNullRequiredFieldsAndInvalidEmptyValues() {
        let payloads = [
            #"{"items":null,"total":0,"page":0,"size":20}"#,
            #"{"items":[],"total":null,"page":0,"size":20}"#,
            #"{"items":[{"id":null,"title":"Book","authors":[],"files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":null,"authors":[],"files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":" \n\t ","authors":[],"files":[]}],"total":1,"page":0,"size":20}"#,
            #"{"items":[{"id":1,"title":"Book","authors":null,"files":[]}],"total":1,"page":0,"size":20}"#
        ]

        for payload in payloads {
            XCTAssertThrowsError(try decodeQuery(payload), payload)
        }
    }

    func testDetailAcceptsOnlyCanonicalAuthorAndFileFields() throws {
        let detail = try decodeDetail(#"{"id":1,"title":"Book","authors":[{"name":"Author"}],"files":[{"id":2,"format":"pdf","role":null,"sizeBytes":0,"absolutePath":"/srv/book.pdf","createdAt":"2026-08-11T00:00:00Z","filename":"book.pdf","durationSeconds":null}]}"#)

        XCTAssertEqual(detail.author, "Author")
        XCTAssertEqual(detail.files.first?.fileName, "book.pdf")
        XCTAssertEqual(detail.files.first?.sizeBytes, 0)
        XCTAssertNil(detail.files.first?.role)
        XCTAssertNil(detail.files.first?.durationSeconds)
    }

    func testDetailIgnoresExtensionFieldsAtEveryObjectLevel() {
        let payloads = [
            #"{"id":1,"title":"Book","authors":[],"files":[],"unknown":true}"#,
            #"{"id":1,"title":"Book","authors":[{"name":"Author","id":9}],"files":[]}"#,
            #"{"id":1,"title":"Book","authors":[],"files":[{"id":2,"format":"epub","sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub","checksum":"legacy"}]}"#
        ]

        for payload in payloads {
            XCTAssertNoThrow(try decodeDetail(payload), payload)
        }
    }

    func testDetailRejectsMissingRequiredFieldsMatrix() {
        let payloads = [
            #"{"title":"Book","authors":[],"files":[]}"#,
            #"{"id":1,"authors":[],"files":[]}"#,
            #"{"id":1,"title":"Book","files":[]}"#,
            #"{"id":1,"title":"Book","authors":[]}"#,
            #"{"id":1,"title":"Book","authors":[{}],"files":[]}"#,
            detailWithFile(#"{"format":"epub","sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"format":"epub","absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now"}"#)
        ]

        for payload in payloads {
            XCTAssertThrowsError(try decodeDetail(payload), payload)
        }
    }

    func testDetailRejectsNullRequiredFieldsMatrix() {
        let payloads = [
            #"{"id":null,"title":"Book","authors":[],"files":[]}"#,
            #"{"id":1,"title":null,"authors":[],"files":[]}"#,
            #"{"id":1,"title":"Book","authors":null,"files":[]}"#,
            #"{"id":1,"title":"Book","authors":[{"name":null}],"files":[]}"#,
            #"{"id":1,"title":"Book","authors":[],"files":null}"#,
            detailWithFile(#"{"id":null,"format":"epub","sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"format":null,"sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":null,"absolutePath":"/book.epub","createdAt":"now","filename":"book.epub"}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":1,"absolutePath":"/book.epub","createdAt":"now","filename":null}"#)
        ]

        for payload in payloads {
            XCTAssertThrowsError(try decodeDetail(payload), payload)
        }
    }

    func testDetailEmptyAndNumericBoundaries() throws {
        for payload in [
            #"{"id":1,"title":"","authors":[],"files":[]}"#,
            #"{"id":1,"title":"Book","authors":[{"name":" \n "}],"files":[]}"#,
            detailWithFile(#"{"id":2,"format":"","sizeBytes":1,"absolutePath":"/book","createdAt":"now","filename":"book"}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":1,"absolutePath":"/book","createdAt":"now","filename":" \t "}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":-1,"absolutePath":"/book","createdAt":"now","filename":"book"}"#),
            detailWithFile(#"{"id":2,"format":"epub","sizeBytes":1,"absolutePath":"/book","createdAt":"now","filename":"book","durationSeconds":-0.001}"#)
        ] {
            XCTAssertThrowsError(try decodeDetail(payload), payload)
        }

        let maximum = try decodeDetail(detailWithFile(#"{"id":9223372036854775807,"format":"m4b","role":"primary","sizeBytes":9223372036854775807,"absolutePath":"","createdAt":"","filename":"book.m4b","durationSeconds":0}"#))
        XCTAssertEqual(maximum.files.first?.id, Int64.max)
        XCTAssertEqual(maximum.files.first?.sizeBytes, Int64.max)
        XCTAssertEqual(maximum.files.first?.durationSeconds, 0)
    }

    func testRequestEncodingUsesOnlyCanonicalKeys() throws {
        let request = BookQueryRequest(
            sort: [BookSort(field: "updatedAt", dir: "desc")],
            pagination: Pagination(page: 0, size: 100),
            collapseSeries: false,
            q: nil
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sort", "pagination", "collapseSeries"])

        let sort = try XCTUnwrap((object["sort"] as? [[String: String]])?.first)
        XCTAssertEqual(sort, ["field": "updatedAt", "dir": "desc"])
        let pagination = try XCTUnwrap(object["pagination"] as? [String: Int])
        XCTAssertEqual(pagination, ["page": 0, "size": 100])
    }

    func testProgressEncodingDoesNotAddAliasesOrNullPlaceholders() throws {
        let file = FileProgressPayload(percentage: 0)
        let fileObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        XCTAssertEqual(Set(fileObject.keys), ["percentage", "dirty"])
        XCTAssertEqual(fileObject["dirty"] as? Bool, false)

        let audio = AudioProgressPayload(percentage: 100, currentFileId: Int64.max, positionSeconds: 0)
        let audioObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(audio)) as? [String: Any])
        XCTAssertEqual(Set(audioObject.keys), ["percentage", "currentFileId", "positionSeconds", "dirty"])
        XCTAssertNil(audioObject["fileId"])
    }

    func testAuthResponsesIgnoreExtensionsAndRejectWrongTypeBoundaries() throws {
        let extended = try JSONDecoder().decode(
            LoginResponse.self,
            from: Data(#"{"accessToken":"token","tokenType":"Bearer"}"#.utf8)
        )
        XCTAssertEqual(extended.accessToken, "token")

        for payload in [
            #"{"accessToken":0}"#,
            #"{"accessToken":[]}"#,
            #"{"accessToken":"\n\t"}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(LoginResponse.self, from: Data(payload.utf8)), payload)
        }
    }

    private func decodeQuery(_ payload: String) throws -> BookQueryResponse {
        try JSONDecoder().decode(BookQueryResponse.self, from: Data(payload.utf8))
    }

    private func decodeDetail(_ payload: String) throws -> BookOrbitBookDetail {
        try JSONDecoder().decode(BookOrbitBookDetail.self, from: Data(payload.utf8))
    }

    private func detailWithFile(_ file: String) -> String {
        #"{"id":1,"title":"Book","authors":[],"files":["# + file + "]}"
    }
}
