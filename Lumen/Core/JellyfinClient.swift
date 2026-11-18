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

    static let clientName = "Lumen"
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

    // MARK: Auth

    func publicInfo() async throws -> PublicSystemInfo {
        try await get("System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthResult {
        try await post("Users/AuthenticateByName", body: ["Username": username, "Pw": password])
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
               start: Int, limit: Int) async throws -> ItemsResult {
        try await get("Items", query: [
            "userId": userId, "parentId": parentId, "includeItemTypes": types,
            "recursive": recursive ? "true" : "false", "sortBy": sortBy, "sortOrder": sortOrder,
            "startIndex": String(start), "limit": String(limit), "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb",
        ])
    }

    func item(_ id: String) async throws -> BaseItem {
        try await get("Items/\(id)", query: ["userId": userId])
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Shows/\(seriesId)/Seasons", query: ["userId": userId])
        return r.items
    }

    func episodes(seriesId: String, seasonId: String) async throws -> [BaseItem] {
        let r: ItemsResult = try await get("Shows/\(seriesId)/Episodes", query: [
            "userId": userId, "seasonId": seasonId, "fields": "Overview,PrimaryImageAspectRatio",
        ])
        return r.items
    }

    // MARK: Playback

    func playbackInfo(itemId: String, maxBitrate: Int, startTicks: Int64 = 0,
                      audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = -1) async throws -> PlaybackInfoResponse {
        var body: [String: Any] = [
            "UserId": userId ?? "",
            "DeviceProfile": DeviceCapabilities.deviceProfile(maxBitrate: maxBitrate),
            "MaxStreamingBitrate": maxBitrate,
            "StartTimeTicks": startTicks,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
        ]
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if let subtitleStreamIndex { body["SubtitleStreamIndex"] = subtitleStreamIndex }
        // Some server versions read these from the query string rather than the body, so send both.
        return try await post("Items/\(itemId)/PlaybackInfo", query: [
            "userId": userId,
            "maxStreamingBitrate": String(maxBitrate),
            "startTimeTicks": String(startTicks),
            "audioStreamIndex": audioStreamIndex.map(String.init),
            "subtitleStreamIndex": subtitleStreamIndex.map(String.init),
        ], body: body)
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
            "deviceId": Self.deviceId, "api_key": accessToken,
        ])
    }

    func originalDownloadURL(itemId: String) -> URL {
        url("Items/\(itemId)/Download", query: ["api_key": accessToken])
    }

    /// Server-returned paths (like TranscodingUrl) are relative to the server root.
    func absoluteURL(serverRelative rawPath: String) -> URL? {
        let path = Self.removingSubtitleBurnIn(rawPath)
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var full = base + (path.hasPrefix("/") ? path : "/" + path)
        let lower = full.lowercased()
        if !lower.contains("api_key=") && !lower.contains("apikey="), let accessToken {
            full += (full.contains("?") ? "&" : "?") + "api_key=\(accessToken)"
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
