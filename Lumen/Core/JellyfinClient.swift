import Foundation

enum JellyfinError: LocalizedError {
    case badURL
    case http(Int)
    case noMediaSource

    var errorDescription: String? {
        switch self {
        case .badURL: return "That server address doesn't look right."
        case .http(let code):
            switch code {
            case 401: return "Wrong username or password, or your session expired."
            case 403: return "The server denied access (check this user's permissions)."
            case 404: return "Not found on the server."
            default: return "Server error (HTTP \(code))."
            }
        case .noMediaSource: return "The server didn't return a playable version of this item."
        }
    }
}

/// Thin wrapper over the Jellyfin REST API (targets server 10.9+).
final class JellyfinClient {
    let baseURL: URL
    let deviceName: String
    var accessToken: String?
    var userId: String?
    private let session: URLSession

    static let clientName = "Huefin"
    static let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    static let deviceId: String = {
        let key = "lumen.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    init(baseURL: URL, deviceName: String, token: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        let cleaned = deviceName.unicodeScalars.filter { $0.isASCII && $0 != "\"" && $0 != "," }
        self.deviceName = cleaned.isEmpty ? "iOS" : String(cleaned)
        self.accessToken = token
        self.userId = userId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    var authorizationHeader: String {
        var h = "MediaBrowser Client=\"\(Self.clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(Self.deviceId)\", Version=\"\(Self.version)\""
        if let accessToken { h += ", Token=\"\(accessToken)\"" }
        return h
    }

    // MARK: Request plumbing

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var comps = URLComponents(url: baseURL.appendingPathComponent(trimmed), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { comps.queryItems = items.sorted { $0.name < $1.name } }
        return comps.url!
    }

    @discardableResult
    func send(_ path: String, query: [String: String?] = [:], method: String = "POST", body: Any? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JellyfinError.http(http.statusCode)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        let data = try await send(path, query: query, method: "GET")
        return try JSONDecoder.jellyfin.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, query: [String: String?] = [:], body: Any) async throws -> T {
        let data = try await send(path, query: query, method: "POST", body: body)
        return try JSONDecoder.jellyfin.decode(T.self, from: data)
    }

    // MARK: Connection speed

    /// Downloads `bytes` of throwaway data from the server (Jellyfin's bitrate test) and returns bits per second.
    /// The time includes the round trip, so it errs on the safe side.
    func measureSpeed(bytes: Int) async throws -> Double {
        var req = URLRequest(url: url("Playback/BitrateTest", query: ["size": String(bytes)]))
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        let start = Date()
        let (data, response) = try await URLSession(configuration: config).data(for: req)
        let elapsed = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw JellyfinError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return Double(data.count * 8) / max(elapsed, 0.001)
    }

    // MARK: Auth

    func publicInfo() async throws -> PublicSystemInfo {
        try await get("System/Info/Public")
    }

    /// The server's own LAN address (e.g. http://192.168.1.20:8096), for switching to local when at home.
    func localAddress() async -> String? {
        let info: SystemInfo? = try? await get("System/Info")
        return info?.localAddress
    }

    func authenticate(username: String, password: String) async throws -> AuthResult {
        try await post("Users/AuthenticateByName", body: ["Username": username, "Pw": password])
    }

    // MARK: Quick Connect

    func quickConnectEnabled() async -> Bool {
        let on: Bool? = try? await get("QuickConnect/Enabled")
        return on ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectState {
        let data = try await send("QuickConnect/Initiate", method: "POST")
        return try JSONDecoder.jellyfin.decode(QuickConnectState.self, from: data)
    }

    func quickConnectState(secret: String) async throws -> QuickConnectState {
        try await get("QuickConnect/Connect", query: ["secret": secret])
    }

    func quickConnectAuthenticate(secret: String) async throws -> AuthResult {
        try await post("Users/AuthenticateWithQuickConnect", body: ["Secret": secret])
    }

    // MARK: Library

    static let listFields = "PrimaryImageAspectRatio,Overview,Genres"

    func userViews() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("UserViews", query: ["userId": userId])
        return r.items
    }

