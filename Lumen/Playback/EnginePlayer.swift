import SwiftUI
import AVFoundation
import AVKit
import Combine
#if canImport(Libmpv)

/// The Huefin Engine: plays MKV, AVI, DTS, TrueHD, PGS subtitles and other files that Apple's player can't,
/// straight from the original file, with HDR and Dolby Vision shown as intended.
///
/// It has two cores (see EngineCore): the native one (Apple's decoder and display: real Dolby Vision, Atmos,
/// Picture in Picture) for the files it can show as intended, and mpv for everything else. If the native core
/// can't show a file after all, mpv carries on from the same moment.
@MainActor @Observable
final class EnginePlayerModel {
    @ObservationIgnored private(set) var player: EngineCore
    /// Changes whenever the core (and so the video view) is swapped.
    private(set) var coreGeneration = 0
    @ObservationIgnored var onCoreChange: (() -> Void)?
    /// Subtitles drawn by the app (native core).
    private(set) var subtitle: EngineSubtitle?
    var usesNativeCore: Bool { player.engineName == "native" }
    private(set) var item: BaseItem
    private(set) var isPlaying = false
    private(set) var isLoading = true
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    struct Track: Hashable { let index: Int32; let name: String }
    private(set) var audioTracks: [Track] = []
    private(set) var subtitleTracks: [Track] = []
    private(set) var audioTrack: Int32 = -1
    private(set) var subtitleTrack: Int32 = -1
    private(set) var speed: Float = 1
    /// 100 = normal, up to 200 = boosted.
    private(set) var volume: Int32 = 100
    private(set) var segments: [MediaSegment] = []
    /// How the picture is being drawn ("Dolby Vision P5 → HDR (PQ) · hardware decode").
    private(set) var pictureInfo = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ended = false

    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private let client: JellyfinClient?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var startedReport = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var tracksLoaded = false

    init(request: PlaybackRequest, client: JellyfinClient?) {
        self.request = request
        self.item = request.item
        self.client = client
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
        player = EnginePrefs.nativeEnabled && request.localDownload == nil ? NativeCore() : MPVCore()
        #else
        player = MPVCore()
        #endif
    }

    /// Hooks the model up to whichever core is playing.
    private func wire() {
        player.onPlaybackRestart = { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.pictureInfo = self.player.pictureDescription
            if !self.startedReport { self.startedReport = true; Task { await self.report("Sessions/Playing") } }
        }
        player.onEnd = { [weak self] reason in
            guard let self, !self.stopped else { return }
            switch reason {
            case .finished: Task { await self.finished() }
            case .failed(let why):
                self.isLoading = false
                self.errorMessage = "The Huefin Engine couldn't open this file (\(why))."
            case .fallback(let at):
                self.switchToMPV(resumeAt: at)
            }
        }
    }

    /// Swaps in the mpv core (Level 3).
    private func useMPVCore() {
        guard player.engineName != "mpv" else { return }
        player.destroy()
        player = MPVCore()
        wire()
        subtitle = nil
        tracksLoaded = false
        coreGeneration += 1
        onCoreChange?()
    }

    /// Hands playback to mpv from the given moment (the native core couldn't show the file as intended).
    private func switchToMPV(resumeAt: Double) {
        guard player.engineName != "mpv", let url = currentURL else { return }
        useMPVCore()
        let m = player
        guard m.isReady else { errorMessage = "The Huefin Engine couldn't start on this device."; isLoading = false; return }
        isLoading = true
        m.load(url, start: resumeAt)
        if speed != 1 { m.speed = Double(speed) }
        for (u, title, lang) in externalSubs { m.addSubtitle(u, title: title, lang: lang) }
    }
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var externalSubs: [(URL, String, String?)] = []

