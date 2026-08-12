import Foundation
import MobileVLCKit

/// Local-file-only LibVLC fallback for codecs AVFoundation cannot decode.
///
/// MobileVLCKit is not given BookOrbit Authorization headers and is never
/// selected for an authenticated or redirect-sensitive remote URL. This
/// keeps AVFoundation as the only authenticated Range transport.
@MainActor
final class MobileVLCAudioFallback: NSObject, AudioPlaybackFallback, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private var onTime: (@MainActor (Double, Double) -> Void)?
    private var onEnded: (@MainActor () -> Void)?
    private var onError: (@MainActor (Error) -> Void)?

    var isPlaying: Bool { player.isPlaying }
    var currentTime: Double { max(0, Double(player.time.intValue) / 1000) }
    var duration: Double { max(0, Double(player.media?.length.intValue ?? 0) / 1000) }

    override init() {
        super.init()
        player.delegate = self
    }

    func start(
        track: AudioPlaybackService.Track,
        startAt seconds: Double,
        rate: Float,
        onTime: @escaping @MainActor (Double, Double) -> Void,
        onEnded: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard track.url.isFileURL, track.headers.isEmpty else {
            onError(MobileVLCAudioFallbackError.remoteCredentialsNotSupported)
            return
        }
        self.onTime = onTime
        self.onEnded = onEnded
        self.onError = onError
        player.media = VLCMedia(url: track.url)
        player.rate = rate
        player.play()
        if seconds > 0 { player.time = VLCTime(int: Int32(seconds * 1000)) }
    }

    func play(rate: Float) {
        player.rate = rate
        player.play()
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func stop() {
        player.stop()
        onTime = nil
        onEnded = nil
        onError = nil
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onTime?(self.currentTime, self.duration)
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.player.state == .ended {
                self.onEnded?()
            } else if self.player.state == .error {
                self.onError?(MobileVLCAudioFallbackError.decoderFailed)
            }
        }
    }
}

enum MobileVLCAudioFallbackError: LocalizedError {
    case remoteCredentialsNotSupported
    case decoderFailed

    var errorDescription: String? {
        switch self {
        case .remoteCredentialsNotSupported:
            return "MobileVLCKit fallback 仅支持本地无认证文件"
        case .decoderFailed:
            return "MobileVLCKit 无法解码当前音频"
        }
    }
}
