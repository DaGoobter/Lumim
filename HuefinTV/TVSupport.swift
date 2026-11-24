import SwiftUI
import AVFoundation

// Pieces the shared iPhone code expects that work differently on Apple TV.

enum Theme {
    // Huefin palette: six hues on a deep, warm night. Each part of the app owns one hue.
    static let red = Color(red: 1.0, green: 0.30, blue: 0.43)        // #FF4D6D
    static let orange = Color(red: 1.0, green: 0.65, blue: 0.17)     // #FFA62B
    static let yellow = Color(red: 1.0, green: 0.89, blue: 0.36)     // #FFE45C
    static let green = Color(red: 0.24, green: 0.94, blue: 0.63)     // #3EF0A0
    static let blue = Color(red: 0.24, green: 0.66, blue: 1.0)       // #3DA9FF
    static let violet = Color(red: 0.61, green: 0.36, blue: 1.0)     // #9B5CFF

    static let accent = red                                             // default when no section hue applies
    static let accent2 = red
    static let midnight = Color(red: 0.098, green: 0.090, blue: 0.141) // #191724, raised surfaces
    static let background = Color(red: 0.055, green: 0.051, blue: 0.078) // #0E0D14, warm night
    static let card = Color(red: 0.098, green: 0.090, blue: 0.141)      // #191724
    static let ink = Color(red: 0.078, green: 0.067, blue: 0.122)       // #14111F, text on bright hues
    static let paper = Color(red: 1.0, green: 0.973, blue: 0.933)       // #FFF8EE, the light button
    static let hairline = Color.white.opacity(0.09)

    /// Each section's hue.
    static let home = red, library = blue, live = orange, downloads = green, search = violet

    /// The full rainbow: progress, highlights, the brand mark.
    static let spectrum = LinearGradient(colors: [red, orange, yellow, green, blue, violet],
                                         startPoint: .leading, endPoint: .trailing)
    /// Cool side of the spectrum: fills that carry white text stay readable.
    static let gradient = LinearGradient(colors: [blue, violet, red],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Something to play full screen.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let item: BaseItem
    let startTicks: Int64
    var localDownload: DownloadRecord? = nil
    var mediaSourceId: String? = nil
}

/// Opens the player from anywhere (Watch Together, Continue Watching on the Top Shelf…).
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var playRequest: PlaybackRequest?
    /// Set whenever a player closes, so Home and the detail pages refresh your progress.
    var playerClosedAt: Date?
    var showProfiles = false
    private init() {}
}

/// Apple TV keeps no downloads (tvOS can clear app storage at any time); this stands in for the phone's manager.
struct DownloadRecord: Codable, Hashable {
    let itemId: String
    var posterURL: URL? { nil }
    var localURL: URL? { nil }
}

@MainActor
final class DownloadManager {
    static let shared = DownloadManager()
    private(set) var records: [String: DownloadRecord] = [:]
    func attach(client: JellyfinClient) {}
    func localFile(for itemId: String) -> URL? { nil }
    func recordOfflineProgress(_ itemId: String, ticks: Int64) {}
}

extension MediaStream {
    /// Picture-based subtitles can't be sent as text; the server has to burn them into the video.
    var isImageSubtitle: Bool {
        ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle"]
            .contains((codec ?? "").lowercased())
    }
}
