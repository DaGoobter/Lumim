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
    // Sound but no picture (e.g. HEVC tagged 'hev1'): after 4 s of direct play with no frame, use the server's stream.
    @ObservationIgnored private var pictureProbe: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pictureWaitTicks = 0
    @ObservationIgnored private var forceServerStream = false
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

    // MARK: Subtitles drawn by Huefin (in sync, original file keeps playing, adjustable timing)
    private(set) var drawnSubtitle: EngineSubtitle?
    private(set) var subtitleDelay: Double = 0
    /// The text subtitle Huefin is drawing (-1 = off).
    private(set) var drawnIndex: Int = -1
    private(set) var textSubtitles: [MediaStream] = []
    @ObservationIgnored private var appSubs: AppSubtitles?
    @ObservationIgnored private var subtitleObserver: Any?
    @ObservationIgnored private var source: MediaSource?

    func chooseSubtitle(_ index: Int) {
        drawnIndex = index
        // Remember for the rest of this show.
        if let s = source?.subtitleStreams.first(where: { $0.index == index }) {
            ShowTrackChoice.remember(seriesId: item.seriesId, subtitle: ShowTrackChoice.pick(of: s))
        } else if index < 0 {
            ShowTrackChoice.remember(seriesId: item.seriesId, subtitle: .init(off: true))
        }
        Task { await loadDrawnSubtitles() }
        onActionsChanged?()
    }
    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (seconds * 10).rounded() / 10
        UserDefaults.standard.set(subtitleDelay, forKey: "huefin.subDelay.\(item.id)")
        updateDrawnSubtitle()
        onActionsChanged?()
    }
    private func loadDrawnSubtitles() async {
        subtitleDelay = UserDefaults.standard.double(forKey: "huefin.subDelay.\(item.id)")
        guard drawnIndex >= 0, let client, let src = source, let mid = mediaSourceId,
              let s = src.subtitleStreams.first(where: { $0.index == drawnIndex }) else { appSubs = nil; drawnSubtitle = nil; return }
        if appSubs?.streamIndex == drawnIndex { return }
        appSubs = nil; drawnSubtitle = nil
        let wanted = drawnIndex, itemId = item.id
        let loaded = await AppSubtitles.load(client: client, itemId: itemId, mediaSourceId: mid, stream: s)
        guard wanted == drawnIndex, itemId == item.id else { return }
        appSubs = loaded
        updateDrawnSubtitle()
    }
    private func updateDrawnSubtitle() {
        guard let appSubs else { if drawnSubtitle != nil { drawnSubtitle = nil }; return }
        let t = player.currentTime().seconds - subtitleDelay
        guard t.isFinite else { return }
        let size = player.currentItem?.presentationSize ?? .zero
        let next = appSubs.subtitle(at: t, videoWidth: Int(size.width), videoHeight: Int(size.height))
        if next != drawnSubtitle { drawnSubtitle = next }
    }
    var videoAspect: Double {
        let size = player.currentItem?.presentationSize ?? .zero
        return size.width > 0 && size.height > 0 ? Double(size.width / size.height) : 16.0 / 9.0
    }

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
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateDrawnSubtitle() }
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
            var info = try await client.playbackInfo(itemId: target.id, maxBitrate: app.playbackBitrate, startTicks: startTicks)
            guard var src = info.mediaSources.first else { throw URLError(.fileDoesNotExist) }
            // The person's default audio and subtitle languages (Settings).
            let choice = app.trackPrefs.choose(for: src, seriesId: target.seriesId)
            audioIndex = choice.audio; subtitleIndex = choice.subtitle
            // Text subtitles are drawn by Huefin (in sync, adjustable); only picture subtitles need the server's stream.
            textSubtitles = target.isLiveChannel ? [] : src.subtitleStreams.filter(AppSubtitles.isText)
            drawnIndex = -1
            if !target.isLiveChannel, subtitleIndex >= 0,
               let s = src.subtitleStreams.first(where: { $0.index == subtitleIndex }), AppSubtitles.isText(s) {
                drawnIndex = subtitleIndex; subtitleIndex = -1
            }
            var custom = (choice.audio != nil && choice.audio != src.defaultAudioStreamIndex) || subtitleIndex >= 0 || forceServerStream
            // MP4s whose video hides its setup data (hev1/avc3) show black in Apple's player: use the server's stream.
            if !custom, !target.isLiveChannel, src.supportsDirectPlay == true,
               ["mp4", "m4v", "mov"].contains(where: { (src.container ?? "").lowercased().contains($0) }),
               await MP4Probe.needsServerStream(itemId: target.id,
                                                url: client.directPlayURL(itemId: target.id, mediaSourceId: src.id, container: src.container),
                                                authorization: client.authorizationHeader) {
                custom = true; forceServerStream = true
            }
            // When the server has to repackage the file (MKV and friends), have it re-encode the audio too.
            // Copying the audio track as-is into Apple's stream format lets sound drift out of sync with the picture.
            let repackaged = !target.isLiveChannel && (custom || src.supportsDirectPlay != true)
            if repackaged {
                info = try await client.playbackInfo(itemId: target.id, maxBitrate: app.playbackBitrate, startTicks: startTicks,
                                                     audioStreamIndex: audioIndex, subtitleStreamIndex: subtitleIndex,
                                                     allowAudioCopy: false)
                src = info.mediaSources.first ?? src
            }
            playSessionId = info.playSessionId; mediaSourceId = src.id; liveStreamId = src.liveStreamId
            source = src
            appSubs = nil; drawnSubtitle = nil
            Task { await loadDrawnSubtitles() }
            let url: URL
            if target.isLiveChannel {
                if let t = src.transcodingUrl, t.lowercased().contains(".m3u8"), let u = client.absoluteURL(serverRelative: t) {
                    url = JellyfinClient.tuningLiveURL(u)
                } else {
                    url = client.liveHLSURL(channelId: target.id, mediaSourceId: src.id, liveStreamId: src.liveStreamId,
                                            playSessionId: info.playSessionId, maxBitrate: app.playbackBitrate, audioIndex: audioIndex)
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
            pictureProbe = nil; pictureWaitTicks = 0
            if method == "DirectPlay" && !target.isLiveChannel {
                let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                playerItem.add(probe)
                pictureProbe = probe
            }
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
                        // Huefin draws the subtitles: keep the player's own subtitle display off so nothing shows twice.
                        if self.drawnIndex >= 0 || !self.textSubtitles.isEmpty,
                           let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible), self.subtitleIndex < 0 {
                            playerItem.select(nil, in: group)
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

    private func checkPicture() {
        guard let probe = pictureProbe, let current = player.currentItem, player.timeControlStatus == .playing else { return }
        let now = player.currentTime()
        if probe.hasNewPixelBuffer(forItemTime: now) || probe.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil {
            pictureProbe = nil; current.remove(probe); return
        }
        pictureWaitTicks += 1
        guard pictureWaitTicks >= 8 else { return }
        pictureProbe = nil; current.remove(probe)
        forceServerStream = true
        MP4Probe.remember(item.id, needsServerStream: true)
        let ticks = Int64((now.seconds.isFinite ? now.seconds : 0) * 10_000_000)
        Task { await load(item, startTicks: ticks) }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        Task { await report("Sessions/Playing/Progress") }
        checkPicture()
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
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        appSubs = nil; drawnSubtitle = nil
        onClose?()
    }
}

/// Apple TV's own full-screen player (Siri Remote scrubbing, audio and subtitle menus, the info panel)
/// with Huefin's Skip Intro and Next Episode buttons on top.
/// Apple's player, shown the standard tvOS way (presented full screen) so the Menu / Back button
/// first closes whatever is open inside it (Subtitles, Audio, info panels) and only then leaves the movie.
/// Placed inside a SwiftUI screen instead, Menu went straight to that screen and quit playback.
final class TVPlayerHost: UIViewController {
    let player = HuefinAVPlayerController()
    private var presentedOnce = false
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .black }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentedOnce else { return }
        presentedOnce = true
        player.modalPresentationStyle = .fullScreen
        present(player, animated: false)
    }
    /// Takes the player away without leaving (to show an error underneath).
    func hidePlayer() {
        guard player.presentingViewController != nil else { return }
        player.closingOnPurpose = true
        player.dismiss(animated: false)
    }
}

