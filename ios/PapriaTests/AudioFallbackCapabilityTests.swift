import Foundation
import XCTest
@testable import Papria

@MainActor
final class AudioFallbackCapabilityTests: XCTestCase {
    func testFallbackRequiresSeekingAndPlaybackRateBeforeFactoryRuns() {
        let decoder = AudioFallbackStub()
        var factoryCalls = 0
        let track = AudioPlaybackService.Track(
            url: URL(fileURLWithPath: "/tmp/book.ogg"),
            title: "Book",
            fileId: 1
        )

        AudioFallbackRegistry.install(
            provider: "No Seek",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: false,
                supportsPlaybackRate: true
            )
        ) { _ in
            factoryCalls += 1
            return decoder
        }
        assertUnavailable(AudioFallbackRegistry.resolve(for: track), contains: "未声明")
        XCTAssertEqual(factoryCalls, 0)

        AudioFallbackRegistry.install(
            provider: "No Rate",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: true,
                supportsPlaybackRate: false
            )
        ) { _ in
            factoryCalls += 1
            return decoder
        }
        assertUnavailable(AudioFallbackRegistry.resolve(for: track), contains: "未声明")
        XCTAssertEqual(factoryCalls, 0)
    }

    func testAuthenticatedRangeTrackIsRejectedBeforeCredentialBlindFactoryRuns() {
        let decoder = AudioFallbackStub()
        var factoryCalls = 0
        let authorization = "Bearer secret-access-token"
        let track = AudioPlaybackService.Track(
            url: URL(string: "https://books.example.test/api/files/9")!,
            title: "Remote",
            fileId: 9,
            headers: ["Authorization": authorization]
        )

        AudioFallbackRegistry.install(
            provider: "Local Decoder",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: true,
                supportsPlaybackRate: true
            )
        ) { _ in
            factoryCalls += 1
            return decoder
        }

        let reason = unavailableReason(AudioFallbackRegistry.resolve(for: track))
        XCTAssertNotNil(reason)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertFalse(reason?.contains(authorization) == true)
        XCTAssertFalse(reason?.contains("secret-access-token") == true)
        XCTAssertTrue(reason?.contains("Range") == true)
        XCTAssertFalse(AudioFallbackRegistry.selfCheck.contains("secret-access-token"))
    }

    func testLocalHeaderlessTrackCanResolveReviewedDecoder() {
        let decoder = AudioFallbackStub()
        let track = AudioPlaybackService.Track(
            url: URL(fileURLWithPath: "/tmp/book.flac"),
            title: "Local",
            fileId: Int64.max,
            headers: [:]
        )

        AudioFallbackRegistry.install(
            provider: " Reviewed Decoder ",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: true,
                supportsPlaybackRate: true
            )
        ) { candidate in
            XCTAssertEqual(candidate, track)
            return decoder
        }

        switch AudioFallbackRegistry.resolve(for: track) {
        case .decoder(let resolved):
            XCTAssertTrue((resolved as AnyObject) === decoder)
        case .unavailable(let reason):
            XCTFail("Expected decoder, got: \(reason)")
        }
        XCTAssertTrue(AudioFallbackRegistry.selfCheck.contains("Reviewed Decoder"))
        XCTAssertTrue(AudioFallbackRegistry.selfCheck.contains("authenticatedRange=false"))
    }

    func testFactoryRefusalRemainsTerminalAndObservable() {
        let track = AudioPlaybackService.Track(
            url: URL(fileURLWithPath: "/tmp/book.unsupported"),
            title: "Unsupported",
            fileId: 2
        )
        AudioFallbackRegistry.install(
            provider: "Format Gate",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: false,
                supportsSeeking: true,
                supportsPlaybackRate: true
            )
        ) { _ in nil }

        assertUnavailable(AudioFallbackRegistry.resolve(for: track), contains: "无法处理")
    }

    func testAuthenticatedRangeCapabilityMustStillBeBackedByFactory() {
        let decoder = AudioFallbackStub()
        let track = AudioPlaybackService.Track(
            url: URL(string: "https://books.example.test/range")!,
            title: "Remote",
            fileId: 3,
            headers: ["Authorization": "Bearer token"]
        )
        AudioFallbackRegistry.install(
            provider: "Range Decoder",
            capabilities: AudioFallbackCapabilities(
                supportsAuthenticatedRangeStreams: true,
                supportsSeeking: true,
                supportsPlaybackRate: true
            )
        ) { candidate in
            XCTAssertEqual(candidate.headers, track.headers)
            return decoder
        }

        switch AudioFallbackRegistry.resolve(for: track) {
        case .decoder(let resolved):
            XCTAssertTrue((resolved as AnyObject) === decoder)
        case .unavailable(let reason):
            XCTFail("Expected authenticated decoder, got: \(reason)")
        }
    }

    private func assertUnavailable(
        _ resolution: AudioFallbackResolution,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reason = unavailableReason(resolution)
        XCTAssertNotNil(reason, file: file, line: line)
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains(expected) == true, "reason=\(reason ?? "nil")", file: file, line: line)
    }

    private func unavailableReason(_ resolution: AudioFallbackResolution) -> String? {
        guard case .unavailable(let reason) = resolution else { return nil }
        return reason
    }
}

@MainActor
private final class AudioFallbackStub: AudioPlaybackFallback {
    private(set) var isPlaying = false
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0

    func start(
        track: AudioPlaybackService.Track,
        startAt seconds: Double,
        rate: Float,
        onTime: @escaping @MainActor (Double, Double) -> Void,
        onEnded: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        currentTime = seconds
        isPlaying = true
    }

    func play(rate: Float) { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}
