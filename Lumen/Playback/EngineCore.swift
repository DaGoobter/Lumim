import UIKit

/// How a playback attempt ended.
enum EngineEnd {
    case finished
    case failed(String)
    /// The native engine can't show this file as intended; carry on in mpv from this point (seconds).
    case fallback(Double)
}

struct EngineTrack: Hashable { let id: Int32; let name: String; let selected: Bool }

/// A subtitle the app draws itself, above the picture.
enum EngineSubtitle: Equatable {
    case text(String)
    /// A picture subtitle (Blu-ray PGS, DVD) and where it goes, as a fraction of the video frame.
    case image(CGImage, CGRect)
}

/// One of the Huefin Engine's two cores:
/// - **Native** (Level 4): Huefin reads the file and Apple's own video pipeline shows it, so Dolby Vision is real
///   Dolby Vision, Atmos stays Atmos and Picture in Picture works.
/// - **mpv** (Level 3): plays everything else (and Dolby Vision Profile 7) through libplacebo.
protocol EngineCore: AnyObject {
    var videoView: UIView { get }
    var isReady: Bool { get }
    var engineName: String { get }
    /// Called on the main thread.
    var onPlaybackRestart: (() -> Void)? { get set }
    var onEnd: ((EngineEnd) -> Void)? { get set }
    var onVideoReconfig: (() -> Void)? { get set }

    func load(_ url: URL, start: Double)
    func addSubtitle(_ url: URL, title: String, lang: String?)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
    func destroy()

    var time: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var isPlaying: Bool { get }
    var speed: Double { get set }
    /// 0–200 (100 = normal).
    var volume: Double { get set }

    func tracks(_ type: String) -> [EngineTrack]
    func selectAudio(_ id: Int32)
    func selectSubtitle(_ id: Int32)

    var pictureDescription: String { get }
    /// Subtitles the app must draw (nil when the engine draws them itself).
    var overlaySubtitle: EngineSubtitle? { get }
    /// Subtitle timing: positive shows them later, negative earlier (seconds).
    var subtitleDelay: Double { get set }
    /// The video's shape (width ÷ height).
    var videoAspect: Double { get }

    #if os(tvOS)
    /// Asks the TV for the video's dynamic range and frame rate (Match Content). True if a switch was requested.
    @MainActor func matchDisplay(in window: UIWindow?) -> Bool
    /// Changes when the TV mode the video needs changes.
    var displaySignature: String { get }
    #endif
}

enum EnginePrefs {
    static let nativeKey = "huefin.nativeEngine"
    /// The native core (Level 4) is on unless turned off in Settings.
    static var nativeEnabled: Bool { UserDefaults.standard.object(forKey: nativeKey) as? Bool ?? true }
}
