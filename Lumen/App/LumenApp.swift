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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(downloads)
                .environment(AudioPlayer.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter.shared

    var body: some View {
        Group {
            if app.client != nil {
                MainTabView()
                    .id(app.session?.key)   // switching account rebuilds every screen
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: app.client != nil)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.scheduleRouteCheck() }
        }
        // Siri or Watch Together started a video.
        .fullScreenCover(item: $router.playRequest) { PlayerScreen(request: $0) }
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
    var body: some View {
        if #available(iOS 18.0, *) {
            // Tab bar on iPhone; on iPad it can expand into a sidebar.
            TabView {
                Tab("Home", systemImage: "house.fill") { NavigationStack { HomeView() }.withMiniPlayer() }
                Tab("Library", systemImage: "square.grid.2x2.fill") { NavigationStack { LibrariesView() }.withMiniPlayer() }
                Tab("Live TV", systemImage: "tv") { NavigationStack { LiveTVView() }.withMiniPlayer() }
                Tab("Downloads", systemImage: "arrow.down.circle.fill") { NavigationStack { DownloadsView() }.withMiniPlayer() }
                Tab(role: .search) { NavigationStack { SearchView() }.withMiniPlayer() }
            }
            .tabViewStyle(.sidebarAdaptable)
            .withNowPlaying()
        } else {
            TabView {
                NavigationStack { HomeView() }.withMiniPlayer()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                NavigationStack { LibrariesView() }.withMiniPlayer()
                    .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                NavigationStack { LiveTVView() }.withMiniPlayer()
                    .tabItem { Label("Live TV", systemImage: "tv") }
                NavigationStack { DownloadsView() }.withMiniPlayer()
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                NavigationStack { SearchView() }.withMiniPlayer()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
            }
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
