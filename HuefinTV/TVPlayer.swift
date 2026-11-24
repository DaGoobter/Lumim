import SwiftUI
import AVKit
import Combine

/// Plays one video (and the next episodes) with Apple TV's own player: the original file when the
/// Apple TV can play it, otherwise the server repackages it (video untouched, so HDR and Dolby Vision stay).
@MainActor @Observable
final class PlayerModel {
    static weak var active: PlayerModel?
    static func requestClose() { active?.close() }

    let player = AVPlayer()
    private(set) var item: BaseItem
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var segments: [MediaSegment] = []
    private(set) var nextEpisode: BaseItem?
    private(set) var currentTime: Double = 0
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onActionsChanged: (() -> Void)?

    @ObservationIgnored private let app: AppState
    @ObservationIgnored private var client: JellyfinClient? { app.client }
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var liveStreamId: String?
    @ObservationIgnored private var method = "DirectPlay"
    @ObservationIgnored private var audioIndex: Int?
    @ObservationIgnored private var subtitleIndex: Int = -1
    @ObservationIgnored private var pendingSeek: Int64 = 0
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var autoNextDisabled = false
    @ObservationIgnored private var skipped: Set<Double> = []
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastSkipLabel: String?

    var isPlaying: Bool { player.rate != 0 }
    var positionTicks: Int64 { Int64(max(0, currentTime) * 10_000_000) }
    var isLive: Bool { item.isLiveChannel }

