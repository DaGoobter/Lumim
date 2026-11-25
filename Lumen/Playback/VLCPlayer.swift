import SwiftUI
import AVFoundation
#if canImport(VLCKitSPM)
import VLCKitSPM

/// The Huefin Engine: VLC's decoders play MKV, AVI, DTS, TrueHD, PGS subtitles and other files that
/// Apple's player can't, straight from the original file, so the server doesn't convert anything.
@MainActor @Observable
final class EnginePlayerModel {
    @ObservationIgnored let player = VLCMediaPlayer()
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
    }

    func start() async {
        AudioPlayer.shared.stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
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
            let sourceId = request.mediaSourceId ?? item.mediaSources?.first?.id ?? item.id
            url = client.directPlayURL(itemId: item.id, mediaSourceId: sourceId,
                                       container: item.mediaSources?.first?.container)
        } else {
            errorMessage = "Not connected to your server."
            return
        }
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 3000,
            "start-time": Double(request.startTicks) / 10_000_000,
        ])
        player.media = media
        player.play()
        player.rate = speed
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
                               query: ["api_key": client.accessToken])
            _ = player.addPlaybackSlave(u, type: .subtitle, enforce: false)
        }
    }

    @ObservationIgnored private var lastTickTime: Double = -1
    @ObservationIgnored private var serverAudioNames: [String] = []
    @ObservationIgnored private var serverSubNames: [String] = []

    private func tick() {
        guard !stopped else { return }
        let t = Double(player.time.intValue) / 1000
        if t >= 0 { currentTime = t }
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        if len > 0 { duration = len } else if let r = item.runTimeTicks { duration = Double(r) / 10_000_000 }
        isPlaying = player.isPlaying
        // VLC can keep saying "buffering" on network streams while the picture is moving; trust the clock.
        let advancing = t > lastTickTime + 0.05 && player.isPlaying
        if t >= 0 { lastTickTime = t }
        switch advancing ? .playing : player.state {
        case .playing:
            isLoading = false
            if !tracksLoaded || player.numberOfSubtitlesTracks != Int32(subtitleTracks.count) { loadTracks() }
            if !startedReport { startedReport = true; Task { await report("Sessions/Playing") } }
        case .error:
            isLoading = false
            errorMessage = "The Huefin Engine couldn't open this file."
        case .ended:
            Task { await finished() }
        case .buffering, .opening:
            break
        default:
            isLoading = false
        }
        if Date().timeIntervalSince(lastReport) > 10, startedReport {
            lastReport = Date()
            Task { await report("Sessions/Playing/Progress") }
        }
    }

    private func loadTracks() {
        let aNames = player.audioTrackNames as? [String] ?? []
        let aIdx = (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.int32Value)
        audioTracks = zip(aIdx, aNames).filter { $0.0 >= 0 }.map { Track(index: $0.0, name: $0.1) }
        if audioTracks.count == serverAudioNames.count {
            audioTracks = zip(audioTracks, serverAudioNames).map { Track(index: $0.0.index, name: $0.1) }
        }
        let sNames = player.videoSubTitlesNames as? [String] ?? []
        let sIdx = (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.int32Value)
        subtitleTracks = zip(sIdx, sNames).map { Track(index: $0.0, name: $0.0 < 0 ? "Off" : $0.1) }
        let realSubs = subtitleTracks.filter { $0.index >= 0 }
        if !realSubs.isEmpty, realSubs.count <= serverSubNames.count {
            subtitleTracks = subtitleTracks.filter { $0.index < 0 } + zip(realSubs, serverSubNames).map { Track(index: $0.0.index, name: $0.1) }
        }
        audioTrack = player.currentAudioTrackIndex
        subtitleTrack = player.currentVideoSubTitleIndex
        tracksLoaded = !audioTracks.isEmpty || player.time.intValue > 3000
    }

    // MARK: Controls

    var activeSkip: MediaSegment? {
        segments.first { ["Intro", "Recap", "Preview"].contains($0.type ?? "") && currentTime >= $0.start && currentTime < $0.end - 1 }
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func skip(by seconds: Double) { seek(to: min(max(0, currentTime + seconds), max(duration, 1))) }

    func setAudio(_ index: Int32) { player.currentAudioTrackIndex = index; audioTrack = index }
    func setSubtitle(_ index: Int32) { player.currentVideoSubTitleIndex = index; subtitleTrack = index }
    func setSpeed(_ s: Float) { speed = s; player.rate = s }
    func setVolume(_ v: Int32) { volume = v; player.audio?.volume = v }

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
    }

    private func report(_ path: String) async {
        guard let client, request.localDownload == nil else { return }
        var body: [String: Any] = [
            "ItemId": item.id, "PositionTicks": Int64(currentTime * 10_000_000),
            "IsPaused": !player.isPlaying, "PlayMethod": "DirectPlay", "CanSeek": true,
        ]
        if let id = request.mediaSourceId ?? item.mediaSources?.first?.id { body["MediaSourceId"] = id }
        await client.reportPlayback(path, body: body)
    }
}

struct EngineVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        // VLC puts its picture inside `drawable` and attaches its own tap handler to the drawable's parent,
        // which steals taps from Huefin's controls. Two wrappers that ignore touches keep all of that out of the way.
        let outer = UIView()
        outer.backgroundColor = .black
        outer.isUserInteractionEnabled = false
        let middle = UIView(frame: outer.bounds)
        middle.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        middle.isUserInteractionEnabled = false
        let drawable = UIView(frame: middle.bounds)
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        drawable.isUserInteractionEnabled = false
        middle.addSubview(drawable)
        outer.addSubview(middle)
        player.drawable = drawable
        return outer
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

#if os(iOS)
/// Full-screen player for the Huefin Engine.
struct EnginePlayerScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: EnginePlayerModel?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var fill = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                EngineVideoSurface(player: model.player)
                    .scaleEffect(fill ? 1.33 : 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                // Taps land on this clear layer above the video, so they always reach Huefin (not VLC's views).
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
                controls(model)
                    .opacity(controlsVisible || !model.isPlaying ? 1 : 0)
                    .allowsHitTesting(controlsVisible || !model.isPlaying)
                    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            guard model == nil else { return }
            let m = EnginePlayerModel(request: request, client: app.client)
            model = m
            await m.start()
            scheduleHide()
        }
        .onDisappear { Task { await model?.stop() } }
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
                    Menu {
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
                                        Text(time(scrubValue)).font(.caption.monospacedDigit().weight(.bold))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .fixedSize()
                                            .offset(y: -44)
                                    })
                    PlayerSpeedMenu(speed: m.speed) { m.setSpeed($0); scheduleHide() }
                    Menu {
                        Section("Audio") {
                            ForEach(m.audioTracks, id: \.index) { t in
                                Button { m.setAudio(t.index) } label: { check(t.name, t.index == m.audioTrack) }
                            }
                        }
                        Section("Subtitles") {
                            ForEach(m.subtitleTracks, id: \.index) { t in
                                Button { m.setSubtitle(t.index) } label: { check(t.name, t.index == m.subtitleTrack) }
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
}
#endif // os(iOS)
#endif // VLCKitSPM

enum EngineAvailability {
    #if canImport(VLCKitSPM)
    static let available = true
    #else
    static let available = false
    #endif
}
