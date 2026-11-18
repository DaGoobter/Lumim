import SwiftUI
import AVKit

struct PlayerScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel?
    @State private var showInfo = false
    @State private var showSubtitleSearch = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var pinControls: Bool { model == nil || model?.isLoading == true || model?.errorMessage != nil || showInfo || showSubtitleSearch }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                VideoPlayerController(player: model.player, onTap: toggleControls).ignoresSafeArea()

                if model.isLoading && model.errorMessage == nil {
                    ProgressView().tint(.white).scaleEffect(1.5)
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
            }

            VStack {
                HStack {
                    overlayButton("xmark") { close() }
                    Spacer()
                    if let model, !model.isOffline, let source = model.source {
                        TrackMenu(model: model, source: source,
                                  onSearch: { showSubtitleSearch = true },
                                  onPick: { scheduleHide() })
                    }
                    overlayButton("info.circle") { showInfo = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                Spacer()
            }
            .opacity(controlsVisible || pinControls ? 1 : 0)
            .allowsHitTesting(controlsVisible || pinControls)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .statusBarHidden()
        .task {
            guard model == nil else { return }
            let m = PlayerModel(request: request, client: app.client, maxBitrate: app.maxBitrate,
                                prefs: app.trackPrefs)
            model = m
            await m.start()
            scheduleHide()
        }
        .onDisappear { Task { await model?.stop() } }
        .onChange(of: model?.isLoading) { _, loading in if loading == false { scheduleHide() } }
        .onChange(of: showInfo) { _, shown in if !shown { scheduleHide() } }
        .onChange(of: showSubtitleSearch) { _, shown in if !shown { scheduleHide() } }
        .sheet(isPresented: $showSubtitleSearch) {
            if let model, let client = app.client {
                SubtitleSearchView(model: model, client: client, language: app.trackPrefs.subtitleLanguage)
            }
        }
        .sheet(isPresented: $showInfo) {
            if let model { StreamInfoView(diagnostics: model.diagnostics) }
        }
    }

    private func overlayButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
    }

    /// Mirrors the system player: a tap shows/hides controls, and they fade after a few seconds.
    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
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

struct VideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    var onTap: () -> Void = {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void = {}
        @objc func tapped() { onTap() }
        // Let the system player keep handling the same tap (it toggles its own controls).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        context.coordinator.onTap = onTap
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onTap = onTap
    }
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
