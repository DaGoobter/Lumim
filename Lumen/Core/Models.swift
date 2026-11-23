import Foundation

// MARK: - JSON decoding

/// Jellyfin returns PascalCase keys ("RunTimeTicks"); this maps them to Swift camelCase ("runTimeTicks").
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension JSONDecoder {
    static let jellyfin: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let last = keys[keys.count - 1]
            if last.intValue != nil { return last }
            let s = last.stringValue
            guard let first = s.first else { return last }
            return AnyKey(stringValue: first.lowercased() + s.dropFirst())
        }
        return decoder
    }()
}

// MARK: - API models

struct PublicSystemInfo: Codable {
    let serverName: String?
    let version: String?
    let id: String?
}

struct SystemInfo: Codable {
    let localAddress: String?
    let id: String?
}

struct UserDto: Codable {
    let id: String
    let name: String
}

struct AuthResult: Codable {
    let user: UserDto
    let accessToken: String
    let serverId: String?
}

struct ItemsResult: Codable {
    let items: [BaseItem]
    let totalRecordCount: Int?
}

struct NameId: Codable, Hashable {
    let name: String?
    let id: String
}

struct ProgramsResult: Codable {
    let items: [ProgramInfo]
}

struct UserItemData: Codable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let playedPercentage: Double?
    let isFavorite: Bool?
    let unplayedItemCount: Int?
}

struct MediaStream: Codable {
    let type: String?
    let index: Int?
    let codec: String?
    let profile: String?
    let displayTitle: String?
    let title: String?
    let language: String?
    let channels: Int?
    let channelLayout: String?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let videoRange: String?
    let videoRangeType: String?
    let dvProfile: Int?
    let audioSpatialFormat: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isExternal: Bool?
}

/// A subtitle found online by the server's subtitle plugin (e.g. OpenSubtitles).
struct RemoteSubtitleInfo: Codable, Identifiable {
    let id: String
    let name: String?
    let providerName: String?
    let format: String?
    let author: String?
    let comment: String?
    let downloadCount: Int?
    let communityRating: Double?
    let threeLetterISOLanguageName: String?
    let isHashMatch: Bool?
    let hearingImpaired: Bool?
    let forced: Bool?
    let machineTranslated: Bool?
    let aiTranslated: Bool?
}

struct MediaSource: Codable {
    let id: String
    let name: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let runTimeTicks: Int64?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let liveStreamId: String?
    let defaultAudioStreamIndex: Int?
    let mediaStreams: [MediaStream]?
}

struct PlaybackInfoResponse: Codable {
    let mediaSources: [MediaSource]
    let playSessionId: String?
    let errorCode: String?
}

struct TranscodingInfo: Codable {
    let audioCodec: String?
    let videoCodec: String?
    let container: String?
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    let hardwareAccelerationType: String?
}

struct SessionInfo: Codable {
    let id: String?
    let deviceId: String?
    let nowPlayingItem: BaseItem?
    let transcodingInfo: TranscodingInfo?
}

