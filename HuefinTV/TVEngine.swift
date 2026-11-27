import SwiftUI
import UIKit

/// On-screen state for the engine's controls.
@MainActor @Observable
final class EngineUIState {
    var showControls = true
    /// Which small button next to the progress bar is highlighted (nil = the progress bar itself).
    var button: Int?
    /// Which button's menu is open, and the highlighted row in it.
    var menu: Int?
    var row = 0
}

/// The small buttons next to the progress bar, like Apple's own player.
enum EngineMenus {
    static let buttons: [(title: String, symbol: String)] = [("Subtitles", "captions.bubble"), ("Audio", "speaker.wave.2"),
                                                             ("Speed", "gauge.with.dots.needle.67percent"), ("Subtitle timing", "timer")]
    static let timingSteps: [Double] = [-0.5, -0.1, 0, 0.1, 0.5]
    static func timingLabel(_ d: Double) -> String {
        d == 0 ? "in sync" : String(format: "%@%.1f s %@", d > 0 ? "+" : "−", abs(d), d > 0 ? "later" : "earlier")
    }
    /// The heading of a pop-up (the timing one shows the current setting).
    @MainActor static func title(_ menu: Int, _ m: EnginePlayerModel) -> String {
        menu == 3 ? "Subtitle timing · \(timingLabel(m.subtitleDelay))" : buttons[menu].title
    }
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @MainActor static func options(_ menu: Int, _ m: EnginePlayerModel) -> [(name: String, on: Bool)] {
        switch menu {
        case 0: return m.subtitleTracks.map { ($0.name, $0.index == m.subtitleTrack) }
        case 1: return m.audioTracks.map { ($0.name, $0.index == m.audioTrack) }
        case 2: return speeds.map { ($0 == 1 ? "Normal" : String(format: "%gx", $0), $0 == m.speed) }
        default: return timingSteps.map { ($0 == 0 ? "Reset" : String(format: "%@%.1f s", $0 > 0 ? "+" : "−", abs($0)), false) }
        }
    }
    @MainActor static func choose(_ menu: Int, _ row: Int, _ m: EnginePlayerModel) {
        switch menu {
        case 0: if m.subtitleTracks.indices.contains(row) { m.setSubtitle(m.subtitleTracks[row].index) }
        case 1: if m.audioTracks.indices.contains(row) { m.setAudio(m.audioTracks[row].index) }
        case 2: if speeds.indices.contains(row) { m.setSpeed(speeds[row]) }
        default:
            // Subtitles too early: +. Too late: −.
            if timingSteps.indices.contains(row) { m.setSubtitleDelay(timingSteps[row] == 0 ? 0 : m.subtitleDelay + timingSteps[row]) }
        }
    }
}

