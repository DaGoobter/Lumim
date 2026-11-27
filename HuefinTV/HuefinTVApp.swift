import SwiftUI
import AVFoundation

@main
struct HuefinTVApp: App {
    @State private var app = AppState()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(app)
                .environment(AudioPlayer.shared)
                .preferredColorScheme(.dark)
                // Continue Watching on the Top Shelf opens huefin://play/<id>.
                .onOpenURL { url in Task { await AppRouter.shared.open(url, client: app.client) } }
        }
    }
}

struct TVRoot: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter.shared
    @State private var socket = SessionSocket.shared
    @State private var showProfiles = false
    @State private var asked = false
    @AppStorage("prism.askWhoIsWatching") private var askOnLaunch = true
    @State private var appleRequest: PlaybackRequest?

    private func route(_ req: PlaybackRequest) async {
        AudioPlayer.shared.pause()
        // Watch Together needs Apple's player.
        if SyncPlayManager.shared.groupId == nil,
           await EngineDecider.useEngine(for: req, client: app.client, maxBitrate: app.playbackBitrate) {
            TVEngineViewController.present(request: req, client: app.client)
        } else {
            appleRequest = req
        }
    }

    var body: some View {
        Group {
            if app.client != nil { TVTabs().id(app.session?.key) } else { TVLoginView() }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: app.client.map { ObjectIdentifier($0) }) {
            if let c = app.client {
                await ServerDefaults.apply(app: app)
                await socket.connect(c)
            } else { socket.disconnect() }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { app.scheduleRouteCheck() } }
        .onAppear {
            guard !asked else { return }
            asked = true
            if askOnLaunch, app.accounts.count > 1, app.client != nil { showProfiles = true }
        }
        .fullScreenCover(isPresented: $showProfiles) { TVProfilePicker() }
        .fullScreenCover(item: $appleRequest, onDismiss: { router.playerClosedAt = Date() }) { TVApplePlayerScreen(request: $0) }
        // Every play request lands here: Apple's player for files the Apple TV plays natively,
        // the Huefin Engine (a UIKit screen, so the Siri Remote always works) for everything else.
        .onChange(of: router.playRequest?.id) { _, id in
            guard id != nil, let req = router.playRequest else { return }
            router.playRequest = nil
            Task { await route(req) }
        }
        .overlay(alignment: .top) {
            if let n = socket.notice {
                HStack(spacing: 20) {
                    Image(systemName: "bell.fill").font(.title2).foregroundStyle(Theme.red)
                    VStack(alignment: .leading) { Text(n.header).font(.headline); Text(n.text) }
                }
                .padding(30).background(Theme.card, in: RoundedRectangle(cornerRadius: 26)).padding(.top, 40)
                .task(id: n.id) { try? await Task.sleep(for: .seconds(10)); if socket.notice?.id == n.id { socket.notice = nil } }
            }
        }
    }
}

/// The tabs across the top of the screen, like Apple's own apps.
struct TVTabs: View {
    @Environment(AppState.self) private var app
    @State private var tab = 0
    @State private var music: BaseItem?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TVHomeView() }.tabItem { Text("Home") }.tag(0)
            NavigationStack { TVLibrariesView() }.tabItem { Text("Library") }.tag(1)
            NavigationStack { TVLiveView() }.tabItem { Text("Live TV") }.tag(2)
            NavigationStack { TVMusicView() }.tabItem { Text("Music") }.tag(3)
            NavigationStack { TVRequestsView() }.tabItem { Text("Requests") }.tag(6)
            NavigationStack { TVSearchView() }.tabItem { Image(systemName: "magnifyingglass") }.tag(4)
            NavigationStack { TVSettingsView() }.tabItem { Image(systemName: "gearshape") }.tag(5)
        }
    }
}
