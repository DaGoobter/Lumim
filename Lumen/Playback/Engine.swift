import Foundation

/// Decides who plays a video: Apple's player (best for HDR, Dolby Vision, AirPlay, PiP) or the
/// Huefin Engine (mpv + libplacebo), which plays nearly any file as-is with HDR and Dolby Vision shown as intended.
enum PlaybackEngine: String, CaseIterable, Identifiable {
    case auto, apple, prism
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .apple: return "Apple player only"
        case .prism: return "Huefin Engine always"
        }
    }
    static var current: PlaybackEngine {
        PlaybackEngine(rawValue: UserDefaults.standard.string(forKey: PlaybackPrefs.keys.engine) ?? "") ?? .auto
    }
}

struct Playability: Equatable {
    enum Kind: Equatable { case original, repackaged, prismEngine, converted, unknown }
    let kind: Kind
    let detail: String
    /// The server's reasons it couldn't send the original.
    var reasons: [String] = []
    /// The Huefin Engine's native core can play this file itself (real Dolby Vision, Atmos, PiP, no server work).
    var nativeOK = false

    var title: String {
        switch kind {
        case .original: return "Plays original"
        case .repackaged: return "Plays original quality"
        case .prismEngine: return "Plays original with Huefin Engine"
        case .converted: return "Server converts"
        case .unknown: return "Checking…"
        }
    }
    var symbol: String {
        switch kind {
        case .original, .repackaged: return "checkmark.seal.fill"
        case .prismEngine: return "sparkles"
        case .converted: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum EngineDecider {
    /// Reasons the Huefin Engine can fix by playing the file itself. Bitrate limits need the server.
    static let engineFixable: Set<String> = [
        "ContainerNotSupported", "VideoCodecNotSupported", "AudioCodecNotSupported",
        "SubtitleCodecNotSupported", "VideoProfileNotSupported", "VideoLevelNotSupported",
        "AudioChannelsNotSupported", "AudioProfileNotSupported", "VideoRangeTypeNotSupported",
        "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported", "VideoCodecTagNotSupported",
        "AudioSampleRateNotSupported", "AudioBitDepthNotSupported", "UnknownVideoStreamInfo",
        "UnknownAudioStreamInfo", "VideoFramerateNotSupported", "VideoBitDepthNotSupported",
        "RefFramesNotSupported", "VideoResolutionNotSupported",
    ]

    static func reasons(_ src: MediaSource) -> [String] {
        guard let t = src.transcodingUrl,
              let comps = URLComponents(string: "http://x" + (t.hasPrefix("/") ? t : "/" + t)) else { return [] }
        let raw = comps.queryItems?.first { $0.name.lowercased() == "transcodereasons" }?.value ?? ""
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func friendly(_ reason: String) -> String {
        switch reason {
        case "ContainerNotSupported": return "file type"
        case "VideoCodecNotSupported", "VideoCodecTagNotSupported": return "video format"
        case "AudioCodecNotSupported", "AudioProfileNotSupported": return "audio format"
        case "SubtitleCodecNotSupported": return "subtitles"
        case "VideoRangeTypeNotSupported": return "HDR type"
        case "AudioChannelsNotSupported": return "surround channels"
        case "ContainerBitrateExceedsLimit", "VideoBitrateNotSupported", "AudioBitrateNotSupported":
            return "too big for your quality limit"
        case "VideoProfileNotSupported", "VideoLevelNotSupported", "VideoBitDepthNotSupported": return "video profile"
        case "VideoResolutionNotSupported": return "resolution"
        default: return reason.replacingOccurrences(of: "NotSupported", with: "").lowercased()
        }
    }

    /// The server's view of how this phone would play the item, plus whether the Huefin Engine helps.
    static func playability(for item: BaseItem, client: JellyfinClient, maxBitrate: Int,
                            mediaSourceId: String? = nil) async -> Playability {
        guard let info = try? await client.playbackInfo(itemId: item.id, maxBitrate: maxBitrate,
                                                        subtitleStreamIndex: nil, mediaSourceId: mediaSourceId),
              let src = info.mediaSources.first(where: { $0.id == mediaSourceId }) ?? info.mediaSources.first
        else { return Playability(kind: .unknown, detail: "") }
        if let sid = info.playSessionId { Task { await client.stopEncoding(playSessionId: sid) } }
        var native = false
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
        native = NativeCore.canPlay(src) && PlaybackEngine.current != .apple
        #endif
        if src.supportsDirectPlay == true {
            return Playability(kind: .original, detail: "Streams the file untouched.")
        }
        let why = reasons(src)
        if src.supportsDirectStream == true {
            if native {
                return Playability(kind: .prismEngine, detail: "Huefin plays the original file itself, in true Dolby Vision / HDR with the original sound, so the server doesn't repackage it.", nativeOK: true)
            }
            return Playability(kind: .repackaged, detail: "Same picture and sound, just repackaged on the fly (light work for the server).")
        }
        let names = Array(Set(why.map(friendly))).sorted().joined(separator: ", ")
        if !why.isEmpty, why.allSatisfy({ engineFixable.contains($0) }), PlaybackEngine.current != .apple {
            return Playability(kind: .prismEngine,
                               detail: "Apple's player can't handle the \(names), so Huefin plays it with its own engine instead of making the server convert it.",
                               reasons: why, nativeOK: native)
        }
        return Playability(kind: .converted, detail: names.isEmpty ? "The server converts it for this device." : "Because of the \(names).")
    }

    /// Whether to open the Huefin Engine for this request.
    static func useEngine(for request: PlaybackRequest, client: JellyfinClient?, maxBitrate: Int) async -> Bool {
        let mode = PlaybackEngine.current
        if mode == .apple || request.item.isLiveChannel || request.item.isAudio { return false }
        if let local = request.localDownload {
            let ext = local.localURL?.pathExtension.lowercased() ?? ""
            return mode == .prism || !["mp4", "m4v", "mov", "movpkg", ""].contains(ext)
        }
        guard let client else { return false }
        if mode == .prism { return true }
        #if os(iOS)
        // iPhone/iPad: Apple's player on Automatic, so swiping home floats the video in Picture in Picture; the
        // server repackages what Apple can't open directly. The one exception: when the server would have to
        // re-encode the *picture* (Dolby Vision Profile 7, an HDR type or codec Apple can't decode), which would
        // lose HDR / Dolby Vision. Those play in the Huefin Engine so they look as intended.
        let p = await playability(for: request.item, client: client, maxBitrate: maxBitrate,
                                  mediaSourceId: request.mediaSourceId)
        let picture: Set<String> = ["VideoRangeTypeNotSupported", "VideoCodecNotSupported", "VideoCodecTagNotSupported",
                                    "VideoProfileNotSupported", "VideoLevelNotSupported", "VideoBitDepthNotSupported",
                                    "VideoResolutionNotSupported", "UnknownVideoStreamInfo", "InterlacedVideoNotSupported"]
        // The native core plays the original itself with real Picture in Picture, so it can take everything it handles.
        return p.kind == .prismEngine && (p.nativeOK || !picture.isDisjoint(with: p.reasons))
        #else
        let p = await playability(for: request.item, client: client, maxBitrate: maxBitrate,
                                  mediaSourceId: request.mediaSourceId)
        return p.kind == .prismEngine
        #endif
    }
}
