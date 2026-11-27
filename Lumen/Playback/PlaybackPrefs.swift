import Foundation

/// Player preferences (Settings → Playback). Also used as server-pushed defaults.
enum PlaybackPrefs {
    static let keys = (
        autoIntro: "prism.autoSkipIntro", autoRecap: "prism.autoSkipRecap",
        autoCredits: "prism.autoSkipCredits", delay: "prism.autoSkipDelay",
        back: "prism.skipBack", forward: "prism.skipForward", engine: "prism.engine",
        boost: "prism.volumeBoost"
    )
    private static var d: UserDefaults { .standard }

    static var autoSkipIntro: Bool { d.bool(forKey: keys.autoIntro) }
    static var autoSkipRecap: Bool { d.bool(forKey: keys.autoRecap) }
    /// Credits: jump straight to the next episode.
    static var autoSkipCredits: Bool { d.bool(forKey: keys.autoCredits) }
    /// Seconds to wait (with a cancel button) before skipping automatically.
    static var autoSkipDelay: Int { d.object(forKey: keys.delay) == nil ? 3 : d.integer(forKey: keys.delay) }
    static var skipBack: Int { let v = d.integer(forKey: keys.back); return [5, 10, 15, 30].contains(v) ? v : 10 }
    static var skipForward: Int { let v = d.integer(forKey: keys.forward); return [5, 10, 15, 30].contains(v) ? v : 10 }
}

/// How subtitles look (Settings → Subtitles). Used wherever Huefin draws text subtitles itself.
enum SubtitleStyle {
    static let keys = (size: "huefin.sub.size", color: "huefin.sub.color", background: "huefin.sub.background", position: "huefin.sub.position")
    static let sizes: [(id: String, name: String, scale: Double)] = [("small", "Small", 0.78), ("medium", "Medium", 1), ("large", "Large", 1.3), ("huge", "Extra large", 1.65)]
    static let colors: [(id: String, name: String)] = [("white", "White"), ("yellow", "Yellow"), ("cyan", "Light blue")]
    static let backgrounds: [(id: String, name: String)] = [("shadow", "Outline"), ("box", "Dark box"), ("none", "None")]
    static let positions: [(id: String, name: String, lift: Double)] = [("bottom", "Bottom", 0.07), ("raised", "Raised", 0.16)]
    private static var d: UserDefaults { .standard }
    static var scale: Double { sizes.first { $0.id == (d.string(forKey: keys.size) ?? "medium") }?.scale ?? 1 }
    static var color: String { d.string(forKey: keys.color) ?? "white" }
    static var background: String { d.string(forKey: keys.background) ?? "shadow" }
    static var lift: Double { positions.first { $0.id == (d.string(forKey: keys.position) ?? "bottom") }?.lift ?? 0.07 }
}
