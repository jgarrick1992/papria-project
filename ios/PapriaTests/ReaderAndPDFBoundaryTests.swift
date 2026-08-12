import Foundation
import XCTest
@testable import Papria

final class ReaderAndPDFBoundaryTests: XCTestCase {
    func testCFIMakeClampsNegativeInputsAndFiltersInvalidPathSteps() throws {
        let value = EpubCFILocator.make(
            spineIndex: -9,
            idref: "chapter[]^,;=!",
            contentPath: [0, -1],
            textOffset: -3
        )
        XCTAssertEqual(value, "epubcfi(/6/4[chapter^[^]^^^,^;^=^!]!/4/2/1:0)")

        let parsed = try XCTUnwrap(EpubCFILocator.parse(value))
        XCTAssertEqual(parsed.spineIndex, 0)
        XCTAssertEqual(parsed.idref, "chapter[]^,;=!")
        XCTAssertEqual(parsed.contentPath, [4, 2, 1])
        XCTAssertEqual(parsed.textOffset, 0)
    }

    func testCFIParseAcceptsPointBiasAndRejectsMalformedMatrix() throws {
        let before = try XCTUnwrap(EpubCFILocator.parse("epubcfi(/6/4[chapter]!/4/2/1:7;s=b)"))
        XCTAssertEqual(before.textOffset, 7)
        let after = try XCTUnwrap(EpubCFILocator.parse("epubcfi(/6/6!/4/2:0;s=a)"))
        XCTAssertEqual(after.spineIndex, 1)

        let invalid = [
            "",
            "epubcfi()",
            "epubcfi(/6/4)",
            "epubcfi(/6/4!!/4/2:0)",
            "epubcfi(/4/4!/4/2:0)",
            "epubcfi(/6/3!/4/2:0)",
            "epubcfi(/6/2!/4/2:0)",
            "epubcfi(/6/4!/:0)",
            "epubcfi(/6/4!/4/0:0)",
            "epubcfi(/6/4!/4/2:-1)",
            "epubcfi(/6/4!/4/2:1;s=x)",
            "epubcfi(/6/4!/4/2:1,3)",
            "epubcfi(/6/4[unterminated!/4/2:0)",
            "epubcfi(/6/4[bad[nest]]!/4/2:0)",
            "epubcfi(/6/4!/4/2:999999999999999999999999999999999999)"
        ]

        for value in invalid {
            XCTAssertNil(EpubCFILocator.parse(value), value)
        }
    }

    func testContentIndexClampsDisplayOffsetsAndRejectsInvalidDOMOffsets() throws {
        let markup = "<html><head><title>Ignored</title><style>.x{}</style></head><body><p id=\"first\">A😀B</p><script>ignored()</script><p id=\"last\">C &amp; D</p></body></html>"
        let index = EpubContentCFIIndex(markup: markup)

        XCTAssertFalse(index.text.contains("Ignored"))
        XCTAssertFalse(index.text.contains("ignored()"))
        XCTAssertTrue(index.text.contains("A😀B"))
        XCTAssertTrue(index.text.contains("C & D"))
        XCTAssertNotNil(index.anchors["first"])
        XCTAssertNotNil(index.anchors["last"])

        let start = try XCTUnwrap(index.location(forDisplayOffset: -1))
        XCTAssertEqual(index.displayOffset(forPath: start.path, utf16Offset: start.utf16Offset), 0)

        let end = try XCTUnwrap(index.location(forDisplayOffset: Int.max))
        XCTAssertEqual(index.displayOffset(forPath: end.path, utf16Offset: end.utf16Offset), index.text.count)
        XCTAssertNil(index.displayOffset(forPath: end.path, utf16Offset: -1))
        XCTAssertNil(index.displayOffset(forPath: [999, 999], utf16Offset: 0))
    }

    func testContentIndexReturnsNoLocationForEmptyOrSuppressedMarkup() {
        for markup in ["", "   \n\t", "<html><head><title>Only title</title></head><body><script>x</script></body></html>"] {
            let index = EpubContentCFIIndex(markup: markup)
            XCTAssertTrue(index.text.isEmpty)
            XCTAssertNil(index.location(forDisplayOffset: 0))
        }
    }

