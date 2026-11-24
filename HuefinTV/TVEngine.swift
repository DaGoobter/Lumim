import SwiftUI
import UIKit
import VLCKitSPM

/// On-screen state for the engine's controls.
@MainActor @Observable
final class EngineUIState {
    var showControls = true
}

/// The Huefin Engine on Apple TV: plays MKV and other files straight from the original, so the server
/// doesn't repackage anything and sound stays perfectly in sync.
///
/// It is a plain UIKit screen (not SwiftUI) so every Siri Remote click, swipe and button press reaches it.
/// Remote: click or ▶︎❚❚ = play/pause (or Skip Intro when offered), swipe or press ◀︎ ▶︎ = skip,
/// swipe up = show controls, swipe down = audio & subtitles, Menu = hide controls, then exit.
final class TVEngineViewController: UIViewController {
    private let model: EnginePlayerModel
    private let ui = EngineUIState()
    private let videoView = UIView()
    private var hideTask: Task<Void, Never>?
    private var closing = false
    private var showingTracks = false

    init(request: PlaybackRequest, client: JellyfinClient?) {
        model = EnginePlayerModel(request: request, client: client)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    final class FocusView: UIView {
        override var canBecomeFocused: Bool { true }
    }

    override func loadView() {
        let root = FocusView()
        root.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        videoView.backgroundColor = .black
        videoView.frame = root.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(videoView)
        view = root

        let overlay = UIHostingController(rootView: EngineOverlay(model: model, ui: ui))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        addChild(overlay)
        overlay.view.frame = root.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(overlay.view)
        overlay.didMove(toParent: self)

        for (dir, action) in [(UISwipeGestureRecognizer.Direction.left, #selector(swipeLeft)), (.right, #selector(swipeRight)),
                              (.down, #selector(swipeDown)), (.up, #selector(swipeUp))] {
            let g = UISwipeGestureRecognizer(target: self, action: action)
            g.direction = dir
            root.addGestureRecognizer(g)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.player.drawable = videoView
        Task { await model.start(); reveal() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate(); updateFocusIfNeeded()
        becomeFirstResponder()
    }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: Remote buttons

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            switch p.type {
            case .select: onSelect(); handled = true
            case .playPause: model.togglePlay(); reveal(); handled = true
            case .menu: onMenu(); handled = true
            case .leftArrow: swipeLeft(); handled = true
            case .rightArrow: swipeRight(); handled = true
            case .downArrow: swipeDown(); handled = true
            case .upArrow: swipeUp(); handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    // Swallow the matching "ended" events so tvOS doesn't also act on them (Menu would leave the app).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let ours: Set<UIPress.PressType> = [.select, .playPause, .menu, .leftArrow, .rightArrow, .upArrow, .downArrow]
        if !presses.contains(where: { ours.contains($0.type) }) { super.pressesEnded(presses, with: event) }
    }

    private func onSelect() {
        if let seg = model.activeSkip { model.seek(to: seg.end) }
        else if ui.showControls || !model.isPlaying { model.togglePlay() }
        reveal()
    }
    private func onMenu() {
        if ui.showControls && model.isPlaying { hideTask?.cancel(); ui.showControls = false }
        else { close() }
    }
    @objc private func swipeLeft() { model.skip(by: -Double(PlaybackPrefs.skipBack)); reveal() }
    @objc private func swipeRight() { model.skip(by: Double(PlaybackPrefs.skipForward)); reveal() }
    @objc private func swipeUp() { reveal() }
    @objc private func swipeDown() { showTracks() }

    private func showTracks() {
        guard !showingTracks, presentedViewController == nil else { return }
        showingTracks = true
        hideTask?.cancel(); ui.showControls = false
        var host: UIHostingController<TVEngineTracks>?
        let sheet = UIHostingController(rootView: TVEngineTracks(model: model, close: { [weak self] in
            host?.dismiss(animated: true) { self?.showingTracks = false; self?.setNeedsFocusUpdate() }
        }))
        host = sheet
        sheet.modalPresentationStyle = .overFullScreen
        sheet.view.backgroundColor = .clear
        present(sheet, animated: true)
    }

    private func reveal() {
        ui.showControls = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.model.isPlaying else { return }
            self.ui.showControls = false
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        hideTask?.cancel()
        let m = model
        Task { await m.stop() }
        dismiss(animated: true) { AppRouter.shared.playerClosedAt = Date() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed && !closing {
            closing = true
            let m = model
            Task { await m.stop() }
            AppRouter.shared.playerClosedAt = Date()
        }
    }

    /// Opens the engine over whatever is on screen.
    @MainActor static func present(request: PlaybackRequest, client: JellyfinClient?) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
        else { return }
        while let p = top.presentedViewController { top = p }
        top.present(TVEngineViewController(request: request, client: client), animated: true)
    }
}

/// The picture-on-top part: title, progress bar, Skip Intro. Purely visual — the remote is handled above.
private struct EngineOverlay: View {
    let model: EnginePlayerModel
    let ui: EngineUIState

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        let m = model
        ZStack {
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
            }}.padding(.trailing, 80).padding(.bottom, ui.showControls ? 190 : 80)
        }
        if ui.showControls || !m.isPlaying {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: ui.showControls)
    }
}

/// Audio and subtitle choices for the engine.
private struct TVEngineTracks: View {
    let model: EnginePlayerModel
    var close: () -> Void
    private func dismiss() { close() }
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
        .background(Color.black.opacity(0.85).ignoresSafeArea())
        .onExitCommand { close() }
    }
}