    func start() async {
        AudioPlayer.shared.stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        poll = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                // Subtitles the app draws need a quick clock; everything else is fine twice a second.
                if !self.stopped { let sub = self.player.overlaySubtitle; if sub != self.subtitle { self.subtitle = sub } }
                n += 1
                if n % 5 == 0 { self.tick() }
            }
        }
        guard player.isReady else { errorMessage = "The Huefin Engine couldn't start on this device."; isLoading = false; return }
        wire()
        await load()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        tracksLoaded = false
        let url: URL
        if let local = request.localDownload?.localURL {
            url = local
        } else if let client {
            // The full item says what's inside the file, which decides the core.
            // Usually already known from the page you pressed Play on; only ask the server when it isn't.
            let full = item.mediaSources?.isEmpty == false ? item : ((try? await client.item(item.id)) ?? item)
            let src = full.mediaSources?.first(where: { $0.id == request.mediaSourceId }) ?? full.mediaSources?.first
            url = Self.sourceURL(for: full, mediaSourceId: request.mediaSourceId, client: client)
            #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
            if usesNativeCore && !NativeCore.canPlay(src) { useMPVCore() }
            #endif
        } else {
            errorMessage = "Not connected to your server."
            return
        }
        currentURL = url
        externalSubs = []
        thumbs = nil
        if request.localDownload == nil, let client {
            let itemId = item.id, sourceId = request.mediaSourceId
            Task { [weak self] in
                let t = await TrickplayThumbs.load(client: client, itemId: itemId, mediaSourceId: sourceId)
                if self?.item.id == itemId { self?.thumbs = t }
            }
        }
        player.load(url, start: Double(request.startTicks) / 10_000_000)
        restoreSubtitleDelay()
        if speed != 1 { player.speed = Double(speed) }
        // Intro markers and outside subtitle files load alongside the video, never holding it up.
        if let client {
            Task { [weak self] in
                guard let self else { return }
                await self.addExternalSubtitles(client)
                self.segments = await client.mediaSegments(itemId: self.item.id)
            }
        }
    }

    /// Subtitles stored as separate files on the server (.srt, .ass) next to the video.
    private func addExternalSubtitles(_ client: JellyfinClient) async {
        guard request.localDownload == nil, let full = try? await client.item(item.id),
              let src = full.mediaSources?.first(where: { $0.id == request.mediaSourceId }) ?? full.mediaSources?.first
        else { return }
        // The server's names ("English - AC3 - 5.1"), in the same order the engine lists the tracks.
        serverAudioNames = src.audioStreams.filter { $0.isExternal != true }.map { $0.displayTitle ?? $0.language ?? "Audio" }
        serverSubNames = (src.subtitleStreams.filter { $0.isExternal != true } + src.subtitleStreams.filter { $0.isExternal == true })
            .map { $0.displayTitle ?? $0.title ?? $0.language ?? "Subtitles" }
        if tracksLoaded { loadTracks() }
        for s in src.subtitleStreams where s.isExternal == true {
            guard let idx = s.index else { continue }
            let codec = (s.codec ?? "srt").lowercased()
            let ext = ["ass", "ssa", "vtt", "srt"].contains(codec) ? codec : "srt"
            let u = client.url("Videos/\(item.id)/\(src.id)/Subtitles/\(idx)/0/Stream.\(ext)",
                               query: ["ApiKey": client.accessToken])
            let title = s.displayTitle ?? s.title ?? s.language ?? "Subtitles"
            externalSubs.append((u, title, s.language))
            player.addSubtitle(u, title: title, lang: s.language)
        }
    }

    @ObservationIgnored private var lastTickTime: Double = -1
    @ObservationIgnored private var serverAudioNames: [String] = []
    @ObservationIgnored private var serverSubNames: [String] = []

    /// The address of the original file the engine plays (the same one Instant Play opens ahead of time).
    static func sourceURL(for item: BaseItem, mediaSourceId: String?, client: JellyfinClient) -> URL {
        let src = item.mediaSources?.first(where: { $0.id == mediaSourceId }) ?? item.mediaSources?.first
        let sourceId = mediaSourceId ?? src?.id ?? item.id
        return client.directPlayURL(itemId: item.id, mediaSourceId: sourceId, container: src?.container)
    }

    /// Scrubbing preview pictures (when the server has made them for this file).
    private(set) var thumbs: TrickplayThumbs?

    /// Instant Play for the next episode: open it in the background during the last minute and a half.
    @ObservationIgnored private var nextWarmed = false
    private func warmNextEpisode() {
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
        guard !nextWarmed, usesNativeCore, duration > 120, duration - currentTime < 90, currentTime > 30,
              item.type == "Episode", request.localDownload == nil, let client else { return }
        nextWarmed = true
        Task {
            guard let next = await client.episodeAfter(item), let full = try? await client.item(next.id) else { return }
            let src = full.mediaSources?.first
            guard NativeCore.canPlay(src) else { return }
            NativeCore.prewarm(url: Self.sourceURL(for: full, mediaSourceId: nil, client: client),
                               start: Double(full.resumeTicks) / 10_000_000)
        }
        #endif
    }

    private func tick() {
        guard !stopped else { return }
        warmNextEpisode()
        let t = player.time
        if t >= 0, !isLoading { currentTime = t }
        let len = player.duration
        if len > 0 { duration = len } else if let r = item.runTimeTicks { duration = Double(r) / 10_000_000 }
        isPlaying = player.isPlaying
        if !isLoading {
            let subs = player.tracks("sub").count
            if !tracksLoaded || subs != subtitleTracks.filter({ $0.index >= 0 }).count { loadTracks() }
            if pictureInfo.isEmpty || Int(t) % 10 == 0 { pictureInfo = player.pictureDescription }
        }
        if Date().timeIntervalSince(lastReport) > 10, startedReport {
            lastReport = Date()
            Task { await report("Sessions/Playing/Progress") }
        }
    }

    private func loadTracks() {
        let audio = player.tracks("audio")
        audioTracks = audio.map { Track(index: $0.id, name: $0.name) }
        if audioTracks.count == serverAudioNames.count {
            audioTracks = zip(audioTracks, serverAudioNames).map { Track(index: $0.0.index, name: $0.1) }
        }
        let subs = player.tracks("sub")
        var named = subs.map { Track(index: $0.id, name: $0.name) }
        if !named.isEmpty, named.count <= serverSubNames.count {
            named = zip(named, serverSubNames).map { Track(index: $0.0.index, name: $0.1) }
        }
        subtitleTracks = [Track(index: -1, name: "Off")] + named
        audioTrack = audio.first(where: \.selected)?.id ?? -1
        subtitleTrack = subs.first(where: \.selected)?.id ?? -1
        tracksLoaded = !audioTracks.isEmpty || currentTime > 3
    }

    // MARK: Controls

    var activeSkip: MediaSegment? {
        segments.first { ["Intro", "Recap", "Preview"].contains($0.type ?? "") && currentTime >= $0.start && currentTime < $0.end - 1 }
    }

    func togglePlay() {
        if player.isPaused { player.play() } else { player.pause() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: seconds)
    }

    func skip(by seconds: Double) { seek(to: min(max(0, currentTime + seconds), max(duration, 1))) }

    func setAudio(_ index: Int32) { player.selectAudio(index); audioTrack = index }
    func setSubtitle(_ index: Int32) { player.selectSubtitle(index); subtitleTrack = index }

    /// Subtitle timing (seconds; positive = later). Remembered per title, like Infuse.
    private(set) var subtitleDelay: Double = 0
    func setSubtitleDelay(_ seconds: Double) {
        let v = (seconds * 10).rounded() / 10
        subtitleDelay = v
        player.subtitleDelay = v
        UserDefaults.standard.set(v, forKey: "huefin.subDelay.\(item.id)")
    }
    private func restoreSubtitleDelay() {
        let v = UserDefaults.standard.double(forKey: "huefin.subDelay.\(item.id)")
        subtitleDelay = v
        player.subtitleDelay = v
        let a = UserDefaults.standard.double(forKey: "huefin.audioDelay.\(item.id)")
        audioDelay = a
        player.audioDelay = a
        nightMode = UserDefaults.standard.bool(forKey: "huefin.nightMode")
        player.nightMode = nightMode
    }

    /// Audio sync (seconds; positive = sound later), remembered per title.
    private(set) var audioDelay: Double = 0
    func setAudioDelay(_ seconds: Double) {
        let v = (seconds * 20).rounded() / 20
        audioDelay = v
        player.audioDelay = v
        UserDefaults.standard.set(v, forKey: "huefin.audioDelay.\(item.id)")
    }
    /// Night mode (remembered for everything until turned off).
    private(set) var nightMode = false
    func setNightMode(_ on: Bool) {
        nightMode = on
        player.nightMode = on
        UserDefaults.standard.set(on, forKey: "huefin.nightMode")
    }
    func setSpeed(_ s: Float) { speed = s; player.speed = Double(s) }
    func setVolume(_ v: Int32) { volume = v; player.volume = Double(v) }

    private func finished() async {
        guard !stopped, let client, item.type == "Episode" else { return }
        await report("Sessions/Playing/Stopped")
        guard let next = await client.episodeAfter(item) else { return }
        item = next
        request = PlaybackRequest(item: next, startTicks: 0)
        startedReport = false
        segments = []
        await load()
    }

    func stop() async {
        guard !stopped else { return }
        poll?.cancel()
        let ticks = Int64(currentTime * 10_000_000)
        if let local = request.localDownload {
            if ticks > 0 { DownloadManager.shared.recordOfflineProgress(local.itemId, ticks: ticks) }
        } else if startedReport {
            await report("Sessions/Playing/Stopped")
        }
        stopped = true
        player.stop()
        player.destroy()
        // Smart downloads: fetch the next episodes and clear the one you just finished.
        #if os(iOS)
        if item.type == "Episode" { Task { await DownloadManager.shared.runSmartDownloads(force: true) } }
        #endif
    }

    private func report(_ path: String) async {
        guard let client, request.localDownload == nil else { return }
        var body: [String: Any] = [
            "ItemId": item.id, "PositionTicks": Int64(currentTime * 10_000_000),
            "IsPaused": player.isPaused, "PlayMethod": "DirectPlay", "CanSeek": true,
        ]
        if let id = request.mediaSourceId ?? item.mediaSources?.first?.id { body["MediaSourceId"] = id }
        await client.reportPlayback(path, body: body)
    }
}