final class HuefinAVPlayerController: AVPlayerViewController {
    /// Called when tvOS closes the player because Menu was pressed with nothing open.
    var onGone: (() -> Void)?
    var closingOnPurpose = false
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed && !closingOnPurpose { onGone?() }
    }
}

struct TVPlayerView: UIViewControllerRepresentable {
    let model: PlayerModel

    func makeUIViewController(context: Context) -> TVPlayerHost {
        let host = TVPlayerHost()
        let vc = host.player
        let model = model
        vc.onGone = { model.onClose?() }
        vc.player = model.player
        vc.appliesPreferredDisplayCriteriaAutomatically = true   // match frame rate and HDR / Dolby Vision
        model.onActionsChanged = { [weak vc] in
            guard let vc else { return }
            Task { @MainActor in update(vc) }
        }
        // Huefin's own subtitles, drawn over the picture.
        if let overlay = vc.contentOverlayView {
            let host = UIHostingController(rootView: TVDrawnSubtitles(model: model))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                                         host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                                         host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                                         host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)])
            context.coordinator.host = host
        }
        update(vc)
        return host
    }

    func updateUIViewController(_ host: TVPlayerHost, context: Context) {
        if model.errorMessage != nil { host.hidePlayer() }
    }

    final class Coordinator { var host: UIViewController? }
    func makeCoordinator() -> Coordinator { Coordinator() }

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
        vc.transportBarCustomMenuItems = subtitleMenus()
    }

    /// "Subtitles" (drawn by Huefin) and "Subtitle timing" in the player's top bar.
    @MainActor private func subtitleMenus() -> [UIMenuElement] {
        guard !model.textSubtitles.isEmpty else { return [] }
        var tracks: [UIMenuElement] = [UIAction(title: "Off", state: model.drawnIndex < 0 ? .on : .off) { _ in model.chooseSubtitle(-1) }]
        for s in model.textSubtitles {
            guard let i = s.index else { continue }
            tracks.append(UIAction(title: s.displayTitle ?? s.language ?? "Subtitle \(i)", state: model.drawnIndex == i ? .on : .off) { _ in
                model.chooseSubtitle(i)
            })
        }
        let subs = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: tracks)
        guard model.drawnIndex >= 0 else { return [subs] }
        let d = model.subtitleDelay
        let now = d == 0 ? "in sync" : String(format: "%@%.1f s %@", d > 0 ? "+" : "−", abs(d), d > 0 ? "later" : "earlier")
        func step(_ title: String, _ by: Double) -> UIAction {
            let a = UIAction(title: title) { _ in model.setSubtitleDelay(by == 0 ? 0 : model.subtitleDelay + by) }
            if #available(tvOS 16.0, *) { a.attributes = .keepsMenuPresented }
            return a
        }
        let timing = UIMenu(title: "Subtitle timing · \(now)", image: UIImage(systemName: "timer"),
                            children: [step("Later +0.5 s", 0.5), step("Later +0.1 s", 0.1), step("Reset", 0),
                                       step("Earlier −0.1 s", -0.1), step("Earlier −0.5 s", -0.5)])
        return [subs, timing]
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
            var closed = false
            m.onClose = { if !closed { closed = true; dismiss() } }
            model = m
            await m.start()
        }
        .onDisappear { model?.close() }
    }
}

/// Huefin's subtitles over Apple TV's player, lined up with the picture.
struct TVDrawnSubtitles: View {
    let model: PlayerModel
    var body: some View {
        EngineSubtitleView(subtitle: model.drawnSubtitle, aspect: model.videoAspect)
    }
}