    func resume() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("UserItems/Resume", query: [
            "userId": userId, "limit": "20", "mediaTypes": "Video",
            "fields": Self.listFields, "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        ])
        return r.items
    }

    /// Intro / credits / recap markers (Jellyfin 10.10+, filled in by a segment plugin such as Intro Skipper).
    func mediaSegments(itemId: String) async -> [MediaSegment] {
        let r: MediaSegmentsResult? = try? await get("MediaSegments/\(itemId)")
        return r?.items ?? []
    }

    /// Chapter markers and scrubbing-thumbnail info for an item.
    func playbackExtras(itemId: String) async -> (chapters: [ChapterMarker], trickplay: [String: [String: TrickplayInfo]]) {
        struct R: Codable { let chapters: [ChapterMarker]?; let trickplay: [String: [String: TrickplayInfo]]? }
        let r: R? = try? await get("Users/\(userId ?? "")/Items/\(itemId)", query: ["Fields": "Chapters,Trickplay"])
        return (r?.chapters ?? [], r?.trickplay ?? [:])
    }

    func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String) -> URL {
        url("Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", query: ["mediaSourceId": mediaSourceId])
    }

    /// The episode that comes after this one, across seasons.
    func episodeAfter(_ episode: BaseItem) async -> BaseItem? {
        guard let seriesId = episode.seriesId else { return nil }
        let r: ItemsResult? = try? await get("Shows/\(seriesId)/Episodes", query: [
            "userId": userId, "startItemId": episode.id, "limit": "2",
            "Fields": Self.listFields, "EnableUserData": "true",
        ])
        return r?.items.first { $0.id != episode.id }
    }

