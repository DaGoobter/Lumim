import AVFoundation
import Combine
import Observation

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    let startTicks: Int64
    var localDownload: DownloadRecord? = nil
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
    let player = AVPlayer()
    var isLoading = true
    var errorMessage: String?
    var diagnostics = StreamDiagnostics()

    /// The file being played (for the track picker).
    private(set) var source: MediaSource?
    /// nil = server default.
    private(set) var audioIndex: Int?
    /// -1 = subtitles off.
    private(set) var subtitleIndex: Int = -1

    var isOffline: Bool { request.localDownload != nil }

    @ObservationIgnored private let request: PlaybackRequest
    @ObservationIgnored private let client: JellyfinClient?
    @ObservationIgnored private let maxBitrate: Int
    @ObservationIgnored private let prefs: TrackPreferences
    @ObservationIgnored private var appliedPreferences = false
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var reportedMethod = "DirectPlay"
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusCancellable: AnyCancellable?
    @ObservationIgnored private var pendingSeekTicks: Int64 = 0
    @ObservationIgnored private var itemReady = false
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loadGeneration = 0

    init(request: PlaybackRequest, client: JellyfinClient?, maxBitrate: Int, prefs: TrackPreferences) {
        self.request = request
        self.client = client
        self.maxBitrate = maxBitrate
        self.prefs = prefs
    }

    var itemId: String { request.item.id }

    func start() async {
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.report(.progress) }
        }
        await load(startTicks: request.startTicks)
    }

    /// Switch audio and/or subtitle track. Reloads the stream at the current position.
    func selectTracks(audio: Int?, subtitle: Int) async {
        guard audio != audioIndex || subtitle != subtitleIndex else { return }
        audioIndex = audio
        subtitleIndex = subtitle
        let seconds = player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(seconds * 10_000_000) : request.startTicks
        if let old = playSessionId, let client { await client.stopEncoding(playSessionId: old) }
        await load(startTicks: ticks)
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
            if let local = request.localDownload, let url = local.localURL {
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
                let customTracks = subtitleIndex >= 0 || audioIndex != nil
                let info = try await client.playbackInfo(itemId: request.item.id, maxBitrate: maxBitrate,
                                                         startTicks: startTicks, audioStreamIndex: audioIndex,
                                                         subtitleStreamIndex: subtitleIndex,
                                                         enableDirectPlay: !customTracks)
                guard generation == loadGeneration else { return }
                guard let src = info.mediaSources.first else { throw JellyfinError.noMediaSource }

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

                let url: URL
                if src.supportsDirectPlay == true && !customTracks {
                    url = client.directPlayURL(itemId: request.item.id, mediaSourceId: src.id, container: src.container)
                    reportedMethod = "DirectPlay"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: false,
                                                         audioIndex: audioIndex, subtitleIndex: subtitleIndex)
                } else if let t = src.transcodingUrl,
                          let u = client.absoluteURL(serverRelative: t, allowSubtitleBurnIn: subtitleIndex >= 0) {
                    url = u
                    reportedMethod = "Transcode"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: true,
                                                         audioIndex: audioIndex, subtitleIndex: subtitleIndex)
                } else {
                    throw JellyfinError.noMediaSource
                }
                diagnostics.connection = client.baseURL.host ?? client.baseURL.absoluteString
                asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader],
                ])
            }

            let item = AVPlayerItem(asset: asset)
            observe(item, generation: generation)
            player.replaceCurrentItem(with: item)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func observe(_ item: AVPlayerItem, generation: Int) {
        statusCancellable = item.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.handle(status: status, item: item)
                }
            }
    }

    private func handle(status: AVPlayerItem.Status, item: AVPlayerItem) {
        switch status {
        case .readyToPlay:
            guard !itemReady else { return }
            itemReady = true
            isLoading = false
            if pendingSeekTicks > 0 {
                let t = CMTime(seconds: Double(pendingSeekTicks) / 10_000_000, preferredTimescale: 600)
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            player.play()
            if !reportedStart {
                reportedStart = true
                Task { await report(.start) }
            }
            Task { await applySubtitleSelection(item) }
            Task { await inspectDecodedFormat(item) }
            if reportedMethod == "Transcode" { Task { await checkServerSession() } }
        case .failed:
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

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusCancellable = nil
        player.pause()
        if reportedStart { await report(.stop) }
        player.replaceCurrentItem(with: nil)
        if let playSessionId, let client { await client.stopEncoding(playSessionId: playSessionId) }
    }
}
