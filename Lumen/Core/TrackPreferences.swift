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

/// Audio and subtitle choices remembered per show: pick Japanese audio + English subtitles once,
/// and every other episode of that show starts the same way (like Infuse and Netflix).
struct ShowTrackChoice: Codable, Equatable {
    struct Pick: Codable, Equatable {
        var name: String?
        var language: String?
        var forced: Bool = false
        var off: Bool = false
    }
    var audio: Pick?
    var subtitle: Pick?

    private static func key(_ seriesId: String) -> String { "huefin.showTracks.\(seriesId)" }

    static func load(seriesId: String?) -> ShowTrackChoice? {
        guard let seriesId, let data = UserDefaults.standard.data(forKey: key(seriesId)) else { return nil }
        return try? JSONDecoder().decode(ShowTrackChoice.self, from: data)
    }

    /// Saves one side (audio or subtitle) of the choice, keeping the other.
    static func remember(seriesId: String?, audio: Pick? = nil, subtitle: Pick? = nil) {
        guard let seriesId, audio != nil || subtitle != nil else { return }
        var c = load(seriesId: seriesId) ?? ShowTrackChoice()
        if let audio { c.audio = audio }
        if let subtitle { c.subtitle = subtitle }
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key(seriesId)) }
    }

    /// Server names carry extras that differ between episodes ("- Default", "- External").
    static func normalized(_ name: String?) -> String {
        var n = (name ?? "").lowercased()
        for junk in [" - default", " - external", " - forced", "default", "external"] { n = n.replacingOccurrences(of: junk, with: "") }
        return n.trimmingCharacters(in: .whitespaces)
    }

    static func pick(of stream: MediaStream) -> Pick {
        Pick(name: stream.displayTitle ?? stream.title, language: stream.language, forced: stream.isForced == true)
    }

    /// The stream index in this file that best matches a remembered pick.
    static func match(_ pick: Pick, in streams: [MediaStream]) -> Int? {
        let want = normalized(pick.name)
        if !want.isEmpty, let s = streams.first(where: { normalized($0.displayTitle ?? $0.title) == want }) { return s.index }
        guard let lang = pick.language, !lang.isEmpty else { return nil }
        let same = streams.filter { s in
            guard let l = s.language?.lowercased() else { return false }
            return l == lang.lowercased() || Languages.matches(l, lang.lowercased()) || Languages.matches(lang.lowercased(), l)
        }
        return (same.first { ($0.isForced == true) == pick.forced } ?? same.first)?.index
    }
}

extension TrackPreferences {
    /// Like choose(for:), but the show's remembered choice wins when there is one.
    func choose(for source: MediaSource, seriesId: String?) -> (audio: Int?, subtitle: Int) {
        var choice = choose(for: source)
        guard let memory = ShowTrackChoice.load(seriesId: seriesId) else { return choice }
        if let a = memory.audio, let idx = ShowTrackChoice.match(a, in: source.audioStreams) {
            choice.audio = idx == source.defaultAudioStreamIndex ? nil : idx
        }
        if let s = memory.subtitle {
            if s.off { choice.subtitle = -1 }
            else if let idx = ShowTrackChoice.match(s, in: source.subtitleStreams) { choice.subtitle = idx }
        }
        return choice
    }
}
