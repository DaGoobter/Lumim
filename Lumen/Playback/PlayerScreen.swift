import SwiftUI
import AVKit

import MediaPlayer

/// Lumen's own player: full-screen video with zoom (pinch, double-tap or the zoom menu), custom controls,
/// AirPlay, Picture in Picture, audio/subtitle picker and Stream Info.
struct PlayerScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel?
    @State private var showInfo = false
    @State private var showSubtitleSearch = false
    @State private var showSyncPlay = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var surface = VideoSurfaceHandle()
    @State private var volume = SystemVolume()
    @State private var brightness: Double = Double(UIScreen.main.brightness)
    @State private var originalBrightness: CGFloat?

    // Zoom: 1 = whole picture visible. "Fill" crops to cover the screen.
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var zoomHUD: String?
    @State private var zoomHUDTask: Task<Void, Never>?

    // Scrubbing
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var scrubThumb: UIImage?

    private var pinControls: Bool {
        model == nil || model?.isLoading == true || model?.errorMessage != nil || showInfo || showSubtitleSearch
            || scrubbing || model?.isPlaying == false || showSyncPlay
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let model {
                    VideoSurface(player: model.player, zoom: zoom, handle: surface)
                        .ignoresSafeArea()
                        .gesture(pinch(fillScale: fillScale(model: model, size: geo.size)))
                        .onTapGesture(count: 2) { toggleFill(model: model, size: geo.size) }
                        .onTapGesture { toggleControls() }

                    if model.isLoading && model.errorMessage == nil {
                        VStack(spacing: 14) {
                            ProgressView().tint(.white).scaleEffect(1.5)
                            if let status = model.liveStatus {
                                Text(status).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                            } else if model.isLive {
                                Text("Tuning in…").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    } else if let status = model.liveStatus, model.errorMessage == nil {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text(status).font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                    }

                    if let error = model.errorMessage {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                            Text("Couldn't play this").font(.headline)
                            Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Stream info") { showInfo = true }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .padding()
                    }

                    SkipAndUpNext(model: model, client: app.client, controlsShown: controlsVisible || pinControls)

                    controls(model: model, size: geo.size)
                        .opacity(controlsVisible || pinControls ? 1 : 0)
                        .allowsHitTesting(controlsVisible || pinControls)
                        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
                }

                // Hosts the system volume control (also hides the big system volume overlay while watching).
                if app.showVolumeSlider {
                    SystemVolumeHost(volume: volume).frame(width: 1, height: 1).opacity(0.01)
                }

                if let zoomHUD {
                    Text(zoomHUD)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            guard model == nil else { return }
            let m = PlayerModel(request: request, client: app.client, maxBitrate: app.maxBitrate,
                                prefs: app.trackPrefs)
            model = m
            await m.start()
            scheduleHide()
            await SyncPlayManager.shared.playerOpened(m)
        }
        .onDisappear {
            Task { await model?.stop() }
            if let originalBrightness { UIScreen.main.brightness = originalBrightness }
        }
        .onChange(of: model?.isPlaying) { _, playing in if playing == true { scheduleHide() } }
        .onChange(of: showInfo) { _, shown in if !shown { scheduleHide() } }
        .onChange(of: showSubtitleSearch) { _, shown in if !shown { scheduleHide() } }
        .sheet(isPresented: $showSubtitleSearch) {
            if let model, let client = app.client {
                SubtitleSearchView(model: model, client: client, language: app.trackPrefs.subtitleLanguage)
            }
        }
        .sheet(isPresented: $showSyncPlay) {
            if let model, let client = app.client { SyncPlaySheet(model: model, client: client) }
        }
        .sheet(isPresented: $showInfo) {
            if let model { StreamInfoView(diagnostics: model.diagnostics) }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(model: PlayerModel, size: CGSize) -> some View {
        ZStack {
            // Legibility gradients
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Brightness (left) and volume (right), like the iOS video apps people know.
            HStack {
                if app.showBrightnessSlider {
                    VerticalSlider(value: Binding(get: { brightness }, set: { setBrightness($0) }),
                                   systemImage: brightness < 0.4 ? "sun.min.fill" : "sun.max.fill",
                                   label: "Brightness")
                }
                Spacer()
                if app.showVolumeSlider {
                    VerticalSlider(value: Binding(get: { Double(volume.level) }, set: { volume.set(Float($0)) }),
                                   systemImage: volume.level == 0 ? "speaker.slash.fill"
                                       : (volume.level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"),
                                   label: "Volume")
                }
            }
            .padding(.horizontal, 22)

            VStack(spacing: 0) {
                // Top bar
                HStack(spacing: 12) {
                    circleButton("xmark", label: "Close") { close() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.item.displayTitle).font(.headline).lineLimit(1)
                        if let sub = model.isLive ? model.liveProgramTitle : model.item.episodeLabel {
                            Text(sub).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    if !model.isOffline, let source = model.source {
                        TrackMenu(model: model, source: source,
                                  onSearch: { showSubtitleSearch = true },
                                  onPick: { scheduleHide() })
                    }
                    if model.chapters.count > 1 {
                        ChapterMenu(model: model, timeString: timeString) { scheduleHide() }
                    }
                    RoutePicker().frame(width: 38, height: 38)
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        circleButton("pip.enter", label: "Picture in Picture") { surface.startPiP() }
                    }
                    PlayerMoreMenu(model: model, onSyncPlay: { showSyncPlay = true }, onInfo: { showInfo = true },
                                   onPick: { scheduleHide() })
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Transport
                HStack(spacing: 56) {
                    if !model.isLive {
                    Button { model.skip(by: -10); scheduleHide() } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 30, weight: .medium))
                    }
                    .accessibilityLabel("Back 10 seconds")
                    }
                    Button { model.togglePlay(); scheduleHide() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46, weight: .bold))
                            .frame(width: 64, height: 64)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    if !model.isLive {
                    Button { model.skip(by: 10); scheduleHide() } label: {
                        Image(systemName: "goforward.10").font(.system(size: 30, weight: .medium))
                    }
                    .accessibilityLabel("Forward 10 seconds")
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 8)

                Spacer()

                if model.isLive {
                    HStack(spacing: 10) {
                        Text("LIVE")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 5))
                        if let program = model.liveProgramTitle {
                            Text(program).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Spacer()
                        zoomMenu(model: model, size: size)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                } else {
                // Scrubber
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { scrubbing ? scrubValue : model.currentTime },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...max(model.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                scrubValue = model.currentTime
                                scrubbing = true
                            } else {
                                model.seek(to: scrubValue)
                                scrubbing = false
                                scheduleHide()
                            }
                        }
                    )
                    .tint(.white)
                    .background { ChapterTicks(model: model) }
                    .overlay(alignment: .bottomLeading) {
                        if scrubbing {
                            ScrubPreview(model: model, time: scrubValue, image: scrubThumb, timeText: timeString(scrubValue))
                        }
                    }
                    .task(id: scrubbing ? Int(scrubValue / Double(max(1, (model.trickplay?.interval ?? 10_000))) * 1000) : -1) {
                        guard scrubbing else { scrubThumb = nil; return }
                        if let img = await model.thumbnail(at: scrubValue) { scrubThumb = img }
                    }
                    HStack {
                        Text(timeString(scrubbing ? scrubValue : model.currentTime))
                        Spacer()
                        zoomMenu(model: model, size: size)
                        Spacer()
                        Text("-" + timeString(max(0, model.duration - (scrubbing ? scrubValue : model.currentTime))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                }
            }
        }
    }

    private func zoomMenu(model: PlayerModel, size: CGSize) -> some View {
        let fill = fillScale(model: model, size: size)
        return Menu {
            Button { setZoom(1, label: "Fit") } label: { Label("Fit (whole picture)", systemImage: "rectangle.arrowtriangle.2.inward") }
            Button { setZoom(fill, label: "Fill") } label: { Label("Fill screen", systemImage: "rectangle.arrowtriangle.2.outward") }
            Divider()
            ForEach([1.1, 1.25, 1.5, 2.0], id: \.self) { z in
                Button("\(Int(z * 100))%") { setZoom(CGFloat(z), label: "\(Int(z * 100))%") }
            }
        } label: {
            Label(zoomLabel(fill: fill), systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Zoom")
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    private func setBrightness(_ value: Double) {
        if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
        brightness = value
        UIScreen.main.brightness = CGFloat(value)
        scheduleHide()
    }

    // MARK: Zoom

    /// Scale that makes the video cover the whole screen (cropping the edges).
    private func fillScale(model: PlayerModel, size: CGSize) -> CGFloat {
        let video = model.videoSize
        guard video.width > 0, video.height > 0, size.width > 0, size.height > 0 else { return 1 }
        let videoAspect = video.width / video.height
        let screenAspect = size.width / size.height
        return max(videoAspect / screenAspect, screenAspect / videoAspect)
    }

    private func zoomLabel(fill: CGFloat) -> String {
        if abs(zoom - 1) < 0.01 { return "Fit" }
        if abs(zoom - fill) < 0.01 { return "Fill" }
        return "\(Int((zoom * 100).rounded()))%"
    }

    private func pinch(fillScale: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                if pinchStart == nil { pinchStart = zoom }
                var z = start * value.magnification
                z = min(max(z, 1), max(2.5, fillScale * 1.5))
                // Gentle snap to Fit / Fill.
                if abs(z - 1) < 0.03 { z = 1 }
                if abs(z - fillScale) < 0.04 { z = fillScale }
                zoom = z
                showZoomHUD(zoomLabel(fill: fillScale))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func toggleFill(model: PlayerModel, size: CGSize) {
        let fill = fillScale(model: model, size: size)
        if abs(zoom - 1) < 0.01 { setZoom(fill, label: "Fill") } else { setZoom(1, label: "Fit") }
    }

    private func setZoom(_ z: CGFloat, label: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { zoom = z }
        showZoomHUD(label)
        scheduleHide()
    }

    private func showZoomHUD(_ text: String) {
        withAnimation { zoomHUD = text }
        zoomHUDTask?.cancel()
        zoomHUDTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation { zoomHUD = nil }
        }
    }

    // MARK: Helpers

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !pinControls else { return }
            controlsVisible = false
        }
    }

    private func close() {
        Task {
            await model?.stop()
            dismiss()
        }
    }
}


/// Audio language and subtitle picker.
struct TrackMenu: View {
    let model: PlayerModel
    let source: MediaSource
    let onSearch: () -> Void
    let onPick: () -> Void

    var body: some View {
        Menu {
            if source.audioStreams.count > 1 {
                Section("Audio") {
                    ForEach(source.audioStreams, id: \.index) { stream in
                        Button {
                            pick(audio: stream.index, subtitle: model.subtitleIndex)
                        } label: {
                            item(stream.displayTitle ?? stream.language ?? "Track \(stream.index ?? 0)",
                                 selected: (model.audioIndex ?? source.defaultAudioStreamIndex) == stream.index)
                        }
                    }
                }
            }
            Section("Subtitles") {
                Button {
                    pick(audio: model.audioIndex, subtitle: -1)
                } label: {
                    item("Off", selected: model.subtitleIndex == -1)
                }
                ForEach(source.subtitleStreams, id: \.index) { stream in
                    Button {
                        pick(audio: model.audioIndex, subtitle: stream.index ?? -1)
                    } label: {
                        let name = stream.displayTitle ?? stream.language ?? "Subtitle"
                        item(stream.isImageSubtitle ? name + " · re-encodes video" : name,
                             selected: model.subtitleIndex == stream.index)
                    }
                }
                Button(action: onSearch) {
                    Label("Search online…", systemImage: "magnifyingglass")
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Audio and subtitles")
    }

    @ViewBuilder
    private func item(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func pick(audio: Int?, subtitle: Int) {
        onPick()
        Task { await model.selectTracks(audio: audio, subtitle: subtitle) }
    }
}

/// Finds subtitles online through the server (OpenSubtitles plugin) and switches to the one picked.
struct SubtitleSearchView: View {
    let model: PlayerModel
    let client: JellyfinClient
    @State var language: String
    @Environment(\.dismiss) private var dismiss
    @State private var results: [RemoteSubtitleInfo] = []
    @State private var loading = false
    @State private var message: String?
    @State private var downloadingId: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(results) { r in
                        Button { Task { await download(r) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.name ?? "Subtitle").font(.subheadline).lineLimit(2)
                                    Text(details(r)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if downloadingId == r.id { ProgressView() }
                            }
                        }
                        .disabled(downloadingId != nil)
                    }
                }
            }
            .navigationTitle("Find Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: language) { await search() }
        }
    }

    private func details(_ r: RemoteSubtitleInfo) -> String {
        var parts: [String] = []
        if r.isHashMatch == true { parts.append("Exact match") }
        if let p = r.providerName { parts.append(p) }
        if let f = r.format { parts.append(f.uppercased()) }
        if let d = r.downloadCount { parts.append("\(d) downloads") }
        if r.hearingImpaired == true { parts.append("SDH") }
        if r.forced == true { parts.append("Forced") }
        if r.machineTranslated == true || r.aiTranslated == true { parts.append("Machine translated") }
        return parts.joined(separator: " · ")
    }

    private func search() async {
        loading = true
        message = nil
        results = []
        do {
            let found = try await client.searchSubtitles(itemId: model.itemId, language: language)
            // Exact (hash) matches first, then most downloaded.
            results = found.sorted {
                ($0.isHashMatch == true ? 1 : 0, $0.downloadCount ?? 0) > ($1.isHashMatch == true ? 1 : 0, $1.downloadCount ?? 0)
            }
            if results.isEmpty {
                message = "No subtitles found. If this keeps happening, make sure the Open Subtitles plugin is installed on your Jellyfin server (Dashboard → Plugins → Catalog) and signed in with your opensubtitles.com account."
            }
        } catch {
            message = "Search failed: \(error.localizedDescription) Your server needs the Open Subtitles plugin (Dashboard → Plugins → Catalog)."
        }
        loading = false
    }

    private func download(_ r: RemoteSubtitleInfo) async {
        downloadingId = r.id
        message = nil
        let known = Set(model.source?.subtitleStreams.compactMap(\.index) ?? [])
        do {
            try await client.downloadSubtitle(itemId: model.itemId, subtitleId: r.id)
            message = "Downloaded. Adding it to the video…"
            if await model.useDownloadedSubtitle(knownIndexes: known, language: language) {
                dismiss()
            } else {
                message = "Downloaded to your server, but it hasn't shown up yet. Pick it from the subtitle menu in a moment."
            }
        } catch {
            message = "Download failed: \(error.localizedDescription)"
        }
        downloadingId = nil
    }
}


/// Lets SwiftUI buttons reach the Picture-in-Picture controller owned by the video view.
final class VideoSurfaceHandle {
    var pip: AVPictureInPictureController?
    func startPiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The video itself, rendered with AVPlayerLayer (HDR / Dolby Vision aware), scaled for zoom.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let zoom: CGFloat
    let handle: VideoSurfaceHandle

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .black
        let video = PlayerLayerView()
        video.playerLayer.player = player
        video.playerLayer.videoGravity = .resizeAspect
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        video.frame = container.bounds
        container.addSubview(video)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: video.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            handle.pip = pip
        }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let video = container.subviews.first as? PlayerLayerView else { return }
        if video.playerLayer.player !== player { video.playerLayer.player = player }
        guard abs(video.transform.a - zoom) > 0.001 else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            video.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        }
    }
}

/// Tall rounded slider used for brightness and volume.
struct VerticalSlider: View {
    @Binding var value: Double
    let systemImage: String
    let label: String
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(.white.opacity(0.9))
                    .frame(height: max(0, geo.size.height * value))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(value > 0.12 ? .black : .white)
                    .padding(.bottom, 10)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        value = min(1, max(0, start - g.translation.height / geo.size.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(width: 40, height: 150)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            value = min(1, max(0, value + (dir == .increment ? 0.1 : -0.1)))
        }
    }
}

/// Reads and sets the system volume (via a hidden MPVolumeView, the only supported way).
@Observable
final class SystemVolume {
    var level: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let v = session.outputVolume
            DispatchQueue.main.async { self?.level = v }
        }
    }

    func set(_ value: Float) {
        level = value
        let slider = view.subviews.compactMap { $0 as? UISlider }.first
        DispatchQueue.main.async { slider?.value = value }
    }
}

