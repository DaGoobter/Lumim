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
        await load()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
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
        if let client {
            segments = await client.mediaSegments(itemId: item.id)
            await addExternalSubtitles(client)
        }
    }

    /// Subtitles stored as separate files on the server (.srt, .ass) next to the video.
    private func addExternalSubtitles(_ client: JellyfinClient) async {
        guard request.localDownload == nil, let full = try? await client.item(item.id),
              let src = full.mediaSources?.first(where: { $0.id == request.mediaSourceId }) ?? full.mediaSources?.first
        else { return }
        for s in src.subtitleStreams where s.isExternal == true {
            guard let idx = s.index else { continue }
            let codec = (s.codec ?? "srt").lowercased()
            let ext = ["ass", "ssa", "vtt", "srt"].contains(codec) ? codec : "srt"
            let u = client.url("Videos/\(item.id)/\(src.id)/Subtitles/\(idx)/0/Stream.\(ext)",
                               query: ["api_key": client.accessToken])
            _ = player.addPlaybackSlave(u, type: .subtitle, enforce: false)
        }
    }

    private func tick() {
        guard !stopped else { return }
        let t = Double(player.time.intValue) / 1000
        if t >= 0 { currentTime = t }
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        if len > 0 { duration = len } else if let r = item.runTimeTicks { duration = Double(r) / 10_000_000 }
        isPlaying = player.isPlaying
        switch player.state {
        case .playing:
            isLoading = false
            if !tracksLoaded { loadTracks() }
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
        let sNames = player.videoSubTitlesNames as? [String] ?? []
        let sIdx = (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.int32Value)
        subtitleTracks = zip(sIdx, sNames).map { Track(index: $0.0, name: $0.0 < 0 ? "Off" : $0.1) }
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
        let v = UIView()
        v.backgroundColor = .black
        player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

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
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(spacing: 12) {
                    round("xmark") { close() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.item.displayTitle).font(.headline).lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text([m.item.episodeLabel, "Huefin Engine"].compactMap { $0 }.joined(separator: " · "))
                        }
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer()
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
                    } label: { roundLabel("captions.bubble") }
                    Menu {
                        Section("Speed") {
                            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { s in
                                Button { m.setSpeed(s) } label: { check(s == 1 ? "Normal" : String(format: "%g×", s), s == m.speed) }
                            }
                        }
                        Section("Volume boost") {
                            ForEach([Int32(100), 125, 150, 200], id: \.self) { v in
                                Button { m.setVolume(v) } label: { check(v == 100 ? "Normal" : "\(v)%", v == m.volume) }
                            }
                        }
                    } label: { roundLabel("ellipsis") }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                HStack(spacing: 56) {
                    Button { m.skip(by: -Double(PlaybackPrefs.skipBack)); scheduleHide() } label: {
                        Image(systemName: "gobackward.\(PlaybackPrefs.skipBack)").font(.system(size: 30, weight: .medium))
                    }
                    Button { m.togglePlay(); scheduleHide() } label: {
                        Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 46, weight: .bold))
                            .frame(width: 64, height: 64).contentTransition(.symbolEffect(.replace))
                    }
                    Button { m.skip(by: Double(PlaybackPrefs.skipForward)); scheduleHide() } label: {
                        Image(systemName: "goforward.\(PlaybackPrefs.skipForward)").font(.system(size: 30, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                Spacer()
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { scrubbing ? scrubValue : m.currentTime }, set: { scrubValue = $0 }),
                           in: 0...max(m.duration, 1),
                           onEditingChanged: { editing in
                               if editing { scrubValue = m.currentTime; scrubbing = true }
                               else { m.seek(to: scrubValue); scrubbing = false; scheduleHide() }
                           })
                        .tint(.white)
                    HStack {
                        Text(time(scrubbing ? scrubValue : m.currentTime))
                        Spacer()
                        Text("-" + time(max(0, m.duration - (scrubbing ? scrubValue : m.currentTime))))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(symbol) }
    }

    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle()).foregroundStyle(.white)
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
#endif

enum EngineAvailability {
    #if canImport(VLCKitSPM)
    static let available = true
    #else
    static let available = false
    #endif
}
