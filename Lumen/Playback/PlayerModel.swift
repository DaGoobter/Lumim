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
    var transcodeReasons = "—"
    var decodedFormat = "—"

    static let videoReasonMarkers = ["Video", "Subtitle", "Interlaced", "Anamorphic", "RefFrames", "ContainerBitrate"]

    static func from(source: MediaSource, usingHLS: Bool) -> StreamDiagnostics {
        var d = StreamDiagnostics()
        d.container = source.container ?? "—"
        if let v = source.videoStream {
            d.videoCodec = [v.codec?.uppercased(), v.profile].compactMap { $0 }.joined(separator: " ")
            d.resolution = "\(v.width ?? 0)×\(v.height ?? 0)" + (v.bitDepth.map { " · \($0)-bit" } ?? "")
            d.videoRange = v.videoRangeType ?? v.videoRange ?? "—"
            if let p = v.dvProfile { d.dolbyVisionProfile = "Profile \(p)" }
        }
        if let b = source.bitrate { d.bitrate = String(format: "%.1f Mbps", Double(b) / 1_000_000) }
        let audio = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex } ?? source.audioStreams.first
        if let audio { d.audio = audio.displayTitle ?? audio.codec ?? "—" }

        if usingHLS {
            let reasons = source.transcodingUrl
                .flatMap { URLComponents(string: "http://x\($0)")?.queryItems }?
                .first { $0.name.lowercased() == "transcodereasons" }?.value ?? ""
            d.transcodeReasons = reasons.isEmpty ? "—" : reasons.replacingOccurrences(of: ",", with: ", ")
            let videoTouched = videoReasonMarkers.contains { reasons.contains($0) }
            d.playMethod = videoTouched
                ? "Transcode (video re-encoded)"
                : "Direct Stream (remux, original video)"
        } else {
            d.playMethod = "Direct Play (original file)"
        }
        return d
    }
}

@MainActor @Observable
final class PlayerModel {
    let player = AVPlayer()
    var isLoading = true
    var errorMessage: String?
    var diagnostics = StreamDiagnostics()

    @ObservationIgnored private let request: PlaybackRequest
    @ObservationIgnored private let client: JellyfinClient?
    @ObservationIgnored private let maxBitrate: Int
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var reportedMethod = "DirectPlay"
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusCancellable: AnyCancellable?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false

    init(request: PlaybackRequest, client: JellyfinClient?, maxBitrate: Int) {
        self.request = request
        self.client = client
        self.maxBitrate = maxBitrate
    }

    func start() async {
        do {
            try? AVAudioSession.sharedInstance().setActive(true)
            let asset: AVURLAsset

            if let local = request.localDownload, let url = local.localURL {
                asset = AVURLAsset(url: url)
                mediaSourceId = local.mediaSourceId
                if let src = local.item.mediaSources?.first {
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: false)
                }
                diagnostics.playMethod = "Offline · \(local.kind.label)"
            } else {
                guard let client else { throw JellyfinError.noMediaSource }
                let info = try await client.playbackInfo(itemId: request.item.id, maxBitrate: maxBitrate,
                                                         startTicks: request.startTicks)
                guard let src = info.mediaSources.first else { throw JellyfinError.noMediaSource }
                mediaSourceId = src.id
                playSessionId = info.playSessionId

                let url: URL
                if src.supportsDirectPlay == true {
                    url = client.directPlayURL(itemId: request.item.id, mediaSourceId: src.id, container: src.container)
                    reportedMethod = "DirectPlay"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: false)
                } else if let t = src.transcodingUrl, let u = client.absoluteURL(serverRelative: t) {
                    url = u
                    reportedMethod = "Transcode"
                    diagnostics = StreamDiagnostics.from(source: src, usingHLS: true)
                } else {
                    throw JellyfinError.noMediaSource
                }
                asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader],
                ])
            }

            let item = AVPlayerItem(asset: asset)
            observe(item)
            player.replaceCurrentItem(with: item)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in self?.handle(status: status, item: item) }
            }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.report(.progress) }
        }
    }

    private func handle(status: AVPlayerItem.Status, item: AVPlayerItem) {
        switch status {
        case .readyToPlay:
            guard !started else { return }
            started = true
            isLoading = false
            if request.startTicks > 0 {
                let t = CMTime(seconds: Double(request.startTicks) / 10_000_000, preferredTimescale: 600)
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            player.play()
            Task { await report(.start) }
            Task { await inspectDecodedFormat(item) }
        case .failed:
            errorMessage = item.error?.localizedDescription ?? "Playback failed."
            isLoading = false
        default:
            break
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

    enum ReportKind { case start, progress, stop }

    private func report(_ kind: ReportKind) async {
        guard let client else { return }
        let seconds = player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(seconds * 10_000_000) : 0
        var body: [String: Any] = [
            "ItemId": request.item.id,
            "PositionTicks": ticks,
            "IsPaused": player.rate == 0,
            "PlayMethod": reportedMethod,
            "CanSeek": true,
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let playSessionId { body["PlaySessionId"] = playSessionId }
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
        if started { await report(.stop) }
        player.replaceCurrentItem(with: nil)
        if let playSessionId, let client { await client.stopEncoding(playSessionId: playSessionId) }
    }
}