/// The Huefin Engine on Apple TV: plays MKV and other files straight from the original, so the server
/// doesn't repackage anything and sound stays perfectly in sync.
///
/// It is a plain UIKit screen (not SwiftUI) so every Siri Remote click, swipe and button press reaches it.
/// Remote: click or ▶︎❚❚ = play/pause (or Skip Intro when offered), swipe or press ◀︎ ▶︎ = skip,
/// swipe up = show controls, swipe down = the Subtitles / Audio / Speed buttons, Menu = back out, then exit.
final class TVEngineViewController: UIViewController {
    private let model: EnginePlayerModel
    private let ui = EngineUIState()
    private let videoView = UIView()
    private var hideTask: Task<Void, Never>?
    private var closing = false

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
        let wrapper = UIView(frame: root.bounds)
        wrapper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wrapper.isUserInteractionEnabled = false
        videoView.frame = wrapper.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wrapper.addSubview(videoView)
        root.addSubview(wrapper)
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
        attachCore()
        model.onCoreChange = { [weak self] in self?.attachCore() }
        Task { await model.start(); reveal() }
    }

    /// Puts the current core's picture on screen (again, if the engine swapped cores).
    private func attachCore() {
        videoView.subviews.forEach { $0.removeFromSuperview() }
        let surface = model.player.videoView
        surface.frame = videoView.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.addSubview(surface)
        // Switch the TV to the video's HDR / Dolby Vision mode and frame rate (Match Content), holding the picture until it has.
        model.player.onVideoReconfig = { [weak self] in self?.matchDisplay() }
    }

    private var matchedGamma: String?
    private func matchDisplay() {
        let gamma = model.player.displaySignature
        guard gamma != matchedGamma, model.player.matchDisplay(in: view.window) else { return }
        matchedGamma = gamma
        let wasPaused = model.player.isPaused
        model.player.pause()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<40 {   // a TV mode switch usually takes 1–3 seconds
                guard let self, self.view.window?.avDisplayManager.isDisplayModeSwitchInProgress == true else { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if !wasPaused { self?.model.player.play() }
        }
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
        if let menu = ui.menu {
            EngineMenus.choose(menu, ui.row, model)
            if menu != 3 { ui.menu = nil }   // timing stays open so you can keep nudging
            reveal(); return
        }
        if let b = ui.button, ui.showControls {
            ui.menu = b
            ui.row = b == 3 ? 3 : (EngineMenus.options(b, model).firstIndex(where: \.on) ?? 0)
            hideTask?.cancel(); return
        }
        if let seg = model.activeSkip { model.seek(to: seg.end) }
        else if ui.showControls || !model.isPlaying { model.togglePlay() }
        reveal()
    }
    private func onMenu() {
        if ui.menu != nil { ui.menu = nil; reveal() }
        else if ui.button != nil { ui.button = nil; reveal() }
        else if ui.showControls && model.isPlaying { hideTask?.cancel(); ui.showControls = false }
        else { close() }
    }
    @objc private func swipeLeft() {
        if ui.menu != nil { return }
        if let b = ui.button, ui.showControls { ui.button = max(0, b - 1); reveal(); return }
        model.skip(by: -Double(PlaybackPrefs.skipBack)); reveal()
    }
    @objc private func swipeRight() {
        if ui.menu != nil { return }
        if let b = ui.button, ui.showControls { ui.button = min(EngineMenus.buttons.count - 1, b + 1); reveal(); return }
        model.skip(by: Double(PlaybackPrefs.skipForward)); reveal()
    }
    @objc private func swipeUp() {
        if ui.menu != nil { ui.row = max(0, ui.row - 1); return }
        ui.button = nil
        reveal()
    }
    @objc private func swipeDown() {
        if let menu = ui.menu { ui.row = min(EngineMenus.options(menu, model).count - 1, ui.row + 1); return }
        if ui.showControls { ui.button = ui.button ?? 0 }
        reveal()
    }

    private func reveal() {
        ui.showControls = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.model.isPlaying, self.ui.menu == nil else { return }
            self.ui.button = nil
            self.ui.showControls = false
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        hideTask?.cancel()
        let m = model
        MPVCore.resetDisplay(in: view.window)
        Task { await m.stop() }
        dismiss(animated: true) { AppRouter.shared.playerClosedAt = Date() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed && !closing {
            closing = true
            let m = model
            MPVCore.resetDisplay(in: view.window ?? presentingViewController?.view.window)
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
        EngineSubtitleView(subtitle: m.subtitle, aspect: m.player.videoAspect)
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
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.item.type == "Episode" ? (m.item.name ?? "") : m.item.displayTitle).font(.title3.bold())
                        if let e = m.item.episodeLabel { Text("\(m.item.seriesName ?? "") · \(e)").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        ForEach(EngineMenus.buttons.indices, id: \.self) { i in
                            let on = ui.button == i
                            Image(systemName: EngineMenus.buttons[i].symbol)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(on ? Color.black : Color.white)
                                .frame(width: 64, height: 64)
                                .background(on ? Color.white : Color.white.opacity(0.18), in: Circle())
                                .scaleEffect(on ? 1.12 : 1)
                                .overlay(alignment: .bottomTrailing) {
                                    if ui.menu == i { menuCard(i, m).fixedSize().offset(y: -84) }
                                }
                        }
                    }
                }
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
                    if let b = ui.button, ui.menu == nil {
                        Text(EngineMenus.buttons[b].title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
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
        .animation(.easeOut(duration: 0.15), value: ui.button)
        .animation(.easeOut(duration: 0.15), value: ui.menu)
    }

    /// The little pop-up list above a button. Shows up to 8 rows around the highlighted one.
    private func menuCard(_ menu: Int, _ m: EnginePlayerModel) -> some View {
        let opts = EngineMenus.options(menu, m)
        let first = max(0, min(ui.row - 3, opts.count - 8))
        let rows = Array(opts.indices).dropFirst(first).prefix(8)
        return VStack(alignment: .leading, spacing: 2) {
            Text(EngineMenus.title(menu, m)).font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 4)
            if opts.isEmpty { Text("None available").font(.callout).padding(.horizontal, 18).padding(.vertical, 8) }
            ForEach(Array(rows), id: \.self) { r in
                let hi = r == ui.row
                HStack(spacing: 12) {
                    Image(systemName: "checkmark").opacity(opts[r].on ? 1 : 0)
                    Text(opts[r].name).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(hi ? Color.black : Color.white)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .frame(minWidth: 320, maxWidth: 520, alignment: .leading)
                .background(hi ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            }
            if opts.count > 8 { Text("\(ui.row + 1) of \(opts.count)").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 4) }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
}

