import AppIntents
import SwiftUI
import Observation

/// Things Siri, Shortcuts or Spotlight asked the app to do; RootView carries them out.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    enum Action: Equatable { case resume, channel(String?), dj }
    var pending: Action?
    /// A video to open full screen from anywhere (Siri, Watch Together).
    var playRequest: PlaybackRequest?
    /// Open the "Who's watching?" screen.
    var showProfiles = false
    private init() {}

    func perform(_ action: Action, app: AppState) async {
        guard let client = app.client else { return }
        switch action {
        case .resume:
            if let item = (try? await client.resume())?.first {
                playRequest = PlaybackRequest(item: item, startTicks: item.resumeTicks)
            } else if let next = (try? await client.nextUp())?.first {
                playRequest = PlaybackRequest(item: next, startTicks: next.resumeTicks)
            }
        case .channel(let name):
            guard let channels = try? await client.liveChannels(), !channels.isEmpty else { return }
            let q = (name ?? "").trimmingCharacters(in: .whitespaces)
            let match = q.isEmpty ? channels.first : channels.first(where: {
                ($0.name ?? "").localizedCaseInsensitiveContains(q) || $0.channelNumber == q
            })
            if let match { playRequest = PlaybackRequest(item: match, startTicks: 0) }
        case .dj:
            let music = (try? await client.userViews())?.first { $0.collectionType == "music" }
            await AudioPlayer.shared.play(station: Stations.dj(libraryId: music?.id), client: client)
        }
    }
}

struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Continue the last thing you were watching in Prism.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .resume
        return .result()
    }
}

struct WatchChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Watch Live TV"
    static let description = IntentDescription("Tune to a live TV channel in Prism.")
    static let openAppWhenRun = true

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: String?

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .channel(channel)
        return .result()
    }
}

struct StartDJIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Prism DJ"
    static let description = IntentDescription("Start the Prism DJ radio station.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .dj
        return .result()
    }
}

struct PrismShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeWatchingIntent(), phrases: [
            "Resume watching in \(.applicationName)",
            "Continue watching in \(.applicationName)",
            "Keep watching in \(.applicationName)",
        ], shortTitle: "Resume Watching", systemImageName: "play.circle.fill")
        AppShortcut(intent: WatchChannelIntent(), phrases: [
            "Watch live TV in \(.applicationName)",
            "Turn on live TV in \(.applicationName)",
        ], shortTitle: "Watch Live TV", systemImageName: "tv")
        AppShortcut(intent: StartDJIntent(), phrases: [
            "Start the DJ in \(.applicationName)",
            "Play music in \(.applicationName)",
        ], shortTitle: "Start DJ", systemImageName: "radio.fill")
    }
}
