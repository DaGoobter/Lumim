import UIKit
import AVFoundation
import Combine
import MediaPlayer
import Observation

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    let startTicks: Int64
    var localDownload: DownloadRecord? = nil
    /// A specific version (e.g. 4K vs 1080p, Director's Cut) to play.
    var mediaSourceId: String? = nil
    /// Use Apple's player even for files the Huefin Engine would normally take (needed for Picture in Picture).
    var forceApple = false
    /// Pop straight into Picture in Picture once the video is ready.
    var startPiP = false
}

/// What is actually being played and why — shown in the player's info panel.
struct StreamDiagnostics {
    var playMethod = "—"
    var container = "—"
    var videoCodec = "—"
    var resolution = "—"
    var videoRange = "—"
    var dolbyVisionProfile = "—"
    var bitrate = "—"
    var audio = "—"
    var subtitles = "Off"
    var transcodeReasons = "—"
    var decodedFormat = "—"
    var serverVideo = "—"
    var serverAudio = "—"
    var connection = "—"

    static func from(source: MediaSource, usingHLS: Bool, audioIndex: Int?, subtitleIndex: Int) -> StreamDiagnostics {
        var d = StreamDiagnostics()
        d.container = source.container ?? "—"
        if let v = source.videoStream {
            d.videoCodec = [v.codec?.uppercased(), v.profile].compactMap { $0 }.joined(separator: " ")
            d.resolution = "\(v.width ?? 0)×\(v.height ?? 0)" + (v.bitDepth.map { " · \($0)-bit" } ?? "")
            d.videoRange = v.videoRangeType ?? v.videoRange ?? "—"
            if let p = v.dvProfile { d.dolbyVisionProfile = "Profile \(p)" }
        }
        if let b = source.bitrate { d.bitrate = String(format: "%.1f Mbps", Double(b) / 1_000_000) }
        let wantedAudio = audioIndex ?? source.defaultAudioStreamIndex
        let audio = source.audioStreams.first { $0.index == wantedAudio } ?? source.audioStreams.first
        if let audio { d.audio = audio.displayTitle ?? audio.codec ?? "—" }
        if subtitleIndex >= 0, let sub = source.subtitleStreams.first(where: { $0.index == subtitleIndex }) {
            d.subtitles = sub.displayTitle ?? sub.language ?? "On"
        }

        if usingHLS {
            let reasons = source.transcodingUrl
                .flatMap { URLComponents(string: "http://x\($0)")?.queryItems }?
                .first { $0.name.lowercased() == "transcodereasons" }?.value ?? ""
            d.transcodeReasons = reasons.isEmpty ? "—" : reasons.replacingOccurrences(of: ",", with: ", ")
            d.playMethod = "Server stream (checking…)"
            d.serverVideo = "Checking…"
            d.serverAudio = "Checking…"
        } else {
            d.playMethod = "Direct Play (original file)"
            d.serverVideo = "Original file"
            d.serverAudio = "Original file"
        }
        return d
    }
}

extension MediaStream {
    /// Picture-based subtitles can't be sent as text; the server has to burn them into the video.
    var isImageSubtitle: Bool {
        ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle"]
            .contains((codec ?? "").lowercased())
    }
}

@MainActor @Observable
final class PlayerModel {
    /// The player on screen right now (for remote control from a parent's device).
    static weak var active: PlayerModel?
    /// Closes the player screen; set by PlayerScreen.
    static var closeAction: (() -> Void)?
    static func requestClose() { closeAction?() }

    let player = AVPlayer()
    var isLoading = true
    var errorMessage: String?
    @ObservationIgnored private var reconnecting = false
    /// Live TV: the stream stalled and we're waiting for it (or reconnecting).
    var liveStatus: String?
    var diagnostics = StreamDiagnostics()

    // Live playback state for the custom controls.
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var videoSize: CGSize = .zero

    /// The file being played (for the track picker).
    private(set) var source: MediaSource?
    /// nil = server default.
    private(set) var audioIndex: Int?
    /// -1 = subtitles off.
    private(set) var subtitleIndex: Int = -1

    var isOffline: Bool { request.localDownload != nil }
    var isLive: Bool { request.item.isLiveChannel }
    /// What's on now (live channels).
    var liveProgramTitle: String? { request.item.currentProgram?.title }

    @ObservationIgnored private var request: PlaybackRequest
    /// What's playing now (changes when the next episode starts).
    private(set) var item: BaseItem

