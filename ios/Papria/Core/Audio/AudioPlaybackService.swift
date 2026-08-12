@preconcurrency import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// System-framework audiobook player.  AVPlayer supports both local files and
/// HTTP URLs (including BookOrbit's Range endpoint); the service keeps Now
/// Playing and remote-control state in sync and emits a five-second progress
/// callback for the local outbox.
@MainActor
final class AudioPlaybackService: ObservableObject {
    /// Installs a reviewed LibVLC/MobileVLCKit adapter. The caller must make
    /// all transport capabilities explicit; no credential-dropping fallback
    /// is accepted for BookOrbit Range streams.
    static func installAudioFallbackFactory(
        provider: String,
        capabilities: AudioFallbackCapabilities,
        factory: @escaping (Track) -> (any AudioPlaybackFallback)?
    ) {
        AudioFallbackRegistry.install(provider: provider, capabilities: capabilities, factory: factory)
    }

    struct Track: Sendable, Equatable {
        let url: URL
        let title: String
        let fileId: Int64
        let headers: [String: String]
        /// Server-provided duration (when available). AVPlayer may not know
        /// the duration until enough of a remote Range stream has loaded.
        let durationHint: Double?

        init(url: URL, title: String, fileId: Int64, headers: [String: String] = [:], durationHint: Double? = nil) {
            self.url = url
            self.title = title
            self.fileId = fileId
            self.headers = headers
            self.durationHint = durationHint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var currentFileId: Int64 = 0
    @Published private(set) var positionSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var playbackError: String?
    @Published private(set) var trackTitles: [String] = []
    @Published private(set) var currentTrackIndex = 0
    /// Exposed so a reader view can be recreated without restarting the
    /// application-owned player or losing its current track.
    private(set) var hasActiveTrack = false
    @Published private(set) var sleepUntil: Date?
    @Published var rate: Float = 1.0 {
        didSet {
            let normalized = Self.normalizedRate(rate)
            if rate != normalized {
                rate = normalized
                return
            }
            if let fallback, isPlaying { fallback.play(rate: rate) }
            player?.rate = isPlaying ? rate : 0
            updateNowPlaying()
        }
    }

    var onProgress: ((Int64, Double, Double) -> Void)?
    /// Rebuilds an authenticated remote track after AVPlayer fails with the
    /// headers captured when the stream first opened. AppEnvironment supplies
    /// the strict BookOrbit refresh implementation; local tracks leave it
    /// unused.
    var refreshRemoteTrack: (@Sendable (Track) async throws -> Track)?
    private var player: AVPlayer?
    private var fallback: (any AudioPlaybackFallback)?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var sleepTimer: Timer?
    private var fallbackProgressTimer: Timer?
    private var endObserver: NSObjectProtocol?
    private var playbackFailureObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var remoteCommandTargets: [RemoteCommandTarget] = []
    private var wasPlayingBeforeInterruption = false
    private var playlist: [Track] = []
    private var trackIndex = 0
    private var trackDurations: [Double?] = []
    private var durationProbeGeneration = UUID()
    private var remoteRefreshAttempts: Set<Int64> = []
    private var remoteRefreshInFlight: Set<Int64> = []
    /// Invalidates delayed AVPlayer/fallback callbacks when the active track
    /// changes or playback stops.
    private var playbackGeneration = UUID()

    init() {
        AudioPlaybackDiagnostics.record("Audio codec boundary: \(AudioFallbackRegistry.selfCheck)")
        configureRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } == true
            Task { @MainActor in
                guard let self else { return }
                if rawType == AVAudioSession.InterruptionType.began.rawValue {
                    // Only resume a track that was actually playing before the
                    // interruption. AVAudioSession may report `.shouldResume`
                    // even when the user had paused the player beforehand.
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.fallback?.pause()
                    self.player?.pause()
                    self.isPlaying = false
                    self.emitProgress()
                    self.updateNowPlaying()
                } else if rawType == AVAudioSession.InterruptionType.ended.rawValue,
                          shouldResume,
                          self.wasPlayingBeforeInterruption {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        self.wasPlayingBeforeInterruption = false
                        self.playbackError = "系统音频会话恢复失败，请手动继续播放"
                        self.emitProgress()
                        self.updateNowPlaying()
                        return
                    }
                    if let fallback = self.fallback {
                        fallback.play(rate: self.rate)
                    } else {
                        self.player?.playImmediately(atRate: self.rate)
                    }
                    self.isPlaying = true
                    self.updateNowPlaying()
                    self.wasPlayingBeforeInterruption = false
                } else if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                    self.wasPlayingBeforeInterruption = false
                }
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            // A Bluetooth/headset disconnect must not silently continue on the
            // speaker. Persist the exact position and pause until the user
            // explicitly resumes on the new route.
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in
                    guard let self else { return }
                    self.fallback?.pause()
                    self.player?.pause()
                    self.wasPlayingBeforeInterruption = false
                    self.isPlaying = false
                    self.emitProgress()
                    self.updateNowPlaying()
                }
            }
        }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fallback?.stop()
                self.player?.pause()
                self.isPlaying = false
                self.playbackError = "系统音频服务已重置，请重新播放"
                self.emitProgress()
                self.updateNowPlaying()
            }
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.persistCurrentState() }
            })
        }
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        if let mediaServicesResetObserver { NotificationCenter.default.removeObserver(mediaServicesResetObserver) }
        if let playbackFailureObserver { NotificationCenter.default.removeObserver(playbackFailureObserver) }
        if let itemStatusObservation { itemStatusObservation.invalidate() }
        remoteCommandTargets.forEach { $0.command.removeTarget($0.value) }
    }

    func play(url: URL, title: String, fileId: Int64, headers: [String: String] = [:], durationHint: Double? = nil, startAt seconds: Double = 0) {
        play(tracks: [Track(url: url, title: title, fileId: fileId, headers: headers, durationHint: durationHint)], startIndex: 0, startAt: seconds)
    }

    func play(tracks: [Track], startIndex: Int = 0, startAt seconds: Double = 0) {
        stop()
        guard !tracks.isEmpty else { return }
        playbackError = nil
        playlist = tracks
        trackTitles = tracks.map(\.title)
        currentTrackIndex = startIndex.coerced(to: 0...(tracks.count - 1))
        trackDurations = tracks.map(\.durationHint)
        durationProbeGeneration = UUID()
        remoteRefreshAttempts = []
        remoteRefreshInFlight = []
        trackIndex = startIndex.coerced(to: 0...(tracks.count - 1))
        let track = tracks[trackIndex]
        title = track.title
        currentFileId = track.fileId
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* playback can still work in a simulator without audio */ }
        loadCurrent(startAt: seconds)
        probeLocalTrackDurations(generation: durationProbeGeneration)
    }

    func toggle() {
        guard hasActiveTrack, playbackError == nil, player != nil || fallback != nil else { return }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Explicit transport commands are separate from `toggle()` so a lock
    /// screen Play event never pauses an already playing track (and vice
    /// versa). This matters for Bluetooth remotes that issue Play/Pause as
    /// distinct commands.
    func play() {
        guard hasActiveTrack, playbackError == nil, player != nil || fallback != nil else { return }
        if let fallback { fallback.play(rate: rate) }
        else { player?.playImmediately(atRate: rate) }
        isPlaying = true
        emitProgress()
        updateNowPlaying()
    }

    func pause() {
        guard player != nil || fallback != nil else { return }
        fallback?.pause()
        player?.pause()
        isPlaying = false
        emitProgress()
        updateNowPlaying()
    }

    /// Emit a final local snapshot without stopping playback. This is used by
    /// scene backgrounding, interruptions, and reader view teardown.
    func persistCurrentState() {
        guard player != nil || fallback != nil else { return }
        emitProgress()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        if let fallback { fallback.seek(to: clamped) }
        else { player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) }
        positionSeconds = clamped
        emitProgress()
        updateNowPlaying()
    }

    func jump(by seconds: Double) {
        seek(to: positionSeconds + seconds)
    }

    @discardableResult
    func nextTrack() -> Bool {
        guard trackIndex + 1 < playlist.count else { return false }
        emitProgress(); trackIndex += 1; loadCurrent(startAt: 0); return true
    }

    @discardableResult
    func previousTrack() -> Bool {
        guard trackIndex > 0 else { return false }
        emitProgress(); trackIndex -= 1; loadCurrent(startAt: 0); return true
    }

    @discardableResult
    func selectTrack(at index: Int) -> Bool {
        guard playlist.indices.contains(index), index != trackIndex || !hasActiveTrack else { return false }
        emitProgress()
        trackIndex = index
        loadCurrent(startAt: 0)
        return true
    }

    func setSleepTimer(minutes: Int?) {
        let deadline = minutes.flatMap { $0 > 0 ? Date().addingTimeInterval(TimeInterval($0 * 60)) : nil }
        setSleepTimer(until: deadline)
    }

    /// Restores the persisted deadline without rounding it to whole minutes.
    /// An expired deadline is cleared; opening the book remains an explicit
    /// user action and is therefore allowed to start playback normally.
    func setSleepTimer(until deadline: Date?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let deadline, deadline > Date() else { sleepUntil = nil; return }
        sleepUntil = deadline
        let timer = Timer(timeInterval: deadline.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fallback?.pause()
                self?.player?.pause()
                self?.isPlaying = false
                self?.sleepUntil = nil
                self?.emitProgress()
                self?.updateNowPlaying()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    func stop() {
        playbackGeneration = UUID()
        snapshotCurrentTime()
        fallback?.stop()
        fallback = nil
        fallbackProgressTimer?.invalidate()
        fallbackProgressTimer = nil
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let playbackFailureObserver { NotificationCenter.default.removeObserver(playbackFailureObserver) }
        playbackFailureObserver = nil
        player = nil
        emitProgress()
        isPlaying = false
        wasPlayingBeforeInterruption = false
        durationSeconds = 0
        positionSeconds = 0
        currentFileId = 0
        hasActiveTrack = false
        playbackError = nil
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepUntil = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        playlist = []
        trackIndex = 0
        trackTitles = []
        currentTrackIndex = 0
        trackDurations = []
        durationProbeGeneration = UUID()
        remoteRefreshAttempts = []
        remoteRefreshInFlight = []
        refreshRemoteCommandAvailability()
    }

    private func loadCurrent(startAt seconds: Double) {
        guard playlist.indices.contains(trackIndex) else { return }
        let track = playlist[trackIndex]
        let generation = UUID()
        playbackGeneration = generation
        fallback?.stop()
        fallback = nil
        fallbackProgressTimer?.invalidate()
        fallbackProgressTimer = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let playbackFailureObserver { NotificationCenter.default.removeObserver(playbackFailureObserver) }
        playbackFailureObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        let newPlayer: AVPlayer
        if track.headers.isEmpty {
            newPlayer = AVPlayer(url: track.url)
        } else {
            let asset = AVURLAsset(url: track.url, options: ["AVURLAssetHTTPHeaderFieldsKey": track.headers])
            newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        player = newPlayer
        hasActiveTrack = true
        title = track.title
        currentFileId = track.fileId
        currentTrackIndex = trackIndex
        durationSeconds = track.durationHint ?? 0
        positionSeconds = max(0, seconds)
        playbackError = nil
        installTimeObserver(for: newPlayer)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.player === newPlayer else { return }
                if self.nextTrack() == false { self.isPlaying = false; self.emitProgress(); self.updateNowPlaying() }
            }
        }
        playbackFailureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: newPlayer.currentItem, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.player === newPlayer else { return }
                self.handlePlaybackFailure(for: track, startAt: self.positionSeconds, error: error, generation: generation)
            }
        }
        // AVPlayer reports codec/container failures asynchronously. Keep the
        // system path as the fast/default decoder, then offer the optional
        // LibVLC provider only after AVPlayer has actually failed.
        if let item = newPlayer.currentItem {
            itemStatusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.playbackGeneration == generation, self.player === newPlayer else { return }
                    if item.status == .readyToPlay {
                        self.remoteRefreshAttempts.remove(track.fileId)
                    } else if item.status == .failed {
                        self.handlePlaybackFailure(for: track, startAt: self.positionSeconds, error: item.error, generation: generation)
                    }
                }
            }
        }
        if seconds > 0 { newPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        newPlayer.playImmediately(atRate: rate)
        isPlaying = true
        refreshRemoteCommandAvailability()
        updateNowPlaying()
    }

    private func handlePlaybackFailure(for track: Track, startAt seconds: Double, error: Error?, generation: UUID) {
        guard playbackGeneration == generation, currentFileId == track.fileId else { return }
        if remoteRefreshInFlight.contains(track.fileId) { return }
        guard !track.url.isFileURL,
              !track.headers.isEmpty,
              !remoteRefreshAttempts.contains(track.fileId),
              let refreshRemoteTrack else {
            activateFallback(for: track, startAt: seconds, error: error, generation: generation)
            return
        }

        remoteRefreshAttempts.insert(track.fileId)
        remoteRefreshInFlight.insert(track.fileId)
        player?.pause()
        isPlaying = false
        emitProgress()
        updateNowPlaying()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await refreshRemoteTrack(track)
                guard self.playbackGeneration == generation,
                      self.currentFileId == track.fileId,
                      self.playlist.indices.contains(self.trackIndex) else { return }
                self.remoteRefreshInFlight.remove(track.fileId)
                self.playlist[self.trackIndex] = refreshed
                self.loadCurrent(startAt: seconds)
            } catch {
                self.remoteRefreshInFlight.remove(track.fileId)
                self.activateFallback(for: track, startAt: seconds, error: error, generation: generation)
            }
        }
    }

    private func activateFallback(for track: Track, startAt seconds: Double, error: Error?, generation: UUID) {
        guard playbackGeneration == generation, fallback == nil else { return }
        guard player != nil else {
            stopForPlaybackFailure(track: track, reason: "主音频引擎不可用", error: error, generation: generation)
            return
        }
        let decoder: any AudioPlaybackFallback
        switch AudioFallbackRegistry.resolve(for: track) {
        case .decoder(let resolved):
            decoder = resolved
        case .unavailable(let reason):
            stopForPlaybackFailure(track: track, reason: reason, error: error, generation: generation)
            return
        }
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        self.fallback = decoder
        decoder.start(track: track, startAt: seconds, rate: rate, onTime: { [weak self] position, duration in
            guard let self, self.playbackGeneration == generation else { return }
            self.positionSeconds = max(0, position)
            if duration.isFinite, duration > 0 {
                self.durationSeconds = duration
                if self.trackDurations.indices.contains(self.trackIndex) { self.trackDurations[self.trackIndex] = duration }
            }
            self.updateNowPlaying()
        }, onEnded: { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            if self.nextTrack() == false {
                self.fallbackProgressTimer?.invalidate()
                self.fallbackProgressTimer = nil
                self.isPlaying = false
                self.emitProgress()
                self.updateNowPlaying()
            }
        }, onError: { [weak self] error in
            guard let self, self.playbackGeneration == generation else { return }
            self.stopForPlaybackFailure(track: track, reason: "fallback 解码器播放失败", error: error, generation: generation)
        })
        guard playbackGeneration == generation, fallback != nil else { return }
        isPlaying = decoder.isPlaying
        startFallbackProgressTimer(generation: generation)
        durationSeconds = decoder.duration > 0 ? decoder.duration : (track.durationHint ?? 0)
        playbackError = nil
        updateNowPlaying()
        AudioPlaybackDiagnostics.record("AVFoundation decoder failed; fallback decoder started")
    }

    /// Stop the failed engine rather than leaving a silent active track in
    /// Now Playing.  Keep the playlist/current position so the reader may
    /// explicitly select another track or retry after the user remedies it.
    private func stopForPlaybackFailure(track: Track, reason: String, error: Error?, generation: UUID) {
        guard playbackGeneration == generation, currentFileId == track.fileId else { return }
        snapshotCurrentTime()
        playbackGeneration = UUID()
        fallback?.stop()
        fallback = nil
        fallbackProgressTimer?.invalidate()
        fallbackProgressTimer = nil
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let playbackFailureObserver { NotificationCenter.default.removeObserver(playbackFailureObserver) }
        playbackFailureObserver = nil
        player = nil
        hasActiveTrack = false
        isPlaying = false
        wasPlayingBeforeInterruption = false
        playbackError = "音频播放失败：\(reason)"
        AudioPlaybackDiagnostics.failure(reason: reason, systemError: error)
        emitProgress()
        refreshRemoteCommandAvailability()
        updateNowPlaying()
    }

    private func installTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.player === player, self.fallback == nil else { return }
                self.positionSeconds = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                    if self.trackDurations.indices.contains(self.trackIndex) { self.trackDurations[self.trackIndex] = duration }
                }
                self.emitProgress()
                self.updateNowPlaying()
            }
        }
    }

    private func startFallbackProgressTimer(generation: UUID) {
        fallbackProgressTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.fallback != nil, self.isPlaying else { return }
                self.emitProgress()
                self.updateNowPlaying()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackProgressTimer = timer
    }

    private func emitProgress() {
        snapshotCurrentTime()
        let percentage = Self.audiobookPercentage(trackIndex: trackIndex, positionSeconds: positionSeconds, trackDurations: trackDurations)
        onProgress?(currentFileId, positionSeconds, percentage)
    }

    private func snapshotCurrentTime() {
        if let fallback {
            positionSeconds = max(0, fallback.currentTime)
            if fallback.duration.isFinite, fallback.duration > 0 { durationSeconds = fallback.duration }
            return
        }
        guard let player else { return }
        let current = player.currentTime().seconds
        if current.isFinite { positionSeconds = max(0, current) }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            durationSeconds = max(0, duration)
            if duration > 0, trackDurations.indices.contains(trackIndex) { trackDurations[trackIndex] = duration }
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: trackIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playlist.count
        ]
        if durationSeconds > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationSeconds }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteCommandTargets.append(RemoteCommandTarget(command: center.playCommand, value: center.playCommand.addTarget { [weak self] _ in
            guard self?.hasActiveTrack == true else { return .noSuchContent }
            self?.play(); return .success
        }))
        remoteCommandTargets.append(RemoteCommandTarget(command: center.pauseCommand, value: center.pauseCommand.addTarget { [weak self] _ in
            guard self?.hasActiveTrack == true else { return .noSuchContent }
            self?.pause(); return .success
        }))
        remoteCommandTargets.append(RemoteCommandTarget(command: center.togglePlayPauseCommand, value: center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self?.hasActiveTrack == true else { return .noSuchContent }
            self?.toggle(); return .success
        }))
        center.skipForwardCommand.preferredIntervals = [15]
        remoteCommandTargets.append(RemoteCommandTarget(command: center.skipForwardCommand, value: center.skipForwardCommand.addTarget { [weak self] _ in
            guard self?.hasActiveTrack == true else { return .noSuchContent }
            self?.jump(by: 15); return .success
        }))
        center.skipBackwardCommand.preferredIntervals = [15]
        remoteCommandTargets.append(RemoteCommandTarget(command: center.skipBackwardCommand, value: center.skipBackwardCommand.addTarget { [weak self] _ in
            guard self?.hasActiveTrack == true else { return .noSuchContent }
            self?.jump(by: -15); return .success
        }))
        remoteCommandTargets.append(RemoteCommandTarget(command: center.nextTrackCommand, value: center.nextTrackCommand.addTarget { [weak self] _ in self?.nextTrack() == true ? .success : .noSuchContent }))
        remoteCommandTargets.append(RemoteCommandTarget(command: center.previousTrackCommand, value: center.previousTrackCommand.addTarget { [weak self] _ in self?.previousTrack() == true ? .success : .noSuchContent }))
        remoteCommandTargets.append(RemoteCommandTarget(command: center.changePlaybackPositionCommand, value: center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard self?.hasActiveTrack == true,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }))
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        remoteCommandTargets.append(RemoteCommandTarget(command: center.changePlaybackRateCommand, value: center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard self?.hasActiveTrack == true,
                  let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.rate = event.playbackRate
            return .success
        }))
        refreshRemoteCommandAvailability()
    }

    private func refreshRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let active = hasActiveTrack
        center.playCommand.isEnabled = active
        center.pauseCommand.isEnabled = active
        center.togglePlayPauseCommand.isEnabled = active
        center.skipForwardCommand.isEnabled = active
        center.skipBackwardCommand.isEnabled = active
        center.changePlaybackPositionCommand.isEnabled = active
        center.changePlaybackRateCommand.isEnabled = active
        center.nextTrackCommand.isEnabled = active && trackIndex + 1 < playlist.count
        center.previousTrackCommand.isEnabled = active && trackIndex > 0
    }

    private func probeLocalTrackDurations(generation: UUID) {
        for (index, track) in playlist.enumerated() where trackDurations[index] == nil && track.url.isFileURL {
            let url = track.url
            Task { [weak self] in
                let asset = AVURLAsset(url: url)
                guard let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 else { return }
                guard let self, self.durationProbeGeneration == generation, self.trackDurations.indices.contains(index) else { return }
                self.trackDurations[index] = time.seconds
            }
        }
    }

    static func normalizedRate(_ candidate: Float) -> Float {
        guard candidate.isFinite else { return 1 }
        return min(3, max(0.5, candidate))
    }

    static func audiobookPercentage(trackIndex: Int, positionSeconds: Double, trackDurations: [Double?]) -> Double {
        guard trackDurations.indices.contains(trackIndex) else { return 0 }
        let safePosition = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        let validDurations = trackDurations.compactMap { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        if validDurations.count == trackDurations.count {
            let total = validDurations.reduce(0, +)
            let completed = validDurations.prefix(trackIndex).reduce(0, +)
            return min(100, max(0, (completed + min(safePosition, validDurations[trackIndex])) / total * 100))
        }
        let currentDuration = trackDurations[trackIndex].flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let withinTrack = currentDuration.map { min(1, safePosition / $0) } ?? 0
        return min(100, max(0, (Double(trackIndex) + withinTrack) / Double(trackDurations.count) * 100))
    }
}

private final class RemoteCommandTarget: @unchecked Sendable {
    let command: MPRemoteCommand
    let value: Any
    init(command: MPRemoteCommand, value: Any) {
        self.command = command
        self.value = value
    }
}

private extension Comparable {
    func coerced(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
