import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandlers: [String: () -> Void] = [:]

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Movie playback audio session: keeps playing with the silent switch on, enables
        // multichannel / Dolby Atmos output to AirPods, AirPlay and HDMI.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback, options: [])
        try? audio.setSupportsMultichannelContent(true)

        // Bigger image cache so posters don't reload constantly.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        #if canImport(GoogleCast)
        Task { @MainActor in CastManager.shared.setUp() }
        #endif
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppDelegate.backgroundCompletionHandlers[identifier] = completionHandler
        _ = DownloadManager.shared // re-attach to the background session
    }
}

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()
    @State private var downloads = DownloadManager.shared

    init() { EngineGuard.checkLastRun() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(downloads)
                .environment(AudioPlayer.shared)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter.shared
    @State private var socket = SessionSocket.shared
    @State private var showProfiles = false
    @State private var askedThisLaunch = false
    @AppStorage("prism.askWhoIsWatching") private var askOnLaunch = true

    var body: some View {
        Group {
            if let client = app.client {
                MainTabView()
                    .task(id: client.baseURL) {
                        await CrashReporter.shared.upload(baseURL: client.baseURL, authorization: client.authorizationHeader)
                    }
                    .id(app.session?.key)   // switching account rebuilds every screen
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: app.client != nil)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.scheduleRouteCheck()
                if let c = app.client { Task { await socket.connect(c) } }
            }
        }
        .task(id: app.client.map { ObjectIdentifier($0) }) {
            if let c = app.client {
                await ServerDefaults.apply(app: app)
                await socket.connect(c)
            } else { socket.disconnect() }
        }
        .overlay(alignment: .top) {
            if let notice = socket.notice {
                NoticeBanner(notice: notice) { withAnimation { socket.notice = nil } }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(12))
                        withAnimation { if socket.notice?.id == notice.id { socket.notice = nil } }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: socket.notice)
        .fullScreenCover(isPresented: $showProfiles) { ProfilePickerView() }
        .onChange(of: router.showProfiles) { _, v in if v { router.showProfiles = false; showProfiles = true } }
        .onAppear {
            guard !askedThisLaunch else { return }
            askedThisLaunch = true
            if askOnLaunch, app.accounts.count > 1, app.client != nil, router.pending == nil { showProfiles = true }
        }
        // Siri or Watch Together started a video.
        .fullScreenCover(item: $router.playRequest) { PlayerScreen(request: $0) }
        // The Continue Watching widget opens huefin://play/<id>.
        .onOpenURL { url in if let a = AppRouter.action(for: url) { router.pending = a } }
        .task(id: router.pending) {
            guard let action = router.pending, app.client != nil else { return }
            router.pending = nil
            await router.perform(action, app: app)
        }
        .onChange(of: app.client != nil) { _, signedIn in
            if signedIn, let action = router.pending {
                router.pending = nil
                Task { await router.perform(action, app: app) }
            }
        }
    }
}

struct MainTabView: View {
    enum TabID: Hashable { case home, library, live, downloads, search }
    @State private var selection: TabID = .home

    /// The tab bar takes the color of the section you're in.
    private var hue: Color {
        switch selection {
        case .home: return Theme.home
        case .library: return Theme.library
        case .live: return Theme.live
        case .downloads: return Theme.downloads
        case .search: return Theme.search
        }
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            // Tab bar on iPhone; on iPad it can expand into a sidebar.
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house.fill", value: TabID.home) {
                    NavigationStack { HomeView() }.withMiniPlayer().sectionHue(Theme.home)
                }
                Tab("Library", systemImage: "square.grid.2x2.fill", value: TabID.library) {
                    NavigationStack { LibrariesView() }.withMiniPlayer().sectionHue(Theme.library)
                }
                Tab("Live TV", systemImage: "tv", value: TabID.live) {
                    NavigationStack { LiveTVView() }.withMiniPlayer().sectionHue(Theme.live)
                }
                Tab("Downloads", systemImage: "arrow.down.circle.fill", value: TabID.downloads) {
                    NavigationStack { DownloadsView() }.withMiniPlayer().sectionHue(Theme.downloads)
                }
                Tab(value: TabID.search, role: .search) {
                    NavigationStack { SearchView() }.withMiniPlayer().sectionHue(Theme.search)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tint(hue)
            .withNowPlaying()
        } else {
            TabView(selection: $selection) {
                NavigationStack { HomeView() }.withMiniPlayer().sectionHue(Theme.home)
                    .tabItem { Label("Home", systemImage: "house.fill") }.tag(TabID.home)
                NavigationStack { LibrariesView() }.withMiniPlayer().sectionHue(Theme.library)
                    .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }.tag(TabID.library)
                NavigationStack { LiveTVView() }.withMiniPlayer().sectionHue(Theme.live)
                    .tabItem { Label("Live TV", systemImage: "tv") }.tag(TabID.live)
                NavigationStack { DownloadsView() }.withMiniPlayer().sectionHue(Theme.downloads)
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }.tag(TabID.downloads)
                NavigationStack { SearchView() }.withMiniPlayer().sectionHue(Theme.search)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(TabID.search)
            }
            .tint(hue)
            .withNowPlaying()
        }
    }
}

/// Your account bubble: tap for Settings, long-press to switch user or server.
struct AccountButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationLink { SettingsView() } label: {
            Text(String(app.session?.userName.prefix(1) ?? "?").uppercased())
                .font(.headline.weight(.heavy)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.gradient))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 6)
        }
        .contextMenu {
            Button { AppRouter.shared.showProfiles = true } label: { Label("Who's watching?", systemImage: "person.2.crop.square.stack") }
            ForEach(app.accounts, id: \.key) { account in
                Button { app.switchTo(account) } label: {
                    Label("\(account.userName) · \(account.serverName ?? "Jellyfin")",
                          systemImage: account.key == app.session?.key ? "checkmark.circle.fill" : "person.crop.circle")
                }
            }
        }
        .accessibilityLabel("Account and settings")
    }
}