    // Skip Intro / Credits and the next-episode countdown.
    private(set) var segments: [MediaSegment] = []
    private(set) var chapters: [ChapterMarker] = []
    private(set) var nextEpisode: BaseItem?
    /// Scrubbing thumbnails, when the server has generated them.
    private(set) var trickplay: TrickplayInfo?
    @ObservationIgnored private var trickplaySourceId: String?
    @ObservationIgnored private var trickplayTiles: [Int: UIImage] = [:]
    /// Seconds left before the next episode starts by itself; nil when the card isn't showing.
    private(set) var upNextCountdown: Int?
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var upNextShownAt: Date?
    @ObservationIgnored private var vodEndObserver: NSObjectProtocol?
    static let upNextSeconds = 10
    @ObservationIgnored private let client: JellyfinClient?
    @ObservationIgnored private let maxBitrate: Int
    @ObservationIgnored private let prefs: TrackPreferences
    @ObservationIgnored private var appliedPreferences = false
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var liveStreamId: String?
    @ObservationIgnored private var reportedMethod = "DirectPlay"
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var uiTimeObserver: Any?
    @ObservationIgnored private var remoteTargets: [Any] = []
    @ObservationIgnored private var statusCancellable: AnyCancellable?
    @ObservationIgnored private var liveWatchdog: Task<Void, Never>?
    @ObservationIgnored private var liveReconnects: [Date] = []
    @ObservationIgnored private var liveEndObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeekTicks: Int64 = 0
    @ObservationIgnored private var itemReady = false
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loadGeneration = 0
    // Picture check: some files play their sound but Apple's decoder never produces a picture (e.g. HEVC tagged
    // 'hev1', whose setup data sits inside the video). If no frame appears within a few seconds of direct play,
    // ask the server for a repackaged stream instead, which fixes the file on the way.
    @ObservationIgnored private var pictureProbe: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pictureWaitTicks = 0
    @ObservationIgnored private var forceServerStream = false
    @ObservationIgnored private var externalCancellable: AnyCancellable?
    /// True while video is going to an AirPlay screen (car, TV); we then send a stream any receiver can decode.
    private(set) var airPlayMode = false