    init(request: PlaybackRequest, app: AppState) {
        self.item = request.item
        self.app = app
        pendingSeek = request.startTicks
        PlayerModel.active = self
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t.seconds) }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .sink { [weak self] n in
                Task { @MainActor in
                    guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                    await self.finished()
                }
            }.store(in: &cancellables)
        player.publisher(for: \.timeControlStatus).sink { [weak self] _ in
            Task { @MainActor in await self?.report("Sessions/Playing/Progress", force: true) }
        }.store(in: &cancellables)
    }

    func start() async {
        await load(item, startTicks: pendingSeek)
        await SyncPlayManager.shared.playerOpened(self)
    }

    // MARK: Loading

    private func load(_ target: BaseItem, startTicks: Int64) async {
        guard let client else { errorMessage = "Not connected to your server."; return }
        isLoading = true; errorMessage = nil; reportedStart = false; skipped = []
        item = target; pendingSeek = startTicks
        do {
            var info = try await client.playbackInfo(itemId: target.id, maxBitrate: app.maxBitrate, startTicks: startTicks)
            guard var src = info.mediaSources.first else { throw URLError(.fileDoesNotExist) }
            // The person's default audio and subtitle languages (Settings).
            let choice = app.trackPrefs.choose(for: src)
            audioIndex = choice.audio; subtitleIndex = choice.subtitle
            let custom = (choice.audio != nil && choice.audio != src.defaultAudioStreamIndex) || subtitleIndex >= 0
            // When the server has to repackage the file (MKV and friends), have it re-encode the audio too.
            // Copying the audio track as-is into Apple's stream format lets sound drift out of sync with the picture.
            let repackaged = !target.isLiveChannel && (custom || src.supportsDirectPlay != true)
            if repackaged {
                info = try await client.playbackInfo(itemId: target.id, maxBitrate: app.maxBitrate, startTicks: startTicks,
                                                     audioStreamIndex: audioIndex, subtitleStreamIndex: subtitleIndex,
                                                     allowAudioCopy: false)
                src = info.mediaSources.first ?? src
            }
            playSessionId = info.playSessionId; mediaSourceId = src.id; liveStreamId = src.liveStreamId
            let url: URL
            if target.isLiveChannel {
                if let t = src.transcodingUrl, t.lowercased().contains(".m3u8"), let u = client.absoluteURL(serverRelative: t) {
                    url = JellyfinClient.tuningLiveURL(u)
                } else {
                    url = client.liveHLSURL(channelId: target.id, mediaSourceId: src.id, liveStreamId: src.liveStreamId,
                                            playSessionId: info.playSessionId, maxBitrate: app.maxBitrate, audioIndex: audioIndex)
                }
                method = "Transcode"
            } else if src.supportsDirectPlay == true && !custom {
                url = client.directPlayURL(itemId: target.id, mediaSourceId: src.id, container: src.container)
                method = "DirectPlay"
            } else if let t = src.transcodingUrl, let u = client.absoluteURL(serverRelative: t, allowSubtitleBurnIn: subtitleIndex >= 0) {
                url = u
                method = "Transcode"
            } else { throw URLError(.fileDoesNotExist) }

            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader]])
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.externalMetadata = metadata(for: target)
            if target.isLiveChannel {
                playerItem.automaticallyPreservesTimeOffsetFromLive = true
                playerItem.configuredTimeOffsetFromLive = CMTime(seconds: 9, preferredTimescale: 1)
            }
            playerItem.publisher(for: \.status).sink { [weak self, weak playerItem] status in
                Task { @MainActor in
                    guard let self, let playerItem, playerItem === self.player.currentItem else { return }
                    switch status {
                    case .readyToPlay:
                        guard self.isLoading else { return }
                        self.isLoading = false
                        if self.pendingSeek > 0 && !self.isLive {
                            await self.player.seek(to: CMTime(seconds: Double(self.pendingSeek) / 10_000_000, preferredTimescale: 600),
                                                   toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                        }
                        if !SyncPlayManager.shared.controls(self) { self.player.play() }
                        await self.report("Sessions/Playing", force: true)
                        self.reportedStart = true
                    case .failed:
                        if self.isLive { try? await Task.sleep(for: .seconds(2)); await self.load(self.item, startTicks: 0); return }
                        self.errorMessage = playerItem.error?.localizedDescription ?? "This couldn't be played."
                        self.isLoading = false
                    default: break
                    }
                }
            }.store(in: &cancellables)
            player.replaceCurrentItem(with: playerItem)
            segments = target.isLiveChannel ? [] : await client.mediaSegments(itemId: target.id)
            nextEpisode = target.type == "Episode" ? await client.episodeAfter(target) : nil
            onActionsChanged?()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func metadata(for item: BaseItem) -> [AVMetadataItem] {
        func meta(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem(); m.identifier = id; m.value = value as NSString; m.extendedLanguageTag = "und"
            return m.copy() as? AVMetadataItem
        }
        var out = [meta(.commonIdentifierTitle, item.type == "Episode" ? item.name : item.displayTitle),
                   meta(.iTunesMetadataTrackSubTitle, item.type == "Episode" ? [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ") : item.productionYear.map(String.init)),
                   meta(.commonIdentifierDescription, item.overview)].compactMap { $0 }
        if let c = client, let data = try? Data(contentsOf: c.posterURL(for: item, width: 600)) {
            let art = AVMutableMetadataItem(); art.identifier = .commonIdentifierArtwork; art.value = data as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String; art.extendedLanguageTag = "und"
            if let a = art.copy() as? AVMetadataItem { out.append(a) }
        }
        return out
    }

    // MARK: Progress, skipping, up next

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        Task { await report("Sessions/Playing/Progress") }
        if activeSkip?.start != nil, PlaybackPrefs.autoSkipIntro, isPlaying, let s = activeSkip, !skipped.contains(s.start), !SyncPlayManager.shared.controls(self) {
            skipSegment()
        }
        if PlaybackPrefs.autoSkipCredits, !autoNextDisabled, nextEpisode != nil, let outro = segments.first(where: { $0.type == "Outro" }),
           seconds >= outro.start, seconds < outro.end - 1, isPlaying, !SyncPlayManager.shared.controls(self) {
            autoNextDisabled = true
            Task { await playNext() }
        }
        let label = activeSkip == nil ? nil : skipLabel
        let upNext = showUpNext
        let key = "\(label ?? "")|\(upNext)"
        if key != lastSkipLabel { lastSkipLabel = key; onActionsChanged?() }
    }

    var activeSkip: MediaSegment? {
        segments.first { ["Intro", "Recap", "Preview", "Commercial"].contains($0.type ?? "") && currentTime >= $0.start && currentTime < $0.end - 1 }
    }
    var skipLabel: String {
        switch activeSkip?.type { case "Recap": return "Skip Recap"; case "Preview": return "Skip Preview"; case "Commercial": return "Skip Ad"; default: return "Skip Intro" }
    }
    var showUpNext: Bool {
        guard nextEpisode != nil, !isLive else { return false }
        let duration = player.currentItem?.duration.seconds ?? 0
        if let outro = segments.first(where: { $0.type == "Outro" }) { return currentTime >= outro.start }
        return duration.isFinite && duration > 0 && currentTime >= duration - 40
    }

    func skipSegment() {
        guard let s = activeSkip else { return }
        skipped.insert(s.start)
        seek(to: s.end)
    }

    func seek(to seconds: Double) {
        if SyncPlayManager.shared.controls(self) {
            Task { await SyncPlayManager.shared.request(.seek(Int64(seconds * 10_000_000))) }
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playNext() async {
        guard let next = nextEpisode else { return }
        await report("Sessions/Playing/Stopped", force: true)
        let start = (next.progress ?? 0) < 0.9 ? next.resumeTicks : 0
        await load(next, startTicks: start)
    }

    private func finished() async {
        await report("Sessions/Playing/Stopped", force: true)
        if isLive { await load(item, startTicks: 0); return }
        if nextEpisode != nil && !autoNextDisabled && !SyncPlayManager.shared.controls(self) { await playNext() } else if !SyncPlayManager.shared.controls(self) { close() }
    }

    private func report(_ path: String, force: Bool = false) async {
        guard let client, reportedStart || path == "Sessions/Playing" else { return }
        if !force && Date().timeIntervalSince(lastReport) < 10 { return }
        lastReport = Date()
        var body: [String: Any] = ["ItemId": item.id, "PositionTicks": positionTicks, "IsPaused": player.rate == 0,
                                   "PlayMethod": method, "CanSeek": !isLive]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let playSessionId { body["PlaySessionId"] = playSessionId }
        if let liveStreamId { body["LiveStreamId"] = liveStreamId }
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        body["SubtitleStreamIndex"] = subtitleIndex
        await client.reportPlayback(path, body: body)
    }

    // MARK: Watch Together hooks

    func syncPlay() { player.play() }
    func syncPause() { player.pause() }
    func syncSeek(ticks: Int64) async {
        currentTime = Double(ticks) / 10_000_000
        await player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func disableAutoNext() { autoNextDisabled = true }
    func waitUntilReady() async {
        for _ in 0..<225 { if !isLoading || closed { return }; try? await Task.sleep(for: .milliseconds(200)) }
    }
    func switchItem(_ next: BaseItem, startTicks: Int64) async {
        await report("Sessions/Playing/Stopped", force: true)
        await load(next, startTicks: startTicks)
    }

    func close() {
        guard !closed else { return }
        closed = true
        SyncPlayManager.shared.unbind(self)
        if PlayerModel.active === self { PlayerModel.active = nil }
        let c = client, ps = playSessionId, live = liveStreamId
        Task {
            await report("Sessions/Playing/Stopped", force: true)
            if let ps { await c?.stopEncoding(playSessionId: ps) }
            if let live { await c?.closeLiveStream(live) }
        }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        onClose?()
    }
}

/// Apple TV's own full-screen player (Siri Remote scrubbing, audio and subtitle menus, the info panel)
/// with Huefin's Skip Intro and Next Episode buttons on top.
struct TVPlayerView: UIViewControllerRepresentable {
    let model: PlayerModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.appliesPreferredDisplayCriteriaAutomatically = true   // match frame rate and HDR / Dolby Vision
        model.onActionsChanged = { [weak vc] in
            guard let vc else { return }
            Task { @MainActor in update(vc) }
        }
        update(vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    @MainActor private func update(_ vc: AVPlayerViewController) {
        var actions: [UIAction] = []
        if model.activeSkip != nil {
            actions.append(UIAction(title: model.skipLabel, image: UIImage(systemName: "forward.fill")) { _ in model.skipSegment() })
        }
        if model.showUpNext, let next = model.nextEpisode {
            actions.append(UIAction(title: "Next Episode · \(next.episodeLabel ?? next.name ?? "")", image: UIImage(systemName: "forward.end.fill")) { _ in
                Task { await model.playNext() }
            })
        }
        vc.contextualActions = actions
    }
}

/// Full-screen playback, closed with the Menu / Back button.
/// Apple's player for files the Apple TV plays natively (best for HDR and Dolby Vision).
struct TVApplePlayerScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                TVPlayerView(model: model).ignoresSafeArea()
                if let e = model.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(Theme.yellow)
                        Text("Couldn't play this").font(.title2.bold())
                        Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
                        Button("Close") { dismiss() }.hueAction()
                    }
                    .padding(60).background(Theme.card, in: RoundedRectangle(cornerRadius: 30))
                }
            }
        }
        .task {
            AudioPlayer.shared.pause()
            let m = PlayerModel(request: request, app: app)
            m.onClose = { dismiss() }
            model = m
            await m.start()
        }
        .onDisappear { model?.close() }
    }
}