    func nextUp(seriesId: String? = nil) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Shows/NextUp", query: [
            "userId": userId, "limit": "20", "seriesId": seriesId, "fields": Self.listFields,
        ])
        return r.items
    }

    func latest(parentId: String) async throws -> [BaseItem] {
        try await get("Items/Latest", query: [
            "userId": userId, "parentId": parentId, "limit": "24", "fields": Self.listFields,
        ])
    }

    func items(parentId: String?, types: String?, recursive: Bool, sortBy: String, sortOrder: String,
               start: Int, limit: Int, filters: String? = nil, genres: String? = nil) async throws -> ItemsResult {
        try await get("Items", query: [
            "userId": userId, "parentId": parentId, "includeItemTypes": types,
            "recursive": recursive ? "true" : "false", "sortBy": sortBy, "sortOrder": sortOrder,
            "startIndex": String(start), "limit": String(limit), "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb", "filters": filters, "genres": genres,
        ])
    }

    /// Every movie and show with just its studio/network tags, for the Studios & Networks grid.
    func studioIndex() async throws -> [StudioTaggedItem] {
        struct Result: Decodable { let items: [StudioTaggedItem] }
        let r: Result = try await get("Items", query: [
            "userId": userId, "recursive": "true", "includeItemTypes": "Movie,Series", "fields": "Studios",
            "enableImages": "false", "enableUserData": "false",
        ])
        return r.items
    }

    func genres(parentId: String?) async -> [String] {
        let r: ItemsResult? = try? await get("Genres", query: ["userId": userId, "parentId": parentId, "sortBy": "SortName"])
        return r?.items.compactMap(\.name) ?? []
    }

    // MARK: Favorites, collections, search

    func setFavorite(_ itemId: String, _ on: Bool) async -> Bool {
        (try? await send("UserFavoriteItems/\(itemId)", query: ["userId": userId], method: on ? "POST" : "DELETE")) != nil
    }

    /// "My List": favorited movies and shows, newest first.
    func favorites() async -> [BaseItem] {
        (try? await browse([
            "filters": "IsFavorite", "includeItemTypes": "Movie,Series", "recursive": "true",
            "sortBy": "DateCreated", "sortOrder": "Descending", "limit": "40",
            "enableImageTypes": "Primary,Backdrop,Thumb",
        ]).items) ?? []
    }

    func collections() async -> [BaseItem] {
        (try? await browse([
            "includeItemTypes": "BoxSet", "recursive": "true", "sortBy": "SortName", "limit": "60",
        ]).items) ?? []
    }

    static let searchTypes = "Movie,Series,Episode,BoxSet,MusicArtist,MusicAlbum,Audio,Book,AudioBook,TvChannel,Playlist"

    func search(_ term: String) async throws -> [BaseItem] {
        try await browse([
            "searchTerm": term, "recursive": "true", "includeItemTypes": Self.searchTypes,
            "limit": "120", "enableImageTypes": "Primary,Backdrop,Thumb",
        ]).items
    }

    /// Behind-the-scenes, trailers, deleted scenes…
    func specialFeatures(_ itemId: String) async -> [BaseItem] {
        (try? await get("Items/\(itemId)/SpecialFeatures", query: ["userId": userId])) ?? []
    }

    /// Parts 2, 3… of a movie split across files.
    func additionalParts(_ itemId: String) async -> [BaseItem] {
        let r: ItemsResult? = try? await get("Videos/\(itemId)/AdditionalParts", query: ["userId": userId])
        return r?.items ?? []
    }

    /// Items related to this one (for "More Like This").
    func similar(_ itemId: String) async -> [BaseItem] {
        let r: ItemsResult? = try? await get("Items/\(itemId)/Similar", query: [
            "userId": userId, "limit": "16", "fields": Self.listFields,
        ])
        return r?.items ?? []
    }

    /// Generic Items query (music, books, playlists…).
    func browse(_ query: [String: String?]) async throws -> ItemsResult {
        var q = query
        q["userId"] = userId
        if q["fields"] == nil { q["fields"] = Self.listFields + ",ChildCount" }
        return try await get("Items", query: q)
    }

    func albumTracks(_ albumId: String) async throws -> [BaseItem] {
        try await browse([
            "parentId": albumId, "includeItemTypes": "Audio", "recursive": "true",
            "sortBy": "ParentIndexNumber,IndexNumber,SortName",
        ]).items
    }

    func artistAlbums(_ artistId: String) async throws -> [BaseItem] {
        try await browse([
            "artistIds": artistId, "includeItemTypes": "MusicAlbum", "recursive": "true",
            "sortBy": "ProductionYear,SortName", "sortOrder": "Descending",
        ]).items
    }

    /// Jellyfin's "Instant Mix": songs similar to a song, album, artist, genre or playlist.
    func instantMix(_ itemId: String, limit: Int = 50) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Items/\(itemId)/InstantMix", query: [
            "userId": userId, "limit": String(limit), "fields": Self.listFields,
        ])
        return r.items
    }

    func musicGenres(parentId: String?) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("MusicGenres", query: [
            "userId": userId, "parentId": parentId, "sortBy": "SortName", "limit": "60",
        ])
        return r.items
    }

    func songs(parentId: String?, sortBy: String, sortOrder: String = "Descending", filters: String? = nil,
               limit: Int = 40) async -> [BaseItem] {
        (try? await browse([
            "parentId": parentId, "includeItemTypes": "Audio", "recursive": "true",
            "sortBy": sortBy, "sortOrder": sortOrder, "filters": filters, "limit": String(limit),
        ]).items) ?? []
    }

    func playlistItems(_ playlistId: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Playlists/\(playlistId)/Items", query: [
            "userId": userId, "fields": Self.listFields,
        ])
        return r.items
    }

    /// Music/audiobook stream. Plays the original (MP3/AAC/ALAC/FLAC/WAV) when possible, otherwise the
    /// server converts to 320 kbps MP3.
    func audioURL(itemId: String) -> URL {
        url("Audio/\(itemId)/universal", query: [
            "UserId": userId, "DeviceId": Self.deviceId, "MaxStreamingBitrate": "320000000",
            "Container": "mp3,aac,m4a,m4b,flac,alac,wav,aiff",
            "TranscodingContainer": "mp3", "TranscodingProtocol": "http", "AudioCodec": "mp3",
            "ApiKey": accessToken,
        ])
    }

    /// Square artwork for songs/albums (songs use their album's art).
    func albumArtURL(for item: BaseItem, width: Int = 600) -> URL {
        if item.imageTag("primary") != nil { return imageURL(item.id, maxWidth: width, tag: item.imageTag("primary")) }
        if let aid = item.albumId { return imageURL(aid, maxWidth: width, tag: item.albumPrimaryImageTag) }
        return imageURL(item.id, maxWidth: width)
    }

    func markPlayed(_ itemId: String) async {
        _ = try? await send("UserPlayedItems/\(itemId)", query: ["userId": userId])
    }

    func item(_ id: String) async throws -> BaseItem {
        try await get("Items/\(id)", query: ["userId": userId])
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Shows/\(seriesId)/Seasons", query: ["userId": userId, "fields": "ChildCount"])
        // Hide empty "seasons" (leftover extras/sample folders) so they don't show up as blank tabs.
        let filled = r.items.filter { ($0.childCount ?? 1) > 0 }
        return filled.isEmpty ? r.items : filled
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Shows/\(seriesId)/Episodes", query: [
            "userId": userId, "seasonId": seasonId, "fields": "Overview,PrimaryImageAspectRatio",
        ])
        return r.items.filter { $0.type == nil || $0.type == "Episode" }
    }

    /// The episode to start for a series: Next Up, else the first real episode. Never a season or folder,
    /// so shows whose folders are laid out oddly still play.
    func firstEpisode(seriesId: String) async -> BaseItem? {
        if let next = (try? await nextUp(seriesId: seriesId))?.first(where: { $0.type == "Episode" }) { return next }
        return (try? await episodes(seriesId: seriesId, seasonId: nil))?.first
    }

    // MARK: Live TV

    func liveChannels() async throws -> [BaseItem] {
        let r: ItemsResult = try await get("LiveTv/Channels", query: [
            "userId": userId, "addCurrentProgram": "true", "enableImageTypes": "Primary,Thumb",
            "fields": "PrimaryImageAspectRatio,ChannelInfo", "limit": "1000",
        ])
        return r.items
    }

    /// Guide entries for the next few hours, grouped by channel.
    func liveGuide(hours: Double = 4) async throws -> [String: [ProgramInfo]] {
        let f = ISO8601DateFormatter()
        let now = Date()
        let r: ProgramsResult = try await get("LiveTv/Programs", query: [
            "userId": userId, "minEndDate": f.string(from: now),
            "maxStartDate": f.string(from: now.addingTimeInterval(hours * 3600)),
            "sortBy": "StartDate", "limit": "3000", "enableImages": "false",
        ])
        return Dictionary(grouping: r.items, by: { $0.channelId ?? "" })
    }

    /// An HLS stream for a live channel. The server otherwise offers a raw MPEG-TS stream for live TV,
    /// which iOS can't play. Video and audio are copied when compatible (H.264/HEVC + AAC/AC-3/E-AC-3).
    func liveHLSURL(channelId: String, mediaSourceId: String, liveStreamId: String?, playSessionId: String?,
                    maxBitrate: Int, audioIndex: Int?) -> URL {
        url("Videos/\(channelId)/master.m3u8", query: [
            "MediaSourceId": mediaSourceId,
            "LiveStreamId": liveStreamId,
            "PlaySessionId": playSessionId,
            "DeviceId": Self.deviceId,
            "VideoCodec": DeviceCapabilities.hevc ? "h264,hevc" : "h264",
            "AudioCodec": "aac,eac3,ac3,mp3",
            "AudioStreamIndex": audioIndex.map(String.init),
            "SegmentContainer": "ts",
            "SegmentLength": String(Self.liveSegmentLength),
            "MinSegments": String(Self.liveMinSegments),
            "BreakOnNonKeyFrames": "false",
            "TranscodingMaxAudioChannels": "6",
            "MaxStreamingBitrate": String(maxBitrate),
            "AllowVideoStreamCopy": "true",
            "AllowAudioStreamCopy": "true",
            "RequireAvc": "false",
            "ApiKey": accessToken,
        ])
    }

    /// Live TV arrives in real time, so the player can never get ahead of it. Short segments that always
    /// start on a keyframe, plus a few of them ready before playback begins, give a cushion that absorbs
    /// hiccups instead of freezing on them.
    static let liveSegmentLength = 2
    static let liveMinSegments = 4

    /// Rewrites the server's live playlist URL with the cushion settings above.
    static func tuningLiveURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        let set: [String: String] = [
            "segmentlength": String(liveSegmentLength),
            "minsegments": String(liveMinSegments),
            "breakonnonkeyframes": "false",
        ]
        items.removeAll { set[$0.name.lowercased()] != nil }
        items += [URLQueryItem(name: "SegmentLength", value: set["segmentlength"]),
                  URLQueryItem(name: "MinSegments", value: set["minsegments"]),
                  URLQueryItem(name: "BreakOnNonKeyFrames", value: "false")]
        comps.queryItems = items
        return comps.url ?? url
    }

    func closeLiveStream(_ liveStreamId: String) async {
        _ = try? await send("LiveTv/LiveStreams/Close", query: ["liveStreamId": liveStreamId])
    }

    // MARK: Playback

    func playbackInfo(itemId: String, maxBitrate: Int, startTicks: Int64 = 0,
                      audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = -1,
                      enableDirectPlay: Bool = true, forAirPlay: Bool = false,
                      mediaSourceId: String? = nil, allowAudioCopy: Bool = true) async throws -> PlaybackInfoResponse {
        let maxBitrate = forAirPlay ? min(maxBitrate, 10_000_000) : maxBitrate
        var body: [String: Any] = [
            "UserId": userId ?? "",
            "DeviceProfile": forAirPlay ? DeviceCapabilities.airPlayProfile(maxBitrate: maxBitrate)
                                        : DeviceCapabilities.deviceProfile(maxBitrate: maxBitrate),
            "MaxStreamingBitrate": maxBitrate,
            "StartTimeTicks": startTicks,
            "EnableDirectPlay": enableDirectPlay && !forAirPlay,
            "EnableDirectStream": !forAirPlay,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": !forAirPlay,
            "AllowAudioStreamCopy": !forAirPlay && allowAudioCopy,
            "AutoOpenLiveStream": true,
        ]
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if let subtitleStreamIndex { body["SubtitleStreamIndex"] = subtitleStreamIndex }
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        // Some server versions read these from the query string rather than the body, so send both.
        return try await post("Items/\(itemId)/PlaybackInfo", query: [
            "userId": userId,
            "maxStreamingBitrate": String(maxBitrate),
            "startTimeTicks": String(startTicks),
            "audioStreamIndex": audioStreamIndex.map(String.init),
            "subtitleStreamIndex": subtitleStreamIndex.map(String.init),
            "mediaSourceId": mediaSourceId,
        ], body: body)
    }

    /// Search online subtitles through the server's plugins (needs e.g. the Open Subtitles plugin).
    func searchSubtitles(itemId: String, language: String) async throws -> [RemoteSubtitleInfo] {
        try await get("Items/\(itemId)/RemoteSearch/Subtitles/\(language)", query: ["isPerfectMatch": "false"])
    }

    /// The server downloads the subtitle next to the media file and adds it to the item.
    func downloadSubtitle(itemId: String, subtitleId: String) async throws {
        try await send("Items/\(itemId)/RemoteSearch/Subtitles/\(subtitleId)", method: "POST")
    }

    /// The server's live view of this device's playback: what it is copying vs re-encoding.
    func currentSession() async throws -> SessionInfo? {
        let sessions: [SessionInfo] = try await get("Sessions", query: ["deviceId": Self.deviceId])
        return sessions.first { $0.nowPlayingItem != nil } ?? sessions.first
    }

    /// Original file, untouched ("static" stream).
    func directPlayURL(itemId: String, mediaSourceId: String, container: String?) -> URL {
        let ext = container?.split(separator: ",").first.map(String.init) ?? "mp4"
        return url("Videos/\(itemId)/stream.\(ext)", query: [
            "static": "true", "mediaSourceId": mediaSourceId,
            "deviceId": Self.deviceId, "ApiKey": accessToken,
        ])
    }

    func originalDownloadURL(itemId: String) -> URL {
        url("Items/\(itemId)/Download", query: ["ApiKey": accessToken])
    }

    /// Server-returned paths (like TranscodingUrl) are relative to the server root.
    func absoluteURL(serverRelative rawPath: String, allowSubtitleBurnIn: Bool = false) -> URL? {
        let path = allowSubtitleBurnIn ? rawPath : Self.removingSubtitleBurnIn(rawPath)
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var full = base + (path.hasPrefix("/") ? path : "/" + path)
        let lower = full.lowercased()
        if !lower.contains("api_key=") && !lower.contains("apikey="), let accessToken {
            full += (full.contains("?") ? "&" : "?") + "ApiKey=\(accessToken)"
        }
        return URL(string: full)
    }

    /// Burning subtitles into the picture forces a full video re-encode (and loses Dolby Vision/HDR).
    /// Until subtitle selection exists, strip any burn-in request so the video can be copied untouched.
    static func removingSubtitleBurnIn(_ path: String) -> String {
        guard var comps = URLComponents(string: "http://placeholder" + (path.hasPrefix("/") ? path : "/" + path)),
              let items = comps.queryItems else { return path }
        let burnIn = items.contains { $0.name.lowercased() == "subtitlemethod" && $0.value?.lowercased() == "encode" }
        guard burnIn else { return path }
        let drop: Set<String> = ["subtitlemethod", "subtitlestreamindex", "subtitlecodec"]
        comps.queryItems = items.filter { !drop.contains($0.name.lowercased()) }
        let rebuilt = comps.percentEncodedPath + (comps.percentEncodedQuery.map { "?" + $0 } ?? "")
        return rebuilt
    }

    /// Set watch position / played state directly (used to sync offline viewing).
    func updateUserData(itemId: String, positionTicks: Int64, played: Bool) async -> Bool {
        let body: [String: Any] = [
            "PlaybackPositionTicks": positionTicks,
            "Played": played,
            "LastPlayedDate": ISO8601DateFormatter().string(from: Date()),
        ]
        if (try? await send("UserItems/\(itemId)/UserData", query: ["userId": userId], body: body)) != nil {
            return true
        }
        // Older servers: report a stopped playback session at that position instead.
        let fallback: [String: Any] = ["ItemId": itemId, "PositionTicks": positionTicks, "CanSeek": true]
        return (try? await send("Sessions/Playing/Stopped", body: fallback)) != nil
    }

    func reportPlayback(_ path: String, body: [String: Any]) async {
        _ = try? await send(path, body: body)
    }

    func stopEncoding(playSessionId: String) async {
        _ = try? await send("Videos/ActiveEncodings",
                            query: ["deviceId": Self.deviceId, "playSessionId": playSessionId],
                            method: "DELETE")
    }

    // MARK: Images

    func imageURL(_ itemId: String, type: String = "Primary", maxWidth: Int = 400, tag: String? = nil) -> URL {
        url("Items/\(itemId)/Images/\(type)", query: ["maxWidth": String(maxWidth), "quality": "90", "tag": tag])
    }

    func posterURL(for item: BaseItem, width: Int = 400) -> URL {
        if item.type == "Episode", let sid = item.seriesId {
            return imageURL(sid, maxWidth: width, tag: item.seriesPrimaryImageTag)
        }
        return imageURL(item.id, maxWidth: width, tag: item.imageTag("primary"))
    }

    /// 16:9 artwork: episode stills, then backdrops, then thumbs.
    func landscapeURL(for item: BaseItem, width: Int = 700) -> URL {
        if item.type == "Episode" { return imageURL(item.id, maxWidth: width, tag: item.imageTag("primary")) }
        return backdropURL(for: item, width: width)
    }

    /// Card artwork that shows the title, like Apple TV: the item's Thumb, then the show's Thumb, then 16:9 art.
    func thumbCardURL(for item: BaseItem, width: Int = 700) -> URL {
        if let tag = item.imageTag("thumb") { return imageURL(item.id, type: "Thumb", maxWidth: width, tag: tag) }
        if let pid = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(pid, type: "Thumb", maxWidth: width, tag: tag)
        }
        if let sid = item.seriesId, let tag = item.seriesThumbImageTag {
            return imageURL(sid, type: "Thumb", maxWidth: width, tag: tag)
        }
        return landscapeURL(for: item, width: width)
    }

    func backdropURL(for item: BaseItem, width: Int = 1600) -> URL {
        if let tag = item.backdropImageTags?.first {
            return imageURL(item.id, type: "Backdrop/0", maxWidth: width, tag: tag)
        }
        if let pid = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(pid, type: "Backdrop/0", maxWidth: width, tag: tag)
        }
        if let thumb = item.imageTag("thumb") {
            return imageURL(item.id, type: "Thumb", maxWidth: width, tag: thumb)
        }
        return imageURL(item.id, maxWidth: width, tag: item.imageTag("primary"))
    }

    func logoURL(for item: BaseItem) -> URL? {
        if let tag = item.imageTag("logo") { return imageURL(item.id, type: "Logo", maxWidth: 600, tag: tag) }
        if let pid = item.parentLogoItemId { return imageURL(pid, type: "Logo", maxWidth: 600, tag: item.parentLogoImageTag) }
        return nil
    }
}