    // MARK: Speed & sleep timer
    private(set) var speed: Float = 1
    /// When the sleep timer pauses playback (nil = off).
    private(set) var sleepAt: Date?
    /// Pause when this episode/movie ends instead of playing the next one.
    private(set) var sleepAtEnd = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    func setSpeed(_ value: Float) {
        speed = value
        player.defaultRate = value
        if player.rate != 0 { player.rate = value }
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepAtEnd = false
        guard let minutes, minutes > 0 else { sleepAt = nil; return }
        let at = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = at
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.player.pause()
            self?.sleepAt = nil
        }
    }

    func setSleepAtEnd() {
        sleepTask?.cancel()
        sleepAt = nil
        sleepAtEnd = true
    }

    init(request: PlaybackRequest, client: JellyfinClient?, maxBitrate: Int, prefs: TrackPreferences) {
        self.request = request
        self.item = request.item
        self.client = client
        self.maxBitrate = maxBitrate
        self.prefs = prefs
    }

    var itemId: String { request.item.id }
    /// For handing playback to a Chromecast.
    var castClient: JellyfinClient? { client }

    func start() async {
        PlayerModel.active = self
        AudioPlayer.shared.stop()   // video takes over from any music/audiobook
        try? AVAudioSession.sharedInstance().setActive(true)
        uiTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                        queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshClock() }
        }
        setupRemoteCommands()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        externalCancellable = player.publisher(for: \.isExternalPlaybackActive)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] active in
                Task { @MainActor [weak self] in await self?.externalPlaybackChanged(active) }
            }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.report(.progress) }
        }
        vodEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, !self.isLive, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if self.sleepAtEnd { self.sleepAtEnd = false; return }
                if self.nextEpisode != nil, !self.upNextDismissed { await self.playNextEpisode() }
            }
        }
        await load(startTicks: request.startTicks)
        await loadEpisodeExtras()
    }

    // MARK: Skip & next episode

    /// The intro / recap / preview the playhead is inside right now, if any.
    var activeSkip: MediaSegment? {
        guard !isLive else { return nil }
        return segments.first { ["Intro", "Recap", "Preview"].contains($0.type ?? "") &&
            currentTime >= $0.start && currentTime < $0.end - 1 }
    }

    var skipLabel: String {
        switch activeSkip?.type {
        case "Recap": return "Skip Recap"
        case "Preview": return "Skip Preview"
        default: return "Skip Intro"
        }
    }

    func skipSegment() {
        guard let s = activeSkip else { return }
        autoSkipIn = nil
        seek(to: s.end)
    }

    // MARK: Auto-skip

    /// Seconds until an intro/recap is skipped automatically (shown on the Skip button).
    private(set) var autoSkipIn: Int?
    @ObservationIgnored private var autoSkipSegment: Double?
    @ObservationIgnored private var autoSkipSince: Date?
    @ObservationIgnored private var autoSkipDeclined: Set<Double> = []

    /// "Watch it": don't auto-skip this segment.
    func cancelAutoSkip() {
        if let start = activeSkip?.start { autoSkipDeclined.insert(start) }
        autoSkipIn = nil
    }

    private func updateAutoSkip() {
        guard let seg = activeSkip, itemReady, isPlaying, !SyncPlayManager.shared.controls(self) else {
            if activeSkip == nil { autoSkipIn = nil; autoSkipSegment = nil }
            return
        }
        let wanted = seg.type == "Recap" ? PlaybackPrefs.autoSkipRecap : PlaybackPrefs.autoSkipIntro
        guard wanted, !autoSkipDeclined.contains(seg.start) else { autoSkipIn = nil; return }
        if autoSkipSegment != seg.start { autoSkipSegment = seg.start; autoSkipSince = Date() }
        let left = PlaybackPrefs.autoSkipDelay - Int(Date().timeIntervalSince(autoSkipSince ?? Date()))
        if left <= 0 {
            autoSkipDeclined.insert(seg.start)
            skipSegment()
        } else {
            autoSkipIn = left
        }
    }

    /// When the credits start: the server's Outro marker if it has one, otherwise 30 seconds before the end.
    private var creditsStart: Double? {
        if let outro = segments.first(where: { $0.type == "Outro" }), outro.start > 0 { return outro.start }
        guard duration > 120 else { return nil }
        return duration - 30
    }

    private func loadEpisodeExtras() async {
        guard let client, !isLive else {
            segments = []; chapters = []; nextEpisode = nil; return
        }
        async let segs = client.mediaSegments(itemId: item.id)
        async let extras = client.playbackExtras(itemId: item.id)
        async let next: BaseItem? = item.type == "Episode" ? client.episodeAfter(item)
            : (item.type == "Movie" ? client.additionalParts(item.id).first : nil)
        let (s1, x1, n1) = await (segs, extras, next)
        segments = s1
        chapters = x1.chapters
        nextEpisode = n1
        trickplayTiles = [:]
        // Pick this file's thumbnails, preferring a width that looks sharp in the preview.
        let bySource = x1.trickplay[mediaSourceId ?? ""] ?? x1.trickplay.values.first
        if let sizes = bySource {
            trickplaySourceId = mediaSourceId ?? x1.trickplay.keys.first
            let sorted = sizes.values.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
            trickplay = sorted.first { ($0.width ?? 0) >= 320 } ?? sorted.last
        } else {
            trickplay = nil
        }
    }

    private func updateUpNext() {
        guard let next = nextEpisode, !upNextDismissed, !sleepAtEnd, let start = creditsStart, currentTime >= start, itemReady else {
            if upNextCountdown != nil && (currentTime < (creditsStart ?? .infinity)) { upNextCountdown = nil; upNextShownAt = nil }
            return
        }
        _ = next.id
        if PlaybackPrefs.autoSkipCredits, isPlaying {
            Task { await playNextEpisode() }
            return
        }
        if upNextShownAt == nil { upNextShownAt = Date() }
        guard isPlaying else { return }   // the countdown waits while paused
        let left = Self.upNextSeconds - Int(Date().timeIntervalSince(upNextShownAt ?? Date()))
        upNextCountdown = max(0, left)
        if left <= 0 { Task { await playNextEpisode() } }
    }

    /// The chapter the given time falls in.
    func chapter(at seconds: Double) -> ChapterMarker? {
        chapters.last { $0.start <= seconds }
    }

    /// The scrubbing thumbnail for a time, cut out of its sprite sheet.
    func thumbnail(at seconds: Double) async -> UIImage? {
        guard let info = trickplay, let client, let sourceId = trickplaySourceId,
              let width = info.width, let interval = info.interval, interval > 0,
              let tw = info.tileWidth, let th = info.tileHeight, tw > 0, th > 0 else { return nil }
        let perTile = tw * th
        let count = info.thumbnailCount ?? Int.max
        let frame = min(max(0, Int(seconds * 1000) / interval), max(0, count - 1))
        let tileIndex = frame / perTile
        let tile: UIImage
        if let cached = trickplayTiles[tileIndex] {
            tile = cached
        } else {
            let url = client.trickplayTileURL(itemId: item.id, width: width, index: tileIndex, mediaSourceId: sourceId)
            var req = URLRequest(url: url)
            req.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: data) else { return nil }
            trickplayTiles[tileIndex] = img
            tile = img
        }
        guard let cg = tile.cgImage else { return nil }
        let cellW = cg.width / tw, cellH = cg.height / th
        let inTile = frame % perTile
        let rect = CGRect(x: (inTile % tw) * cellW, y: (inTile / tw) * cellH, width: cellW, height: cellH)
        guard let cut = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cut)
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNextCountdown = nil
    }

    /// Ends this episode (saving progress) and starts the next one in the same player.
    func playNextEpisode() async {
        guard let next = nextEpisode, !stopped else { return }
        await switchItem(next, startTicks: 0)
    }

    /// Swap what's playing without closing the player (next episode, or Watch Together changing the video).
    func switchItem(_ next: BaseItem, startTicks: Int64) async {
        guard !stopped else { return }
        nextEpisode = nil
        upNextCountdown = nil
        autoSkipDeclined = []
        autoSkipIn = nil
        upNextShownAt = nil
        upNextDismissed = false
        player.pause()
        if reportedStart { await report(.stop) }
        if let playSessionId, let client { await client.stopEncoding(playSessionId: playSessionId) }
        playSessionId = nil
        mediaSourceId = nil
        reportedStart = false
        segments = []
        chapters = []
        trickplay = nil
        trickplayTiles = [:]
        currentTime = 0
        duration = 0
        // Keep the same audio/subtitle choices by language, not by track number.
        appliedPreferences = false
        audioIndex = nil
        subtitleIndex = -1
        let dm = DownloadManager.shared
        let local = dm.localFile(for: next.id) != nil ? dm.records[next.id] : nil
        request = PlaybackRequest(item: next, startTicks: startTicks, localDownload: local)
        item = next
        await load(startTicks: startTicks)
        await loadEpisodeExtras()
    }

    // MARK: Transport

    func togglePlay() {
        let wantsPlay = player.timeControlStatus == .paused
        // In a Watch Together group the server decides when everyone plays or pauses.
        if SyncPlayManager.shared.controls(self) {
            Task { await SyncPlayManager.shared.request(wantsPlay ? .unpause : .pause) }
            return
        }
        if wantsPlay { player.play() } else { player.pause() }
        refreshClock()
    }

    func skip(by seconds: Double) {
        seek(to: max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, currentTime + seconds)))
    }

    func seek(to seconds: Double) {
        if SyncPlayManager.shared.controls(self) {
            currentTime = seconds
            Task { await SyncPlayManager.shared.request(.seek(Int64(seconds * 10_000_000))) }
            return
        }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Watch Together (applied locally, bypassing the group)

    var positionTicks: Int64 {
        let t = player.currentTime().seconds
        return t.isFinite ? Int64(t * 10_000_000) : 0
    }

    func syncPlay() { player.play(); refreshClock() }
    func syncPause() { player.pause(); refreshClock() }

    func syncSeek(ticks: Int64) async {
        let seconds = Double(ticks) / 10_000_000
        currentTime = seconds
        _ = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Waits until the current video can play (up to 45 seconds).
    func waitUntilReady() async {
        for _ in 0..<225 where !itemReady && !stopped {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func disableAutoNext() { upNextDismissed = true; upNextCountdown = nil }

    private func refreshClock() {
        let t = player.currentTime().seconds
        if t.isFinite { currentTime = t }
        if isLive {
            duration = 0
        } else if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            duration = d
        } else if let ticks = request.item.runTimeTicks {
            duration = Double(ticks) / 10_000_000
        }
        isPlaying = player.timeControlStatus != .paused
        if let size = player.currentItem?.presentationSize, size != .zero { videoSize = size }
        checkPicture()
        updateNowPlaying()
        updateUpNext()
        updateAutoSkip()
    }

    /// MP4/MOV files whose video keeps its setup inside the stream (hev1/avc3) show black in Apple's player.
    private static func hasHiddenSetup(_ src: MediaSource, itemId: String, client: JellyfinClient) async -> Bool {
        let containers = (src.container ?? "").lowercased()
        guard ["mp4", "m4v", "mov"].contains(where: { containers.contains($0) }) else { return false }
        let codec = src.mediaStreams?.first(where: { $0.type == "Video" })?.codec?.lowercased() ?? ""
        guard codec == "hevc" || codec == "h264" else { return false }
        let url = client.directPlayURL(itemId: itemId, mediaSourceId: src.id, container: src.container)
        return await MP4Probe.needsServerStream(itemId: itemId, url: url, authorization: client.authorizationHeader)
    }

    /// Sound but no picture after 4 seconds of direct play: switch to the server's repackaged stream.
    private func checkPicture() {
        guard let probe = pictureProbe, let item = player.currentItem, player.timeControlStatus == .playing else { return }
        let now = player.currentTime()
        if probe.hasNewPixelBuffer(forItemTime: now) || probe.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil {
            pictureProbe = nil                       // the picture is fine; stop checking
            item.remove(probe)
            return
        }
        // Counted in clock ticks (every half second while playing), so seeking doesn't skew it.
        pictureWaitTicks += 1
        guard pictureWaitTicks >= 8 else { return }
        let t = now.seconds.isFinite ? now.seconds : 0
        pictureProbe = nil
        item.remove(probe)
        forceServerStream = true
        MP4Probe.remember(request.item.id, needsServerStream: true)   // next time, skip straight to the server's stream
        let ticks = Int64(t * 10_000_000)
        Task { [weak self] in
            guard let self else { return }
            if let old = self.playSessionId, let client = self.client { await client.stopEncoding(playSessionId: old) }
            await self.load(startTicks: ticks)
        }
    }

    // MARK: Lock screen / Control Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets = [
            center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.play() }; return .success },
            center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success },
            center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: 10) }; return .success },
            center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: -10) }; return .success },
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                if let e = event as? MPChangePlaybackPositionCommandEvent {
                    let pos = e.positionTime
                    Task { @MainActor in self?.seek(to: pos) }
                }
                return .success
            },
        ]
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: isLive ? (liveProgramTitle ?? request.item.displayTitle)
                : (request.item.episodeLabel ?? request.item.displayTitle),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if request.item.type == "Episode" { info[MPMediaItemPropertyArtist] = request.item.seriesName }
        if isLive {
            info[MPMediaItemPropertyArtist] = request.item.name
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for cmd in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                    center.skipBackwardCommand, center.changePlaybackPositionCommand] as [MPRemoteCommand] {
            cmd.removeTarget(nil)
        }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// AirPlay screens (especially cars) can't decode 4K HEVC, Dolby Vision or surround formats and end up
    /// playing sound only. When video moves to one, switch to a 1080p H.264 stream; switch back when it returns.
    private func externalPlaybackChanged(_ active: Bool) async {
        guard client != nil, active != airPlayMode else { return }
        if !active {
            // Ignore a momentary blip while the receiver swaps streams.
            try? await Task.sleep(for: .seconds(1.5))
            guard !player.isExternalPlaybackActive, airPlayMode else { return }
        }
        airPlayMode = active
        let seconds = player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(seconds * 10_000_000) : request.startTicks
        if let old = playSessionId, let client { await client.stopEncoding(playSessionId: old) }
        if let live = liveStreamId, let client { await client.closeLiveStream(live); liveStreamId = nil }
        await load(startTicks: isLive ? 0 : ticks)
    }

    /// Switch audio and/or subtitle track. Reloads the stream at the current position.
    func selectTracks(audio: Int?, subtitle: Int) async {
        guard audio != audioIndex || subtitle != subtitleIndex else { return }
        audioIndex = audio
        subtitleIndex = subtitle
        let seconds = player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(seconds * 10_000_000) : request.startTicks
        if let old = playSessionId, let client { await client.stopEncoding(playSessionId: old) }
        if let live = liveStreamId, let client { await client.closeLiveStream(live); liveStreamId = nil }
        await load(startTicks: isLive ? 0 : ticks)
    }

    /// After the server downloads a subtitle, wait for it to appear on the item, then switch to it.
    func useDownloadedSubtitle(knownIndexes: Set<Int>, language: String) async -> Bool {
        guard let client else { return false }
        for delay in [1.5, 2.0, 3.0, 4.0, 5.0] {
            try? await Task.sleep(for: .seconds(delay))
            guard !stopped,
                  let info = try? await client.playbackInfo(itemId: request.item.id, maxBitrate: maxBitrate,
                                                            enableDirectPlay: false),
                  let src = info.mediaSources.first else { continue }
            if let sid = info.playSessionId { await client.stopEncoding(playSessionId: sid) }
            let fresh = src.subtitleStreams.filter { s in s.index.map { !knownIndexes.contains($0) } ?? false }
            let pick = fresh.first { $0.isExternal == true && Languages.matches($0.language, language) }
                ?? fresh.first { $0.isExternal == true } ?? fresh.first
            if let index = pick?.index {
                source = src
                await selectTracks(audio: audioIndex, subtitle: index)
                return true
            }
        }
        return false
    }

    private func load(startTicks: Int64) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        itemReady = false
        pendingSeekTicks = startTicks
        do {
            let asset: AVURLAsset
            if let local = request.localDownload, let url = local.localURL, !(airPlayMode && client != nil) {
                asset = AVURLAsset(url: url)
                mediaSourceId = local.mediaSourceId
                if let src = local.item.mediaSources?.first {
                    source = src
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: false, audioIndex: nil, subtitleIndex: -1)
                }
                diagnostics.playMethod = "Offline · \(local.kind.label)"
                diagnostics.connection = "Offline (on this device)"
            } else {
                guard let client else { throw JellyfinError.noMediaSource }
                // A non-default track needs the server's stream, which carries exactly the chosen tracks.
                // The video is still copied, so Dolby Vision/HDR is kept.
                let customTracks = subtitleIndex >= 0 || audioIndex != nil || forceServerStream
                let info = try await client.playbackInfo(itemId: request.item.id, maxBitrate: maxBitrate,
                                                         startTicks: startTicks, audioStreamIndex: audioIndex,
                                                         subtitleStreamIndex: subtitleIndex,
                                                         enableDirectPlay: !customTracks,
                                                         forAirPlay: airPlayMode,
                                                         mediaSourceId: request.mediaSourceId)
                guard generation == loadGeneration else { return }
                guard let src = info.mediaSources.first(where: { $0.id == request.mediaSourceId }) ?? info.mediaSources.first
                else { throw JellyfinError.noMediaSource }

                // First load: apply the user's default languages, then ask again with those tracks.
                if !appliedPreferences {
                    appliedPreferences = true
                    let choice = prefs.choose(for: src)
                    if choice.audio != audioIndex || choice.subtitle != subtitleIndex {
                        audioIndex = choice.audio
                        subtitleIndex = choice.subtitle
                        await load(startTicks: startTicks)
                        return
                    }
                }

                source = src
                mediaSourceId = src.id
                playSessionId = info.playSessionId
                liveStreamId = src.liveStreamId

                let url: URL
                if isLive {
                    // Live TV: always HLS (iOS can't play the raw MPEG-TS stream the server offers).
                    if let t = src.transcodingUrl, t.lowercased().contains(".m3u8"),
                       let u = client.absoluteURL(serverRelative: t) {
                        url = JellyfinClient.tuningLiveURL(u)
                    } else {
                        url = client.liveHLSURL(channelId: request.item.id, mediaSourceId: src.id,
                                                liveStreamId: src.liveStreamId, playSessionId: info.playSessionId,
                                                maxBitrate: maxBitrate, audioIndex: audioIndex)
                    }
                    reportedMethod = "Transcode"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: true,
                                                         audioIndex: audioIndex, subtitleIndex: subtitleIndex)
                    diagnostics.playMethod = "Live stream (HLS)"
                } else if src.supportsDirectPlay == true && !customTracks && !airPlayMode,
                          !(await Self.hasHiddenSetup(src, itemId: request.item.id, client: client)) {
                    url = client.directPlayURL(itemId: request.item.id, mediaSourceId: src.id, container: src.container)
                    reportedMethod = "DirectPlay"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: false,
                                                         audioIndex: audioIndex, subtitleIndex: subtitleIndex)
                } else if src.supportsDirectPlay == true && !customTracks && !airPlayMode && !forceServerStream {
                    // The file hides its video setup (hev1/avc3): ask again for the server's repackaged stream.
                    forceServerStream = true
                    await load(startTicks: startTicks)
                    return
                } else if let t = src.transcodingUrl,
                          let u = client.absoluteURL(serverRelative: t, allowSubtitleBurnIn: subtitleIndex >= 0) {
                    url = u
                    reportedMethod = "Transcode"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: true,
                                                         audioIndex: audioIndex, subtitleIndex: subtitleIndex)
                } else {
                    throw JellyfinError.noMediaSource
                }
                if airPlayMode { diagnostics.playMethod = "AirPlay (1080p H.264 for the receiver)" }
                diagnostics.connection = client.baseURL.host ?? client.baseURL.absoluteString
                asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader],
                ])
            }

            let item = AVPlayerItem(asset: asset)
            pictureProbe = nil
            pictureWaitTicks = 0
            if reportedMethod == "DirectPlay" && !isLive && request.item.mediaType != "Audio" {
                let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(probe)
                pictureProbe = probe
            }
            if isLive {
                // Sit a few seconds behind the live edge and stay there, so a slow segment doesn't freeze the picture.
                item.automaticallyPreservesTimeOffsetFromLive = true
                item.configuredTimeOffsetFromLive = CMTime(seconds: Double(JellyfinClient.liveSegmentLength * 3),
                                                           preferredTimescale: 1)
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            }
            observe(item, generation: generation)
            player.replaceCurrentItem(with: item)
        } catch {
            guard generation == loadGeneration else { return }
            // A request cut short by a reconnect or by closing the player isn't a real failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled { return }
            if isLive, !reconnecting, await reconnectLive(reason: "Reconnecting to the channel…") { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func observe(_ item: AVPlayerItem, generation: Int) {
        statusCancellable = item.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    await self.handle(status: status, item: item)
                }
            }
    }

    private func handle(status: AVPlayerItem.Status, item: AVPlayerItem) async {
        switch status {
        case .readyToPlay:
            guard !itemReady else { return }
            itemReady = true
            isLoading = false
            liveStatus = nil
            errorMessage = nil
            if pendingSeekTicks > 0 && !isLive {
                let t = CMTime(seconds: Double(pendingSeekTicks) / 10_000_000, preferredTimescale: 600)
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { _ in }
            }
            player.play()
            if !reportedStart {
                reportedStart = true
                Task { await report(.start) }
            }
            Task { await applySubtitleSelection(item) }
            Task { await inspectDecodedFormat(item) }
            if reportedMethod == "Transcode" { Task { await checkServerSession() } }
            if isLive { startLiveWatchdog(item) }
        case .failed:
            if let e = item.error as NSError?, e.code == NSURLErrorCancelled { return }
            if isLive, await reconnectLive(reason: "The channel dropped. Reconnecting…") { return }
            errorMessage = item.error?.localizedDescription ?? "Playback failed."
            isLoading = false
        default:
            break
        }
    }

    /// The server's stream carries only the chosen subtitle; make sure the player shows (or hides) it.
    private func applySubtitleSelection(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if subtitleIndex >= 0 {
            let option = group.options.first { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? group.options.first
            item.select(option, in: group)
        } else {
            item.select(nil, in: group)
        }
    }

    /// Reads the actual track format AVFoundation is decoding (e.g. "dvh1" = Dolby Vision, "hvc1" = HEVC).
    private func inspectDecodedFormat(_ item: AVPlayerItem) async {
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let chars = (try? await track.load(.mediaCharacteristics)) ?? []
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            diagnostics.decodedFormat = "\(codec) · " + (chars.contains(.containsHDRVideo) ? "HDR" : "SDR")
        } else {
            let size = item.presentationSize
            diagnostics.decodedFormat = "HLS stream · \(Int(size.width))×\(Int(size.height))"
        }
    }

    /// Asks the server what it is actually doing (copying vs re-encoding) instead of guessing.
    private func checkServerSession() async {
        guard let client else { return }
        let generation = loadGeneration
        for delay in [3.0, 6.0, 10.0] {
            try? await Task.sleep(for: .seconds(delay))
            guard !stopped, generation == loadGeneration else { return }
            guard let info = try? await client.currentSession()?.transcodingInfo else { continue }
            let videoDirect = info.isVideoDirect == true
            let audioDirect = info.isAudioDirect == true
            let hw = info.hardwareAccelerationType.flatMap { $0.lowercased() == "none" ? nil : $0 }
            diagnostics.serverVideo = videoDirect
                ? "Copied (original, untouched)"
                : "Re-encoded → \((info.videoCodec ?? "?").uppercased())" + (hw.map { " · \($0)" } ?? " · software")
            diagnostics.serverAudio = audioDirect
                ? "Copied (original)"
                : "Converted → \((info.audioCodec ?? "?").uppercased())" + (info.audioChannels.map { " \($0)ch" } ?? "")
            switch (videoDirect, audioDirect) {
            case (true, true): diagnostics.playMethod = "Direct Stream (remux only, full quality)"
            case (true, false): diagnostics.playMethod = "Direct Stream (video untouched, audio converted)"
            default: diagnostics.playMethod = "Transcode (video re-encoded)"
            }
            return
        }
        diagnostics.serverVideo = "Unknown (server didn't report)"
        diagnostics.serverAudio = "Unknown"
        diagnostics.playMethod = "Server stream"
    }

    enum ReportKind { case start, progress, stop }

    private func report(_ kind: ReportKind) async {
        let seconds = player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(seconds * 10_000_000) : 0
        // Offline: remember the position on the device; it syncs to the server when back online.
        if let local = request.localDownload {
            if kind != .start, ticks > 0 { DownloadManager.shared.recordOfflineProgress(local.itemId, ticks: ticks) }
            return
        }
        guard let client else { return }
        var body: [String: Any] = [
            "ItemId": request.item.id,
            "PositionTicks": ticks,
            "IsPaused": player.rate == 0,
            "PlayMethod": reportedMethod,
            "CanSeek": true,
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let playSessionId { body["PlaySessionId"] = playSessionId }
        if let liveStreamId { body["LiveStreamId"] = liveStreamId }
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        body["SubtitleStreamIndex"] = subtitleIndex
        let path: String
        switch kind {
        case .start: path = "Sessions/Playing"
        case .progress: path = "Sessions/Playing/Progress"
        case .stop: path = "Sessions/Playing/Stopped"
        }
        await client.reportPlayback(path, body: body)
    }

    // MARK: Live TV resilience

    /// Watches a live channel: shows "Buffering" during a stall, and if the stream is stuck or ends
    /// (the channel source restarted, the server dropped it), quietly reopens it at the live edge.
    private func startLiveWatchdog(_ item: AVPlayerItem) {
        liveWatchdog?.cancel()
        if let liveEndObserver { NotificationCenter.default.removeObserver(liveEndObserver) }
        liveEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in _ = await self?.reconnectLive(reason: "Reconnecting to the channel…") }
        }
        liveWatchdog = Task { @MainActor [weak self] in
            var stalledFor = 0
            var lastTime = -1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, !self.stopped else { return }
                let waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let t = self.player.currentTime().seconds
                // Playing but the clock isn't moving counts as stuck too.
                let frozen = self.player.timeControlStatus == .playing && t.isFinite && abs(t - lastTime) < 0.01
                lastTime = t
                if waiting || frozen {
                    stalledFor += 1
                    if stalledFor >= 2 { self.liveStatus = "Buffering…" }
                    if stalledFor >= 12 {
                        stalledFor = 0
                        _ = await self.reconnectLive(reason: "Reconnecting to the channel…")
                        return
                    }
                } else {
                    stalledFor = 0
                    if self.liveStatus != nil { self.liveStatus = nil }
                }
            }
        }
    }

    /// Reopens the live stream. Gives up (returns false) after a few tries in a short time.
    private func reconnectLive(reason: String) async -> Bool {
        guard isLive, !stopped, client != nil else { return false }
        // The stall watchdog and the end-of-stream notice can both fire; only reconnect once at a time.
        guard !reconnecting else { return true }
        reconnecting = true
        defer { reconnecting = false }
        let now = Date()
        liveReconnects = liveReconnects.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard liveReconnects.count <= 4 else {
            liveStatus = nil
            return false
        }
        liveStatus = reason
        liveWatchdog?.cancel()
        if let old = playSessionId, let client { await client.stopEncoding(playSessionId: old) }
        if let live = liveStreamId, let client { await client.closeLiveStream(live); liveStreamId = nil }
        await load(startTicks: 0)
        return true
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if PlayerModel.active === self { PlayerModel.active = nil }
        sleepTask?.cancel()
        SyncPlayManager.shared.unbind(self)
        liveWatchdog?.cancel()
        if let vodEndObserver { NotificationCenter.default.removeObserver(vodEndObserver) }
        if let liveEndObserver { NotificationCenter.default.removeObserver(liveEndObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let uiTimeObserver { player.removeTimeObserver(uiTimeObserver) }
        uiTimeObserver = nil
        clearRemoteCommands()
        statusCancellable = nil
        player.pause()
        if reportedStart { await report(.stop) }
        player.replaceCurrentItem(with: nil)
        if let playSessionId, let client { await client.stopEncoding(playSessionId: playSessionId) }
        if let liveStreamId, let client { await client.closeLiveStream(liveStreamId) }
        if item.type == "Episode" { await DownloadManager.shared.runSmartDownloads(force: true) }
    }
}
