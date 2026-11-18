import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// One slot in the queue (the same song can appear twice).
struct QueueEntry: Identifiable, Equatable {
    let id = UUID()
    let item: BaseItem
    /// Spoken by the DJ before this track starts.
    var intro: String? = nil

    static func == (a: QueueEntry, b: QueueEntry) -> Bool { a.id == b.id }
}

/// An endless source of music (DJ, genre radio, artist radio…). Refills the queue as it runs low.
struct Station {
    let name: String
    /// Returns more entries to append; gets the ids already queued/played so it can avoid repeats.
    let refill: @MainActor (JellyfinClient, Set<String>) async -> [QueueEntry]
}

/// Background music & audiobook playback with a queue, stations, DJ voice, lock-screen controls and
/// server progress reporting.
@MainActor @Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    private(set) var queue: [QueueEntry] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var station: Station?
    /// What the DJ said for the current set (shown on Now Playing).
    private(set) var djLine: String?
    var showNowPlaying = false
    var djVoiceEnabled: Bool = UserDefaults.standard.object(forKey: "lumen.djVoice") as? Bool ?? true

    var current: BaseItem? { queue.indices.contains(index) ? queue[index].item : nil }
    var upcoming: [QueueEntry] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }
    var isAudiobook: Bool { current?.isAudiobook == true }
    var hasNext: Bool { index + 1 < queue.count || station != nil }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var commandsInstalled = false
    @ObservationIgnored private var playedIds = Set<String>()
    @ObservationIgnored private var refilling = false
    @ObservationIgnored private var djSpeaking = false
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

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
                await self.advance()
            }
        }
    }

    func setDJVoice(_ on: Bool) {
        djVoiceEnabled = on
        UserDefaults.standard.set(on, forKey: "lumen.djVoice")
    }

    // MARK: Starting playback

    func play(_ items: [BaseItem], startAt start: Int = 0, shuffle: Bool = false, client: JellyfinClient?) {
        play(entries: items.filter(\.isAudio).map { QueueEntry(item: $0) }, startAt: start, shuffle: shuffle,
             station: nil, client: client)
    }

    func play(station: Station, client: JellyfinClient) async {
        self.client = client
        stopSpeech()
        let first = await station.refill(client, [])
        guard !first.isEmpty else { return }
        // Get the first intro ready before the music starts.
        if djVoiceEnabled, let intro = first.first?.intro, DJVoice.shared.engine != .iPhone {
            DJVoice.shared.prefetch(intro)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        play(entries: first, startAt: 0, shuffle: false, station: station, client: client)
    }

    private func play(entries: [QueueEntry], startAt start: Int, shuffle: Bool, station: Station?, client: JellyfinClient?) {
        guard !entries.isEmpty else { return }
        if let client { self.client = client }
        var list = entries
        var startIndex = min(max(0, start), list.count - 1)
        if shuffle { list.shuffle(); startIndex = 0 }
        if current != nil { Task { await report(stopped: true) } }
        stopSpeech()
        self.station = station
        playedIds = []
        queue = list
        index = startIndex
        installCommands()
        try? AVAudioSession.sharedInstance().setActive(true)
        let first = list[startIndex].item
        loadCurrent(startAt: first.isAudiobook ? Double(first.resumeTicks) / 10_000_000 : 0)
    }

    // MARK: Building the queue

    /// Insert right after the current song.
    func playNext(_ items: [BaseItem], client: JellyfinClient?) {
        let entries = items.filter(\.isAudio).map { QueueEntry(item: $0) }
        guard !entries.isEmpty else { return }
        if current == nil { play(entries: entries, startAt: 0, shuffle: false, station: nil, client: client); return }
        queue.insert(contentsOf: entries, at: index + 1)
    }

    /// Add to the end of what's queued.
    func addToQueue(_ items: [BaseItem], client: JellyfinClient?) {
        let entries = items.filter(\.isAudio).map { QueueEntry(item: $0) }
        guard !entries.isEmpty else { return }
        if current == nil { play(entries: entries, startAt: 0, shuffle: false, station: nil, client: client); return }
        queue.append(contentsOf: entries)
    }

    /// Remove upcoming entries (offsets are within `upcoming`).
    func removeUpcoming(at offsets: IndexSet) {
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + index + 1 }))
    }

    /// Reorder upcoming entries (offsets are within `upcoming`).
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var up = upcoming
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + up
    }

    func clearUpcoming() {
        guard queue.indices.contains(index) else { return }
        queue = Array(queue[...index])
        station = nil
    }

    func endStation() { station = nil }

    // MARK: Transport

    func togglePlay() {
        if djSpeaking { stopSpeech() }
        if player.timeControlStatus == .paused { player.playImmediately(atRate: rate) } else { player.pause() }
        tick()
        Task { await report() }
    }

    func pause() {
        player.pause()
        tick()
    }

    func next() {
        Task {
            await report(stopped: true)
            stopSpeech()
            await advance()
        }
    }

    func previous() {
        if currentTime > 4 || index == 0 { seek(to: 0); return }
        Task { await report(stopped: true) }
        stopSpeech()
        index -= 1
        loadCurrent(startAt: 0, allowIntro: false)
    }

    func jump(to entry: QueueEntry) {
        guard let i = queue.firstIndex(of: entry) else { return }
        Task { await report(stopped: true) }
        stopSpeech()
        index = i
        loadCurrent(startAt: 0, allowIntro: false)
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
        stopSpeech()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        station = nil
        djLine = nil
        isPlaying = false
        showNowPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        removeCommands()
    }

    // MARK: Internals

    private func advance() async {
        await refillIfNeeded()
        if index + 1 < queue.count {
            index += 1
            loadCurrent(startAt: 0)
        } else {
            player.pause()
            tick()
        }
    }

    /// Keep stations endless: top up when only a few songs are left.
    private func refillIfNeeded() async {
        guard let station, let client, !refilling, queue.count - index <= 3 else { return }
        refilling = true
        defer { refilling = false }
        let exclude = playedIds.union(queue.map(\.item.id))
        let more = await station.refill(client, exclude)
        if djVoiceEnabled { more.compactMap(\.intro).forEach { DJVoice.shared.prefetch($0) } }
        queue.append(contentsOf: more)
    }

    private func loadCurrent(startAt seconds: Double, allowIntro: Bool = true) {
        guard queue.indices.contains(index) else { return }
        let entry = queue[index]
        let item = entry.item
        playedIds.insert(item.id)
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
        artwork = nil
        if commandsInstalled { refreshCommandAvailability() }
        loadArtwork(for: item)
        Task { await report(started: true) }

        if let intro = entry.intro { djLine = intro }
        if allowIntro, djVoiceEnabled, let intro = entry.intro {
            // Radio style: the song starts quietly under the DJ, then comes up.
            player.volume = 0.18
            player.playImmediately(atRate: rate)
            djSpeaking = true
            Task {
                await DJVoice.shared.say(intro)
                guard self.current?.id == item.id else { return }
                self.djSpeaking = false
                self.fadeVolume(to: 1)
            }
        } else {
            player.volume = 1
            player.playImmediately(atRate: rate)
        }
        tick()
        Task { await refillIfNeeded() }
    }

    // MARK: DJ voice

    private func stopSpeech() {
        guard djSpeaking else { return }
        djSpeaking = false
        DJVoice.shared.stop()
        fadeVolume(to: 1)
    }

    private func fadeVolume(to target: Float) {
        fadeTask?.cancel()
        fadeTask = Task {
            let start = player.volume
            for step in 1...12 {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                player.volume = start + (target - start) * Float(step) / 12
            }
        }
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
        if let album = item.album ?? station?.name { info[MPMediaItemPropertyAlbumTitle] = album }
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
