import SwiftUI
import AVFoundation
import CoreText

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
    /// Light value for the Huefin look, dark value for Night.
    static func look(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    static let background = look(hex(0xFFF8EE), hex(0x0E0D14))          // paper / warm night
    static let card = look(hex(0xFFFFFF), hex(0x191724))
    static let midnight = card
    static let ink = Color(red: 0.106, green: 0.082, blue: 0.188)        // #1B1530, text on bright hues
    static let paper = Color(red: 1.0, green: 0.973, blue: 0.933)        // #FFF8EE, the light button
    static let hairline = look(hex(0x1B1530, 0.85), UIColor.white.withAlphaComponent(0.09))
    static let outline = look(hex(0x1B1530), .clear)
    static let wash = look(hex(0x1B1530, 0.06), UIColor.white.withAlphaComponent(0.07))

    /// Huefin's display type: Bricolage Grotesque when it's bundled, rounded system type otherwise.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy, relativeTo style: Font.TextStyle = .title) -> Font {
        HuefinFont.available ? .custom(HuefinFont.family, size: size, relativeTo: style).weight(weight)
            : .system(size: size, weight: weight, design: .rounded)
    }

    /// Each section's hue.
    static let home = red, library = blue, live = orange, downloads = green, search = violet

    /// The full rainbow: progress, highlights, the brand mark.
    static let spectrum = LinearGradient(colors: [red, orange, yellow, green, blue, violet],
                                         startPoint: .leading, endPoint: .trailing)
    /// Cool side of the spectrum: fills that carry white text stay readable.
    static let gradient = LinearGradient(colors: [blue, violet, red],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The chosen look: "huefin" (paper, the default) or "night".
enum Appearance {
    static let key = "huefin.appearance"
}

enum HuefinFont {
    static let family = "Bricolage Grotesque"
    static let available: Bool = {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return !UIFont.fontNames(forFamilyName: family).isEmpty
    }()
}

/// Ink outline and hard ink shadow on the Huefin look; nothing extra at night.
struct Sticker: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 16
    var depth: CGFloat = 6
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if scheme == .dark {
            content
        } else {
            content
                .overlay(shape.strokeBorder(Theme.ink, lineWidth: 4))
                .background(shape.fill(Theme.ink).offset(x: depth, y: depth))
        }
    }
}

extension View {
    func sticker(_ radius: CGFloat = 16, depth: CGFloat = 6) -> some View { modifier(Sticker(radius: radius, depth: depth)) }
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

    /// Top Shelf: huefin://play/<id> plays that item.
    func open(_ url: URL, client: JellyfinClient?) async {
        guard url.scheme == "huefin", let id = url.pathComponents.last, id != "/", let client,
              let item = try? await client.item(id) else { return }
        playRequest = PlaybackRequest(item: item, startTicks: item.resumeTicks)
    }
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
