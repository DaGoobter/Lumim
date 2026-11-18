import Foundation

enum SubtitleMode: String, CaseIterable, Identifiable, Codable {
    case off, forced, always, foreignAudio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .forced: return "Forced only"
        case .always: return "Always on"
        case .foreignAudio: return "When audio isn't my language"
        }
    }
}

struct LanguageOption: Hashable {
    /// ISO 639-2 code, as Jellyfin and OpenSubtitles use it.
    let code: String
    let name: String
    let aliases: Set<String>
}

enum Languages {
    static let all: [LanguageOption] = [
        .init(code: "eng", name: "English", aliases: ["en"]),
        .init(code: "spa", name: "Spanish", aliases: ["es"]),
        .init(code: "fre", name: "French", aliases: ["fra", "fr"]),
        .init(code: "ger", name: "German", aliases: ["deu", "de"]),
        .init(code: "ita", name: "Italian", aliases: ["it"]),
        .init(code: "por", name: "Portuguese", aliases: ["pt"]),
        .init(code: "jpn", name: "Japanese", aliases: ["ja"]),
        .init(code: "kor", name: "Korean", aliases: ["ko"]),
        .init(code: "chi", name: "Chinese", aliases: ["zho", "zh"]),
        .init(code: "rus", name: "Russian", aliases: ["ru"]),
        .init(code: "ara", name: "Arabic", aliases: ["ar"]),
        .init(code: "hin", name: "Hindi", aliases: ["hi"]),
        .init(code: "dut", name: "Dutch", aliases: ["nld", "nl"]),
        .init(code: "swe", name: "Swedish", aliases: ["sv"]),
        .init(code: "nor", name: "Norwegian", aliases: ["nob", "nno", "no", "nb"]),
        .init(code: "dan", name: "Danish", aliases: ["da"]),
        .init(code: "fin", name: "Finnish", aliases: ["fi"]),
        .init(code: "pol", name: "Polish", aliases: ["pl"]),
        .init(code: "tur", name: "Turkish", aliases: ["tr"]),
        .init(code: "gre", name: "Greek", aliases: ["ell", "el"]),
        .init(code: "heb", name: "Hebrew", aliases: ["he"]),
        .init(code: "tha", name: "Thai", aliases: ["th"]),
        .init(code: "vie", name: "Vietnamese", aliases: ["vi"]),
        .init(code: "ind", name: "Indonesian", aliases: ["id"]),
        .init(code: "tgl", name: "Tagalog", aliases: ["fil", "tl"]),
    ]

    static func matches(_ streamLanguage: String?, _ code: String) -> Bool {
        guard let lang = streamLanguage?.lowercased(), !lang.isEmpty, !code.isEmpty else { return false }
        if lang == code { return true }
        return all.first { $0.code == code }?.aliases.contains(lang) ?? false
    }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code.uppercased()
    }
}

/// The user's default track choices, applied automatically when playback starts.
struct TrackPreferences: Codable, Equatable {
    /// "" = keep the file's default audio track.
    var audioLanguage: String = ""
    var subtitleLanguage: String = "eng"
    var subtitleMode: SubtitleMode = .forced

    static func load() -> TrackPreferences {
        guard let data = UserDefaults.standard.data(forKey: "lumen.trackPrefs"),
              let prefs = try? JSONDecoder().decode(TrackPreferences.self, from: data) else { return TrackPreferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "lumen.trackPrefs")
        }
    }

    /// Picks tracks for a file. audio nil = file default; subtitle -1 = off.
    /// Picture-based subtitles are never auto-selected: they force a full re-encode and lose Dolby Vision.
    func choose(for source: MediaSource) -> (audio: Int?, subtitle: Int) {
        var audio: Int?
        var audioLang = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }?.language
            ?? source.audioStreams.first?.language

        if !audioLanguage.isEmpty {
            let matching = source.audioStreams.filter { Languages.matches($0.language, audioLanguage) }
            if let best = matching.first(where: { $0.isDefault == true }) ?? matching.first {
                audioLang = best.language
                if best.index != source.defaultAudioStreamIndex { audio = best.index }
            }
        }

        let textSubs = source.subtitleStreams.filter { !$0.isImageSubtitle && Languages.matches($0.language, subtitleLanguage) }
        let forced = textSubs.first { $0.isForced == true }?.index
        let full = textSubs.first { $0.isForced != true }?.index

        let subtitle: Int?
        switch subtitleMode {
        case .off:
            subtitle = nil
        case .forced:
            subtitle = forced
        case .always:
            subtitle = full ?? forced
        case .foreignAudio:
            subtitle = Languages.matches(audioLang, subtitleLanguage) ? forced : (full ?? forced)
        }
        return (audio, subtitle ?? -1)
    }
}
