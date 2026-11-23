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