struct SystemVolumeHost: UIViewRepresentable {
    let volume: SystemVolume
    func makeUIView(context: Context) -> MPVolumeView { volume.view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// AirPlay button.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        v.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        v.layer.cornerRadius = 19
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}


struct StreamInfoView: View {
    let diagnostics: StreamDiagnostics

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    row("Method", diagnostics.playMethod)
                    row("Server video", diagnostics.serverVideo)
                    row("Server audio", diagnostics.serverAudio)
                    row("Decoder sees", diagnostics.decodedFormat)
                    row("Subtitles", diagnostics.subtitles)
                    row("Connection", diagnostics.connection)
                    row("Server reasons", diagnostics.transcodeReasons)
                }
                Section("Source file") {
                    row("Container", diagnostics.container)
                    row("Video", diagnostics.videoCodec)
                    row("Resolution", diagnostics.resolution)
                    row("Dynamic range", diagnostics.videoRange)
                    row("Dolby Vision", diagnostics.dolbyVisionProfile)
                    row("Bitrate", diagnostics.bitrate)
                    row("Audio", diagnostics.audio)
                }
                Section("This device") {
                    row("Dolby Vision", DeviceCapabilities.dolbyVision ? "Supported" : "Not supported")
                    row("HDR10", DeviceCapabilities.hdr10 ? "Supported" : "Not supported")
                    row("HEVC hardware", DeviceCapabilities.hevc ? "Yes" : "No")
                    row("AV1 hardware", DeviceCapabilities.av1 ? "Yes" : "No")
                }
            }
            .navigationTitle("Stream Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}


// MARK: - Skip Intro / Up Next

/// Floats over the video (shown even when the controls are hidden), like Netflix and Apple TV.
struct SkipAndUpNext: View {
    let model: PlayerModel
    let client: JellyfinClient?
    let controlsShown: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                if let countdown = model.upNextCountdown, let next = model.nextEpisode {
                    upNextCard(next: next, countdown: countdown)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if model.activeSkip != nil {
                    Button { model.skipSegment() } label: {
                        HStack(spacing: 8) {
                            Text(model.skipLabel)
                            Image(systemName: "forward.end.fill")
                        }
                        .font(.headline)
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .foregroundStyle(.black)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.trailing, 24)
            .padding(.bottom, controlsShown ? 120 : 40)
        }
        .animation(.spring(duration: 0.35), value: model.upNextCountdown != nil)
        .animation(.spring(duration: 0.35), value: model.activeSkip != nil)
        .animation(.easeInOut(duration: 0.25), value: controlsShown)
    }

    private func upNextCard(next: BaseItem, countdown: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { if let client { RemoteImage(url: client.imageURL(next.id, type: "Primary", maxWidth: 480)) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Circle().fill(.black.opacity(0.45)).frame(width: 44, height: 44)
                Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
            }
            .frame(width: 150)
            .onTapGesture { Task { await model.playNextEpisode() } }

            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next in \(countdown)").font(.caption.weight(.bold)).foregroundStyle(Theme.blue)
                    .contentTransition(.numericText(countsDown: true))
                Text(next.episodeLabel ?? next.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Button { Task { await model.playNextEpisode() } } label: {
                        Text("Play Now").font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(.black).background(.white, in: Capsule())
                    }
                    Button { model.dismissUpNext() } label: {
                        Text("Watch Credits").font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 230, alignment: .leading)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}


// MARK: - Scrubbing thumbnails & chapters

/// A thumbnail (when the server has them) and the chapter name, floating above the scrub position.
struct ScrubPreview: View {
    let model: PlayerModel
    let time: Double
    let image: UIImage?
    let timeText: String

    private let width: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let fraction = model.duration > 0 ? min(1, max(0, time / model.duration)) : 0
            let x = min(max(0, geo.size.width * fraction - width / 2), max(0, geo.size.width - width))
            VStack(spacing: 6) {
                if model.trickplay != nil {
                    ZStack {
                        Color.black
                        if let image {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                }
                VStack(spacing: 1) {
                    if let name = model.chapter(at: time)?.name, !name.isEmpty {
                        Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    Text(timeText).font(.caption.monospacedDigit().weight(.bold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .frame(width: width)
            .offset(x: x, y: -(model.trickplay != nil ? width * 9 / 16 + 52 : 44))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }
}

/// Small marks on the scrubber where each chapter starts.
struct ChapterTicks: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { geo in
            if model.duration > 0, model.chapters.count > 1 {
                ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, ch in
                    if ch.start > 1 {
                        Capsule()
                            .fill(.white.opacity(0.55))
                            .frame(width: 2, height: 8)
                            .position(x: geo.size.width * min(1, ch.start / model.duration), y: geo.size.height / 2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ChapterMenu: View {
    let model: PlayerModel
    let timeString: (Double) -> String
    var onPick: () -> Void

    var body: some View {
        Menu {
            ForEach(Array(model.chapters.enumerated()), id: \.offset) { i, ch in
                Button {
                    model.seek(to: ch.start)
                    onPick()
                } label: {
                    let title = "\(ch.name?.isEmpty == false ? ch.name! : "Chapter \(i + 1)")  ·  \(timeString(ch.start))"
                    if model.chapter(at: model.currentTime) == ch {
                        Label(title, systemImage: "play.fill")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Chapters")
    }
}


/// Playback speed, sleep timer and Watch Together.
struct PlayerMoreMenu: View {
    let model: PlayerModel
    let onSyncPlay: () -> Void
    let onInfo: () -> Void
    let onPick: () -> Void

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Menu {
            if !model.isLive {
                Menu {
                    ForEach(speeds, id: \.self) { s in
                        Button { model.setSpeed(s); onPick() } label: {
                            if s == model.speed { Label(label(s), systemImage: "checkmark") } else { Text(label(s)) }
                        }
                    }
                } label: { Label("Speed · \(label(model.speed))", systemImage: "gauge.with.dots.needle.50percent") }
            }
            Menu {
                Button { model.setSleepTimer(minutes: nil); onPick() } label: {
                    if model.sleepAt == nil && !model.sleepAtEnd { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { model.setSleepTimer(minutes: m); onPick() }
                }
                if !model.isLive {
                    Button { model.setSleepAtEnd(); onPick() } label: {
                        if model.sleepAtEnd { Label("End of this \(model.item.type == "Episode" ? "episode" : "video")", systemImage: "checkmark") }
                        else { Text("End of this \(model.item.type == "Episode" ? "episode" : "video")") }
                    }
                }
            } label: { Label(sleepLabel, systemImage: "moon.zzz") }
            if !model.isLive && !model.isOffline {
                Button { onSyncPlay() } label: {
                    Label(SyncPlayManager.shared.groupId == nil ? "Watch Together" : "Watch Together · On",
                          systemImage: "person.2.wave.2")
                }
            }
            Divider()
            Button { onInfo() } label: { Label("Stream Info", systemImage: "info.circle") }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                if model.sleepAt != nil || model.sleepAtEnd || model.speed != 1 || SyncPlayManager.shared.groupId != nil {
                    Circle().fill(Theme.accent).frame(width: 9, height: 9)
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel("More options")
    }

    private var sleepLabel: String {
        if model.sleepAtEnd { return "Sleep · end of video" }
        if let at = model.sleepAt {
            let mins = max(1, Int(ceil(at.timeIntervalSinceNow / 60)))
            return "Sleep · \(mins) min left"
        }
        return "Sleep Timer"
    }

    private func label(_ s: Float) -> String {
        s == 1 ? "Normal" : (s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s))×" : String(format: "%g×", s))
    }
}
