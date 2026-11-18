import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Background music & audiobook playback with a queue, lock-screen controls and server progress reporting.
@MainActor @Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    private(set) var queue: [BaseItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    var showNowPlaying = false

    var current: BaseItem? { queue.indices.contains(index) ? queue[index] : nil }
    var isAudiobook: Bool { current?.isAudiobook == true }
    var hasNext: Bool { index + 1 < queue.count }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var commandsInstalled = false

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                await self.report(stopped: true)
                if self.hasNext { self.index += 1; self.loadCurrent(startAt: 0) } else { self.isPlaying = false }
            }
        }
    }

    // MARK: Control

    func play(_ items: [BaseItem], startAt start: Int = 0, shuffle: Bool = false, client: JellyfinClient?) {
        guard !items.isEmpty else { return }
        if let client { self.client = client }
        var list = items.filter(\.isAudio)
        guard !list.isEmpty else { return }
        var startIndex = min(max(0, start), list.count - 1)
        if shuffle {
            list.shuffle()
            startIndex = 0
        }
        if current != nil { Task { await report(stopped: true) } }
        queue = list
        index = startIndex
        installCommands()
        try? AVAudioSession.sharedInstance().setActive(true)
        let resume = list[startIndex].isAudiobook ? list[startIndex].resumeTicks : 0
        loadCurrent(startAt: Double(resume) / 10_000_000)
    }

    func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: rate) } else { player.pause() }
        tick()
        Task { await report() }
    }

    func pause() {
        player.pause()
        tick()
    }

    func next() {
        guard hasNext else { return }
        Task { await report(stopped: true) }
        index += 1
        loadCurrent(startAt: 0)
    }

    func previous() {
        if currentTime > 4 || index == 0 { seek(to: 0); return }
        Task { await report(stopped: true) }
        index -= 1
        loadCurrent(startAt: 0)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        Task { await report(stopped: true) }
        index = i
        loadCurrent(startAt: 0)
    }

    func skip(by seconds: Double) { seek(to: max(0, min(duration, currentTime + seconds))) }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
        updateNowPlaying()
    }

    func stop() {
        guard current != nil else { return }
        Task { await report(stopped: true) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        isPlaying = false
        showNowPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        removeCommands()
    }

    // MARK: Internals

    private func loadCurrent(startAt seconds: Double) {
        guard let item = current else { return }
        let asset: AVURLAsset
        if let local = DownloadManager.shared.localFile(for: item.id) {
            asset = AVURLAsset(url: local)                       // downloaded: plays offline
        } else if let client {
            asset = AVURLAsset(url: client.audioURL(itemId: item.id), options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader],
            ])
        } else {
            return
        }
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = .timeDomain   // natural voice at 1.5×/2×
        player.replaceCurrentItem(with: playerItem)
        if seconds > 1 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        currentTime = seconds
        duration = item.runTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        player.playImmediately(atRate: rate)
        artwork = nil
        if commandsInstalled { refreshCommandAvailability() }
        loadArtwork(for: item)
        Task { await report(started: true) }
        tick()
    }

    private func tick() {
        let t = player.currentTime().seconds
        if t.isFinite { currentTime = t }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        updateNowPlaying()
        if Date().timeIntervalSince(lastReport) > 10, isPlaying { Task { await report() } }
    }

    private func report(started: Bool = false, stopped: Bool = false) async {
        guard let client, let item = current else { return }
        lastReport = Date()
        let body: [String: Any] = [
            "ItemId": item.id,
            "PositionTicks": Int64(max(0, currentTime) * 10_000_000),
            "IsPaused": !isPlaying,
            "PlayMethod": "DirectStream",
            "CanSeek": true,
        ]
        let path = started ? "Sessions/Playing" : (stopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress")
        await client.reportPlayback(path, body: body)
    }

    private func loadArtwork(for item: BaseItem) {
        let offlineArt = DownloadManager.shared.records[item.id]?.posterURL
        let url = offlineArt ?? client?.albumArtURL(for: item, width: 800)
        guard let url else { return }
        Task {
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0), current?.id == item.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name ?? "Unknown",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = item.artistLine { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installCommands() {
        let c = MPRemoteCommandCenter.shared()
        removeCommands()
        c.playCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.togglePlay() }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.previous() }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.skip(by: 30) }; return .success }
        c.skipBackwardCommand.addTarget { _ in Task { @MainActor in AudioPlayer.shared.skip(by: -15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                let pos = e.positionTime
                Task { @MainActor in AudioPlayer.shared.seek(to: pos) }
            }
            return .success
        }
        commandsInstalled = true
        refreshCommandAvailability()
    }

    private func refreshCommandAvailability() {
        let c = MPRemoteCommandCenter.shared()
        // Audiobooks get ±seconds on the lock screen; music gets next/previous track.
        c.skipForwardCommand.isEnabled = isAudiobook
        c.skipBackwardCommand.isEnabled = isAudiobook
        c.nextTrackCommand.isEnabled = !isAudiobook
        c.previousTrackCommand.isEnabled = !isAudiobook
    }

    private func removeCommands() {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand,
                    c.skipForwardCommand, c.skipBackwardCommand, c.changePlaybackPositionCommand] as [MPRemoteCommand] {
            cmd.removeTarget(nil)
        }
        commandsInstalled = false
    }
}
