import Foundation
import os

/// Optional decoder boundary for codecs that AVFoundation cannot open. The
/// checked-in target registers a checksum-pinned MobileVLCKit decoder only
/// for local files without request headers; unsupported or authenticated
/// streams remain terminal and observable rather than silently weakening
/// BookOrbit transport.
@MainActor
protocol AudioPlaybackFallback: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }

    func start(
        track: AudioPlaybackService.Track,
        startAt seconds: Double,
        rate: Float,
        onTime: @escaping @MainActor (Double, Double) -> Void,
        onEnded: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    )
    func play(rate: Float)
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// Every fallback assertion is explicit. In particular, a decoder that cannot
/// keep BookOrbit authorization headers on an HTTP Range request is never
/// selected for a remote track.
struct AudioFallbackCapabilities: Sendable, Equatable {
    let supportsAuthenticatedRangeStreams: Bool
    let supportsSeeking: Bool
    let supportsPlaybackRate: Bool

    init(
        supportsAuthenticatedRangeStreams: Bool,
        supportsSeeking: Bool,
        supportsPlaybackRate: Bool
    ) {
        self.supportsAuthenticatedRangeStreams = supportsAuthenticatedRangeStreams
        self.supportsSeeking = supportsSeeking
        self.supportsPlaybackRate = supportsPlaybackRate
    }
}

enum AudioFallbackResolution {
    case decoder(any AudioPlaybackFallback)
    case unavailable(reason: String)
}

/// A process-wide injection point for the reviewed decoder. The adapter
/// receives `Track.headers` and must never move credentials into a URL.
@MainActor
enum AudioFallbackRegistry {
    private struct Registration {
        let provider: String
        let capabilities: AudioFallbackCapabilities
        let make: (AudioPlaybackService.Track) -> (any AudioPlaybackFallback)?
    }

    private static var registration: Registration?

    static func install(
        provider: String,
        capabilities: AudioFallbackCapabilities,
        factory: @escaping (AudioPlaybackService.Track) -> (any AudioPlaybackFallback)?
    ) {
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Audio fallback provider name is required")
        registration = Registration(provider: trimmed, capabilities: capabilities, make: factory)
        AudioPlaybackDiagnostics.record("fallback provider registered: \(trimmed)")
    }

    static func resolve(for track: AudioPlaybackService.Track) -> AudioFallbackResolution {
        guard let registration else {
            return .unavailable(reason: "此构建未打包 LibVLC/MobileVLCKit fallback")
        }
        guard registration.capabilities.supportsSeeking,
              registration.capabilities.supportsPlaybackRate else {
            return .unavailable(reason: "\(registration.provider) 未声明拖动和倍速能力")
        }
        guard track.headers.isEmpty || registration.capabilities.supportsAuthenticatedRangeStreams else {
            return .unavailable(reason: "\(registration.provider) 不支持带认证头的 BookOrbit Range 流")
        }
        guard let decoder = registration.make(track) else {
            return .unavailable(reason: "\(registration.provider) 无法处理当前音频编码")
        }
        return .decoder(decoder)
    }

    static var selfCheck: String {
        guard let registration else {
            return "primary=AVFoundation; libvlcFallback=not-packaged; authenticatedRange=AVFoundation-only"
        }
        return "primary=AVFoundation; fallback=\(registration.provider); authenticatedRange=\(registration.capabilities.supportsAuthenticatedRangeStreams)"
    }
}

/// The log boundary intentionally excludes URLs and request headers, which
/// may otherwise disclose BookOrbit bearer credentials.
@MainActor
enum AudioPlaybackDiagnostics {
    private static let logger = Logger(subsystem: "nz.papria.app", category: "audio")

    static func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func failure(reason: String, systemError: Error?) {
        let code = systemError.map { String((($0 as NSError).code)) } ?? "none"
        logger.error("audio playback stopped; systemCode=\(code, privacy: .public); reason=\(reason, privacy: .public)")
    }
}