/// A guide entry for a live channel.
struct ProgramInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let episodeTitle: String?
    let overview: String?
    let channelId: String?
    let startDate: String?
    let endDate: String?
    let isMovie: Bool?
    let isLive: Bool?

    var start: Date? { startDate.flatMap(parseJellyfinDate) }
    var end: Date? { endDate.flatMap(parseJellyfinDate) }

    func progress(at now: Date = Date()) -> Double? {
        guard let start, let end, end > start else { return nil }
        return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }

    var title: String { [name, episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// Jellyfin dates look like 2026-11-17T19:00:00.0000000Z (7 fractional digits), which ISO8601DateFormatter rejects.
func parseJellyfinDate(_ s: String) -> Date? {
    var trimmed = s
    if let dot = trimmed.firstIndex(of: ".") {
        let tail = trimmed[dot...].drop(while: { $0 == "." || $0.isNumber })
        trimmed = String(trimmed[..<dot]) + tail
    }
    if !trimmed.hasSuffix("Z") && !trimmed.contains("+") && trimmed.filter({ $0 == "-" }).count <= 2 { trimmed += "Z" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: trimmed)
}

struct BaseItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let overview: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let officialRating: String?
    let communityRating: Double?
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let collectionType: String?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let seriesPrimaryImageTag: String?
    let userData: UserItemData?
    let mediaSources: [MediaSource]?
    let genres: [String]?
    // Music / books
    let mediaType: String?
    let parentId: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let artists: [String]?
    let albumPrimaryImageTag: String?
    let artistItems: [NameId]?
    let childCount: Int?
    // Live TV
    let channelNumber: String?
    let currentProgram: ProgramInfo?

    static func == (lhs: BaseItem, rhs: BaseItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Helpers

extension BaseItem {
    var isPlayable: Bool { ["Movie", "Episode", "Video", "MusicVideo", "TvChannel"].contains(type ?? "") }
    var isLiveChannel: Bool { type == "TvChannel" }
    var isAudio: Bool { type == "Audio" || type == "AudioBook" }
    var isAudiobook: Bool { type == "AudioBook" }
    var isBook: Bool { type == "Book" }
    var artistLine: String? { albumArtist ?? artists?.first }
    var isSeries: Bool { type == "Series" }

    /// Keys in ImageTags are lowercased by our decoder ("primary", "logo", "thumb").
    func imageTag(_ kind: String) -> String? {
        imageTags?[kind.lowercased()] ?? imageTags?[kind]
    }

    var displayTitle: String { (type == "Episode" ? seriesName : nil) ?? name ?? "Untitled" }

    var episodeLabel: String? {
        guard type == "Episode" else { return nil }
        let s = parentIndexNumber.map { "S\($0)" } ?? ""
        let e = indexNumber.map { "E\($0)" } ?? ""
        let code = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
        return [code, name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var runtimeText: String? { runTimeTicks.map(formatTicks) }

    var progress: Double? {
        guard let pos = userData?.playbackPositionTicks, let total = runTimeTicks, total > 0, pos > 0 else { return nil }
        return min(1, Double(pos) / Double(total))
    }

    var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }
}

extension MediaSource {
    var videoStream: MediaStream? { mediaStreams?.first { $0.type == "Video" } }
    var audioStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Audio" } ?? [] }
    var subtitleStreams: [MediaStream] { mediaStreams?.filter { $0.type == "Subtitle" } ?? [] }

    var badges: [String] {
        var out: [String] = []
        if let v = videoStream {
            let w = v.width ?? 0, h = v.height ?? 0
            if w >= 3200 || h >= 2000 { out.append("4K") } else if w >= 1900 || h >= 1000 { out.append("HD") }
            let range = v.videoRangeType ?? v.videoRange ?? ""
            if range.contains("DOVI") { out.append("Dolby Vision") }
            else if range.contains("HDR10Plus") { out.append("HDR10+") }
            else if range.contains("HDR10") || range == "HDR" { out.append("HDR10") }
            else if range.contains("HLG") { out.append("HLG") }
        }
        if audioStreams.contains(where: { $0.isAtmos }) { out.append("Atmos") }
        return out
    }
}

extension MediaStream {
    var isAtmos: Bool {
        (profile ?? "").localizedCaseInsensitiveContains("atmos")
            || (displayTitle ?? "").localizedCaseInsensitiveContains("atmos")
            || (audioSpatialFormat ?? "") == "DolbyAtmos"
    }
}

func formatTicks(_ ticks: Int64) -> String {
    let minutes = Int(ticks / 600_000_000)
    let h = minutes / 60, m = minutes % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}


struct MediaSegment: Codable, Hashable {
    let type: String?        // Intro, Outro, Recap, Preview, Commercial
    let startTicks: Int64?
    let endTicks: Int64?

    var start: Double { Double(startTicks ?? 0) / 10_000_000 }
    var end: Double { Double(endTicks ?? 0) / 10_000_000 }
}

struct MediaSegmentsResult: Codable { let items: [MediaSegment] }

struct ChapterMarker: Codable, Hashable {
    let startPositionTicks: Int64?
    let name: String?
    var start: Double { Double(startPositionTicks ?? 0) / 10_000_000 }
}