struct EngineVideoSurface: UIViewRepresentable {
    let video: UIView
    /// Bumps when the engine swaps cores, so the new picture replaces the old.
    let generation: Int
    func makeUIView(context: Context) -> UIView {
        let outer = UIView()
        outer.backgroundColor = .black
        outer.isUserInteractionEnabled = false
        attach(video, to: outer)
        return outer
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if video.superview !== uiView { uiView.subviews.forEach { $0.removeFromSuperview() }; attach(video, to: uiView) }
    }
    private func attach(_ v: UIView, to outer: UIView) {
        v.frame = outer.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outer.addSubview(v)
    }
}

/// Subtitles drawn by the app above the picture (the native core hands them over instead of drawing them).
struct EngineSubtitleView: View {
    let subtitle: EngineSubtitle?
    var aspect: Double = 16.0 / 9.0
    var body: some View {
        GeometryReader { g in
            switch subtitle {
            case .text(let line)?:
                VStack {
                    Spacer()
                    let box = SubtitleStyle.background == "box", outline = SubtitleStyle.background == "shadow"
                    Text(line)
                        .font(.system(size: max(15, g.size.height * 0.045 * SubtitleStyle.scale), weight: .semibold))
                        .foregroundStyle(Self.textColor)
                        .shadow(color: outline ? .black : .clear, radius: 2)
                        .shadow(color: outline ? .black.opacity(0.8) : .clear, radius: 6)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, box ? 12 : 0).padding(.vertical, box ? 5 : 0)
                        .background(box ? Color.black.opacity(0.72) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, 40)
                        .padding(.bottom, g.size.height * SubtitleStyle.lift)
                }
                .frame(maxWidth: .infinity)
            case .image(let img, let rect)?:
                // Place the picture inside the video frame (16:9-ish letterboxing is handled by fitting the frame).
                let frame = Self.videoFrame(in: g.size, aspect: aspect)
                Image(decorative: img, scale: 1)
                    .resizable()
                    .frame(width: rect.width * frame.width, height: rect.height * frame.height)
                    .position(x: frame.minX + rect.midX * frame.width, y: frame.minY + rect.midY * frame.height)
            case nil:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
    static var textColor: Color {
        switch SubtitleStyle.color {
        case "yellow": return Color(red: 1, green: 0.92, blue: 0.3)
        case "cyan": return Color(red: 0.6, green: 0.9, blue: 1)
        default: return .white
        }
    }
    static func videoFrame(in size: CGSize, aspect: Double = 16.0 / 9.0) -> CGRect {
        let aspect = CGFloat(aspect > 0.2 ? aspect : 16.0 / 9.0)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

#if os(iOS)
/// Full-screen player for the Huefin Engine.
struct EnginePlayerScreen: View {
    let request: PlaybackRequest
    /// Hands the video to Apple's player (AirPlay to a TV), continuing at the same moment.
    var handToApple: ((PlaybackRequest) -> Void)? = nil
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: EnginePlayerModel?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var scrubThumb: UIImage?
    @State private var showSubSync = false
    @State private var showAudioSync = false
    @State private var fill = false
    // Picture in Picture: Apple's player warms up silently behind the engine, then takes over without a gap.
    @State private var standby: PlayerModel?
    @State private var standbyHandle = VideoSurfaceHandle()
    @State private var poppingOut = false
    /// Picture in Picture straight from the native core's own layer (no hand-off needed).
    @State private var nativePiP: AVPictureInPictureController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let standby {
                VideoSurface(player: standby.player, zoom: 1, handle: standbyHandle)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if let model {
                EngineVideoSurface(video: model.player.videoView, generation: model.coreGeneration)
                    .scaleEffect(fill ? 1.33 : 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                EngineSubtitleView(subtitle: model.subtitle, aspect: model.player.videoAspect)
                // Taps land on this clear layer above the video.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { withAnimation(.spring) { fill.toggle() } }
                    .onTapGesture { controlsVisible.toggle(); scheduleHide() }
                if model.isLoading && model.errorMessage == nil {
                    ProgressView().tint(.white).scaleEffect(1.5)
                }
                if let err = model.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text(err).font(.headline)
                        Button("Close") { close() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                if showSubSync {
                    VStack { Spacer()
                        SubtitleSyncPanel(delay: model.subtitleDelay, set: { model.setSubtitleDelay($0) }, close: { showSubSync = false })
                    }
                    .padding(.bottom, 28)
                }
                if showAudioSync {
                    VStack { Spacer()
                        SubtitleSyncPanel(delay: model.audioDelay, set: { model.setAudioDelay($0) }, close: { showAudioSync = false },
                                          title: "Audio sync", symbol: "waveform",
                                          hint: "Voices before lips move? Press +. After? Press −.", steps: [0.25, 0.05])
                    }
                    .padding(.bottom, 28)
                }
                if let seg = model.activeSkip {
                    VStack { Spacer(); HStack { Spacer()
                        Button { model.seek(to: seg.end) } label: {
                            Label(seg.type == "Recap" ? "Skip Recap" : "Skip Intro", systemImage: "forward.end.fill")
                                .font(.headline).padding(.horizontal, 20).padding(.vertical, 13)
                                .foregroundStyle(.black).background(.white, in: Capsule())
                        }
                    }}
                    .padding(.trailing, 24).padding(.bottom, controlsVisible ? 120 : 40)
                }
                if poppingOut {
                    VStack {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Getting Picture in Picture ready…").font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.top, 70)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                controls(model)
                    .opacity(controlsVisible || !model.isPlaying ? 1 : 0)
                    .allowsHitTesting(controlsVisible || !model.isPlaying)
                    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            airPlayRouteChanged()
        }
        .task {
            guard model == nil else { return }
            let m = EnginePlayerModel(request: request, client: app.client)
            model = m
            await m.start()
            setUpNativePiP(m)
            scheduleHide()
        }
        .onChange(of: model?.coreGeneration) { _, _ in if let model { setUpNativePiP(model) } }
        .onDisappear {
            Task { await model?.stop() }
            // A warm-up that never made it into Picture in Picture shouldn't keep playing.
            if let standby, !PiPSession.shared.owns(standby) {
                PiPSession.shared.unregister(standby)
                Task { await standby.stop() }
            }
        }
    }

    private func controls(_ m: EnginePlayerModel) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    PlayerCircleButton(symbol: "chevron.down", label: "Close", iconSize: 21) { close() }
                    VStack(spacing: 3) {
                        Text(m.item.displayTitle).font(.headline.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                        if let sub = m.item.episodeLabel ?? m.item.productionYear.map(String.init) {
                            Text(sub).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    PlayerCircleButton(symbol: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                       label: fill ? "Fit" : "Fill screen") {
                        withAnimation(.spring) { fill.toggle() }; scheduleHide()
                    }
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        PlayerCircleButton(symbol: "pip.enter", label: "Picture in Picture") { popOut(m) }
                    }
                    // AirPlay: choosing a TV hands the video to Apple's player (which can send video over AirPlay).
                    RoutePicker().frame(width: 26, height: 26).playerCircle()
                        .accessibilityLabel("AirPlay")
                    Menu {
                        if !m.pictureInfo.isEmpty { Section("Picture") { Text(m.pictureInfo) } }
                        Section("Volume boost") {
                            ForEach([Int32(100), 125, 150, 200], id: \.self) { v in
                                Button { m.setVolume(v) } label: { check(v == 100 ? "Normal" : "\(v)%", v == m.volume) }
                            }
                        }
                    } label: {
                        Image(systemName: m.volume > 100 ? "speaker.plus.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 18, weight: .semibold)).playerCircle()
                    }
                    .accessibilityLabel("Volume boost")
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()

                PlayerTransport(isPlaying: m.isPlaying,
                                onBack: { m.skip(by: -Double(PlaybackPrefs.skipBack)); scheduleHide() },
                                onToggle: { m.togglePlay(); scheduleHide() },
                                onForward: { m.skip(by: Double(PlaybackPrefs.skipForward)); scheduleHide() })

                Spacer()

                HStack(spacing: 10) {
                    PlayerScrubPill(current: m.currentTime, duration: m.duration,
                                    scrubbing: $scrubbing, scrubValue: $scrubValue,
                                    onCommit: { m.seek(to: $0); scheduleHide() },
                                    track: { EmptyView() },
                                    bubble: {
                                        TrickplayBubble(duration: m.duration, time: scrubValue, hasPictures: m.thumbs != nil,
                                                        image: scrubThumb, timeText: time(scrubValue))
                                            .offset(y: -22)
                                    })
                        .task(id: scrubbing ? (m.thumbs?.frameIndex(at: scrubValue) ?? -2) : -1) {
                            guard scrubbing, let t = m.thumbs else { scrubThumb = nil; return }
                            if let img = await t.thumbnail(at: scrubValue) { scrubThumb = img }
                        }
                    PlayerSpeedMenu(speed: m.speed) { m.setSpeed($0); scheduleHide() }
                    Menu {
                        Section("Audio") {
                            ForEach(m.audioTracks, id: \.index) { t in
                                Button { m.setAudio(t.index) } label: { check(t.name, t.index == m.audioTrack) }
                            }
                        }
                        Section {
                            Toggle(isOn: Binding(get: { m.nightMode }, set: { m.setNightMode($0) })) {
                                Label("Night mode", systemImage: "moon.stars")
                            }
                            Button { showAudioSync = true; controlsVisible = false } label: {
                                Label(m.audioDelay == 0 ? "Audio sync" : "Audio sync (\(SubtitleSyncPanel.label(m.audioDelay)))",
                                      systemImage: "waveform.badge.magnifyingglass")
                            }
                        }
                        Section("Subtitles") {
                            ForEach(m.subtitleTracks, id: \.index) { t in
                                Button { m.setSubtitle(t.index) } label: { check(t.name, t.index == m.subtitleTrack) }
                            }
                        }
                        Section {
                            Button { showSubSync = true; controlsVisible = false } label: {
                                Label(m.subtitleDelay == 0 ? "Subtitle timing" : "Subtitle timing (\(SubtitleSyncPanel.label(m.subtitleDelay)))",
                                      systemImage: "timer")
                            }
                        }
                    } label: {
                        Image(systemName: "captions.bubble").font(.system(size: 19, weight: .semibold)).playerCircle()
                    }
                    .accessibilityLabel("Audio and subtitles")
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !scrubbing else { return }
            withAnimation { controlsVisible = false }
        }
    }

    private func close() {
        Task {
            await model?.stop()
            dismiss()
        }
    }

    /// The sound just moved to an AirPlay device (an Apple TV or AirPlay TV was picked): the engine draws video
    /// itself and can't send it over AirPlay, so Apple's player takes over at this exact moment.
    private func airPlayRouteChanged() {
        guard let m = model, let handToApple, !poppingOut,
              AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) else { return }
        poppingOut = true
        var req = PlaybackRequest(item: m.item, startTicks: Int64(max(0, m.currentTime) * 10_000_000))
        req.mediaSourceId = request.mediaSourceId
        req.forceApple = true
        Task {
            await m.stop()
            handToApple(req)
        }
    }

    /// The Huefin Engine can't float in a little window itself. So Apple's player (which can) quietly loads the same
    /// video behind it, muted. Once it's playing at the same moment, the sound switches over and the picture
    /// shrinks into the corner, with no black screen or reload in between.
    private func setUpNativePiP(_ m: EnginePlayerModel) {
        nativePiP = nil
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
        if let native = m.player as? NativeCore { nativePiP = native.makePiPController() }
        #endif
    }

    private func popOut(_ m: EnginePlayerModel) {
        if m.usesNativeCore, let nativePiP, nativePiP.isPictureInPicturePossible {
            controlsVisible = false
            nativePiP.startPictureInPicture()
            return
        }
        guard !poppingOut, standby == nil else { return }
        withAnimation { poppingOut = true }
        controlsVisible = false
        let req = PlaybackRequest(item: m.item, startTicks: Int64(max(0, m.currentTime) * 10_000_000),
                                  mediaSourceId: request.mediaSourceId, forceApple: true)
        let s = PlayerModel(request: req, client: app.client, maxBitrate: app.playbackBitrate, prefs: app.trackPrefs)
        s.player.isMuted = true
        standby = s
        Task {
            await s.start()
            s.player.isMuted = true
            var ready = false
            for _ in 0..<80 {   // up to 20 seconds for the server to get it going
                if s.isPlaying, !s.isLoading, let pip = standbyHandle.pip, pip.isPictureInPicturePossible { ready = true; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard ready else { await giveUp(s); return }
            // Line the two up exactly, then swap the sound and float.
            _ = await s.player.seek(to: CMTime(seconds: m.currentTime, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
            m.player.pause()
            s.player.isMuted = false
            PiPSession.shared.register(model: s, request: req, handle: standbyHandle, dismiss: { dismiss() })
            PiPSession.shared.startedByButton = true
            standbyHandle.pip?.startPictureInPicture()
            try? await Task.sleep(for: .seconds(2))
            if !PiPSession.shared.isFloating {   // iOS said no: carry on in the engine as if nothing happened
                m.player.play()
                await giveUp(s)
            }
        }
    }

    private func giveUp(_ s: PlayerModel) async {
        PiPSession.shared.unregister(s)
        await s.stop()
        standby = nil
        withAnimation { poppingOut = false }
    }
}
#endif // os(iOS)
#endif // Libmpv

enum EngineAvailability {
    #if canImport(Libmpv)
    static let available = true
    #else
    static let available = false
    #endif
}