    func testPDFPreferencesDefaultForMissingCorruptAndUnknownZoomModes() {
        let keys = (0..<3).map { "pdf-boundary-\($0)-\(UUID().uuidString)" }
        defer {
            for key in keys {
                UserDefaults.standard.removeObject(forKey: PDFReaderPreferences.key(key))
            }
        }
        let expected = PDFReaderPreferences(
            zoomMode: .fitPage,
            zoomScale: 1,
            rotation: 0,
            continuous: true,
            horizontal: false
        )

        XCTAssertEqual(PDFReaderPreferences.load(storageKey: keys[0]), expected)

        UserDefaults.standard.set(Data("not-json".utf8), forKey: PDFReaderPreferences.key(keys[1]))
        XCTAssertEqual(PDFReaderPreferences.load(storageKey: keys[1]), expected)

        let unknown = Data(#"{"zoomMode":"legacyFit","zoomScale":1,"rotation":0,"continuous":true,"horizontal":false}"#.utf8)
        UserDefaults.standard.set(unknown, forKey: PDFReaderPreferences.key(keys[2]))
        XCTAssertEqual(PDFReaderPreferences.load(storageKey: keys[2]), expected)
    }

    func testPDFPreferencesRoundTripEveryZoomModeAndOrientationBoundary() {
        let cases = [
            PDFReaderPreferences(zoomMode: .fitPage, zoomScale: 0.01, rotation: -270, continuous: false, horizontal: false),
            PDFReaderPreferences(zoomMode: .fitWidth, zoomScale: 1, rotation: 0, continuous: true, horizontal: true),
            PDFReaderPreferences(zoomMode: .manual, zoomScale: 32, rotation: 720, continuous: false, horizontal: true)
        ]
        let keys = cases.indices.map { "pdf-roundtrip-\($0)-\(UUID().uuidString)" }
        defer {
            for key in keys {
                UserDefaults.standard.removeObject(forKey: PDFReaderPreferences.key(key))
            }
        }

        for (index, value) in cases.enumerated() {
            value.save(storageKey: keys[index])
            XCTAssertEqual(PDFReaderPreferences.load(storageKey: keys[index]), value)
        }
    }

    func testFileProgressDifferenceThresholdIncludesReadingLocationFields() {
        let baseline = FileProgressPayload(percentage: 0, cfi: nil, pageNumber: nil, positionSeconds: nil)
        XCTAssertFalse(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0.1)))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0.1001)))
        XCTAssertFalse(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, positionSeconds: 1)))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, positionSeconds: 1.001)))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, cfi: "epubcfi(/6/4!/4/2:0)")))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, pageNumber: 1)))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, koboLocationValue: "42")))
        XCTAssertTrue(ProgressSyncService.fileProgressDiffers(baseline, FileProgressPayload(percentage: 0, koreaderProgress: "0.5")))
    }

    func testAudioProgressDifferenceThresholdsAndMissingRemote() {
        let baseline = AudioProgressPayload(percentage: 0, currentFileId: 7, positionSeconds: 0)
        XCTAssertFalse(ProgressSyncService.audioProgressDiffers(baseline, AudioProgressPayload(percentage: 0.1, currentFileId: 7, positionSeconds: 1)))
        XCTAssertTrue(ProgressSyncService.audioProgressDiffers(baseline, AudioProgressPayload(percentage: 0.1001, currentFileId: 7, positionSeconds: 0)))
        XCTAssertTrue(ProgressSyncService.audioProgressDiffers(baseline, AudioProgressPayload(percentage: 0, currentFileId: 8, positionSeconds: 0)))
        XCTAssertTrue(ProgressSyncService.audioProgressDiffers(baseline, AudioProgressPayload(percentage: 0, currentFileId: 7, positionSeconds: 1.001)))
        XCTAssertTrue(ProgressSyncService.audioProgressDiffers(baseline, nil))
    }
}
