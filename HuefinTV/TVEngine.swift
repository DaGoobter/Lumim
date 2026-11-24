import SwiftUI
import VLCKitSPM

/// The video, plus the Siri Remote: Apple TV sends clicks, swipes and button presses here (UIKit handles
/// them reliably and with no focus bubble on screen).
private struct EngineRemoteSurface: UIViewControllerRepresentable {
    let player: VLCMediaPlayer
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onLeft: () -> Void
    var onRight: () -> Void
    var onDown: () -> Void
    var onUp: () -> Void
    var onMenu: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.surface = self
        player.drawable = c.videoView
        return c
    }
    func updateUIViewController(_ c: Controller, context: Context) { c.surface = self }

    final class FocusView: UIView {
        override var canBecomeFocused: Bool { true }
    }

    final class Controller: UIViewController {
        var surface: EngineRemoteSurface?
        let videoView = UIView()

        override func loadView() {
            let root = FocusView()
            root.backgroundColor = .black
            videoView.isUserInteractionEnabled = false
            videoView.frame = root.bounds
            videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.addSubview(videoView)
            view = root
            func press(_ type: UIPress.PressType, _ action: Selector) {
                let g = UITapGestureRecognizer(target: self, action: action)
                g.allowedPressTypes = [NSNumber(value: type.rawValue)]
                root.addGestureRecognizer(g)
            }
            press(.select, #selector(select))
            press(.playPause, #selector(playPause))
            press(.menu, #selector(menu))
            press(.leftArrow, #selector(left))
            press(.rightArrow, #selector(right))
            press(.downArrow, #selector(down))
            press(.upArrow, #selector(up))
            for (dir, action) in [(UISwipeGestureRecognizer.Direction.left, #selector(left)), (.right, #selector(right)),
                                  (.down, #selector(down)), (.up, #selector(up))] {
                let g = UISwipeGestureRecognizer(target: self, action: action)
                g.direction = dir
                root.addGestureRecognizer(g)
            }
        }
        override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setNeedsFocusUpdate(); updateFocusIfNeeded()
        }
        @objc private func select() { surface?.onSelect() }
        @objc private func playPause() { surface?.onPlayPause() }
        @objc private func menu() { surface?.onMenu() }
        @objc private func left() { surface?.onLeft() }
        @objc private func right() { surface?.onRight() }
        @objc private func down() { surface?.onDown() }
        @objc private func up() { surface?.onUp() }
    }
}

/// The Huefin Engine on Apple TV: plays MKV and other files straight from the original, so the server
/// doesn't repackage anything and sound stays perfectly in sync.
/// Remote: click or ▶︎❚❚ = play/pause (or Skip Intro when offered), swipe or press ◀︎ ▶︎ = 10 s,
/// swipe up = show controls, swipe down = audio & subtitles, Menu = hide controls, then exit.
struct TVEngineScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: EnginePlayerModel?
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showTracks = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                EngineRemoteSurface(
                    player: model.player,
                    onSelect: { select(model) },
                    onPlayPause: { model.togglePlay(); reveal() },
                    onLeft: { model.skip(by: -Double(PlaybackPrefs.skipBack)); reveal() },
                    onRight: { model.skip(by: Double(PlaybackPrefs.skipForward)); reveal() },
                    onDown: { showTracks = true },
                    onUp: { reveal() },
                    onMenu: {
                        if showControls && model.isPlaying { withAnimation { showControls = false } }
                        else { Task { await model.stop() }; dismiss() }
                    })
                .ignoresSafeArea()
                overlay(model).allowsHitTesting(false)
            }
        }
        .task {
            guard model == nil else { return }
            let m = EnginePlayerModel(request: request, client: app.client)
            model = m
            await m.start()
            reveal()
        }
        .onDisappear { Task { await model?.stop() } }
        .sheet(isPresented: $showTracks) { if let model { TVEngineTracks(model: model) } }
    }

    private func select(_ m: EnginePlayerModel) {
        if let seg = m.activeSkip { m.seek(to: seg.end) } else { m.togglePlay() }
        reveal()
    }

    private func reveal() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { showControls = false }
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    @ViewBuilder private func overlay(_ m: EnginePlayerModel) -> some View {
        if m.isLoading && m.errorMessage == nil { ProgressView().scaleEffect(1.5) }
        if let e = m.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(Theme.yellow)
                Text(e).font(.headline)
                Text("Press Menu to go back.").foregroundStyle(.secondary)
            }.padding(50).background(Theme.card, in: RoundedRectangle(cornerRadius: 26))
        }
        if let seg = m.activeSkip {
            VStack { Spacer(); HStack { Spacer()
                Label(seg.type == "Recap" ? "Click to Skip Recap" : "Click to Skip Intro", systemImage: "forward.end.fill")
                    .font(.headline).foregroundStyle(Theme.ink).padding(.horizontal, 26).padding(.vertical, 14)
                    .background(Theme.paper, in: Capsule())
            }}.padding(.trailing, 80).padding(.bottom, showControls ? 190 : 80)
        }
        if showControls || !m.isPlaying {
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Text(m.item.type == "Episode" ? (m.item.name ?? "") : m.item.displayTitle).font(.title3.bold())
                if let e = m.item.episodeLabel { Text("\(m.item.seriesName ?? "") · \(e)").font(.callout).foregroundStyle(.secondary) }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white).frame(width: m.duration > 0 ? g.size.width * min(1, m.currentTime / m.duration) : 0)
                    }
                }.frame(height: 8)
                HStack {
                    Image(systemName: m.isPlaying ? "pause.fill" : "play.fill")
                    Text(clock(m.currentTime)).monospacedDigit()
                    Spacer()
                    Text("Swipe down for audio & subtitles").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("-" + clock(max(0, m.duration - m.currentTime))).monospacedDigit()
                }.font(.callout)
            }
            .padding(.horizontal, 80).padding(.bottom, 60)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom).ignoresSafeArea())
            .transition(.opacity)
        }
    }
}

/// Audio and subtitle choices for the engine.
private struct TVEngineTracks: View {
    let model: EnginePlayerModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            List {
                Section("Audio") {
                    ForEach(model.audioTracks, id: \.self) { t in
                        Button { model.setAudio(t.index); dismiss() } label: {
                            HStack { Text(t.name); Spacer(); if t.index == model.audioTrack { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            List {
                Section("Subtitles") {
                    ForEach(model.subtitleTracks, id: \.self) { t in
                        Button { model.setSubtitle(t.index); dismiss() } label: {
                            HStack { Text(t.name); Spacer(); if t.index == model.subtitleTrack { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
        }
        .padding(60)
    }
}
