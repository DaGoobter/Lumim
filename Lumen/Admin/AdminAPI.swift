import Foundation

// MARK: - Models (server dashboard)

struct AdminSession: Codable, Identifiable, Hashable {
    let id: String
    let userId: String?
    let userName: String?
    let client: String?
    let deviceName: String?
    let deviceId: String?
    let applicationVersion: String?
    let remoteEndPoint: String?
    let lastActivityDate: String?
    let nowPlayingItem: BaseItem?
    let playState: AdminPlayState?
    let transcodingInfo: AdminTranscodingInfo?
    let supportsRemoteControl: Bool?

    static func == (a: AdminSession, b: AdminSession) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var lastActive: Date? { lastActivityDate.flatMap(parseJellyfinDate) }
    var isPaused: Bool { playState?.isPaused ?? false }

    var progress: Double? {
        guard let pos = playState?.positionTicks, let total = nowPlayingItem?.runTimeTicks, total > 0 else { return nil }
        return min(1, max(0, Double(pos) / Double(total)))
    }

    enum Method { case direct, remux, audioOnly, transcode }

    var method: Method {
        if let t = transcodingInfo {
            switch (t.isVideoDirect ?? false, t.isAudioDirect ?? false) {
            case (true, true): return .remux
            case (true, false): return .audioOnly
            default: return nowPlayingItem?.isAudio == true && t.isAudioDirect == true ? .remux : .transcode
            }
        }
        return playState?.playMethod == "Transcode" ? .transcode : .direct
    }

    var isLocal: Bool {
        guard let ip = remoteEndPoint else { return false }
        return ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("127.") || ip.hasPrefix("::1")
            || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
    }
}

struct AdminPlayState: Codable, Hashable {
    let positionTicks: Int64?
    let isPaused: Bool?
    let isMuted: Bool?
    let playMethod: String?
}

struct AdminTranscodingInfo: Codable, Hashable {
    let audioCodec: String?
    let videoCodec: String?
    let container: String?
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?
    let bitrate: Int?
    let framerate: Double?
    let completionPercentage: Double?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    let hardwareAccelerationType: String?
    let transcodeReasons: [String]?
}

struct AdminSystemInfo: Codable {
    let serverName: String?
    let version: String?
    let id: String?
    let operatingSystemDisplayName: String?
    let hasPendingRestart: Bool?
    let hasUpdateAvailable: Bool?
    let canSelfRestart: Bool?
    let systemArchitecture: String?
    let encoderLocation: String?
}

struct FolderStorage: Codable, Hashable {
    let path: String?
    let freeSpace: Int64?
    let usedSpace: Int64?
    let storageType: String?
    let deviceId: String?

    var total: Int64 { max(0, (freeSpace ?? 0)) + max(0, (usedSpace ?? 0)) }
    var fraction: Double { total > 0 ? Double(max(0, usedSpace ?? 0)) / Double(total) : 0 }
    /// "S:\" or "/mnt/media" — the drive a folder lives on.
    var driveLabel: String {
        guard let p = path else { return "Drive" }
        if p.count >= 2, p[p.index(after: p.startIndex)] == ":" { return String(p.prefix(2)) + "\\" }
        return p
    }
}

struct LibraryStorage: Codable, Hashable {
    let id: String?
    let name: String?
    let folders: [FolderStorage]?
}

struct SystemStorage: Codable {
    let programDataFolder: FolderStorage?
    let cacheFolder: FolderStorage?
    let transcodingTempFolder: FolderStorage?
    let libraries: [LibraryStorage]?

    /// One entry per physical drive, labelled with what lives on it.
    var drives: [(drive: FolderStorage, uses: [String])] {
        var order: [String] = []
        var byKey: [String: (FolderStorage, [String])] = [:]
        func add(_ f: FolderStorage?, _ use: String) {
            guard let f, f.total > 0 else { return }
            let key = f.deviceId ?? f.driveLabel
            if byKey[key] == nil { order.append(key); byKey[key] = (f, []) }
            if !(byKey[key]!.1.contains(use)) { byKey[key]!.1.append(use) }
        }
        for lib in libraries ?? [] { for f in lib.folders ?? [] { add(f, lib.name ?? "Library") } }
        add(programDataFolder, "Jellyfin data")
        add(transcodingTempFolder, "Transcodes")
        add(cacheFolder, "Cache")
        return order.compactMap { byKey[$0] }.map { ($0.0, $0.1) }
    }
}

struct ItemCounts: Codable {
    let movieCount: Int?
    let seriesCount: Int?
    let episodeCount: Int?
    let albumCount: Int?
    let songCount: Int?
    let artistCount: Int?
    let bookCount: Int?
    let musicVideoCount: Int?
    let boxSetCount: Int?
}

struct VirtualFolder: Codable, Identifiable, Hashable {
    let name: String?
    let itemId: String?
    let collectionType: String?
    let locations: [String]?
    let refreshProgress: Double?
    let refreshStatus: String?
    let primaryImageItemId: String?

    var id: String { itemId ?? name ?? UUID().uuidString }
}

struct AdminUser: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let primaryImageTag: String?
    let hasPassword: Bool?
    let lastLoginDate: String?
    let lastActivityDate: String?
    let policy: AdminUserPolicy?

    var lastActive: Date? { lastActivityDate.flatMap(parseJellyfinDate) }
}

struct AdminUserPolicy: Codable, Hashable {
    let isAdministrator: Bool?
    let isDisabled: Bool?
    let enableRemoteAccess: Bool?
    let enableContentDownloading: Bool?
    let enableVideoPlaybackTranscoding: Bool?
    let enableAudioPlaybackTranscoding: Bool?
    let enablePlaybackRemuxing: Bool?
    let enableLiveTvAccess: Bool?
    let remoteClientBitrateLimit: Int?
}

struct ScheduledTask: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let state: String?
    let currentProgressPercentage: Double?
    let category: String?
    let description: String?
    let isHidden: Bool?
    let lastExecutionResult: TaskResult?

    var isRunning: Bool { state == "Running" || state == "Cancelling" }
}

struct TaskResult: Codable, Hashable {
    let startTimeUtc: String?
    let endTimeUtc: String?
    let status: String?
    let errorMessage: String?

    var ended: Date? { endTimeUtc.flatMap(parseJellyfinDate) }
}

struct ActivityEntry: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let overview: String?
    let shortOverview: String?
    let type: String?
    let date: String?
    let userId: String?
    let severity: String?

    var when: Date? { date.flatMap(parseJellyfinDate) }
}

struct ActivityPage: Codable {
    let items: [ActivityEntry]
    let totalRecordCount: Int?
}

struct LogFile: Codable, Identifiable, Hashable {
    let name: String
    let size: Int64?
    let dateModified: String?
    var id: String { name }
    var modified: Date? { dateModified.flatMap(parseJellyfinDate) }
}

struct DeviceEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let customName: String?
    let appName: String?
    let appVersion: String?
    let lastUserName: String?
    let lastUserId: String?
    let dateLastActivity: String?

    var lastActive: Date? { dateLastActivity.flatMap(parseJellyfinDate) }
}

struct DevicePage: Codable { let items: [DeviceEntry] }

struct PluginInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let version: String?
    let description: String?
    let status: String?
    let canUninstall: Bool?
}

// MARK: - Watch statistics (Playback Reporting plugin)

struct WatchStats {
    struct Day: Identifiable { let date: Date; let hours: Double; var id: Date { date } }
    struct Slice: Identifiable { let label: String; let count: Int; var id: String { label } }
    struct Row: Identifiable { let name: String; let hours: Double; let plays: Int; var id: String { name } }

    var days: [Day] = []
    var methods: [Slice] = []
    var users: [Row] = []
    var titles: [Row] = []

    var totalHours: Double { days.reduce(0) { $0 + $1.hours } }
}

// MARK: - API

extension JellyfinClient {
    func adminIsAdministrator() async -> Bool {
        struct Me: Codable { let policy: AdminUserPolicy? }
        let me: Me? = try? await get("Users/Me")
        return me?.policy?.isAdministrator ?? false
    }

    func adminSystemInfo() async throws -> AdminSystemInfo { try await get("System/Info") }
    func adminStorage() async throws -> SystemStorage { try await get("System/Info/Storage") }
    func adminCounts() async throws -> ItemCounts { try await get("Items/Counts") }

    func adminSessions() async throws -> [AdminSession] {
        try await get("Sessions", query: ["activeWithinSeconds": "960"])
    }

    func adminSessionCommand(_ sessionId: String, _ command: String) async throws {
        try await send("Sessions/\(sessionId)/Playing/\(command)")
    }

    func adminSendMessage(_ sessionId: String, header: String, text: String) async throws {
        try await send("Sessions/\(sessionId)/Message",
                       body: ["Header": header, "Text": text, "TimeoutMs": 8000] as [String: Any])
    }

    func adminLibraries() async throws -> [VirtualFolder] { try await get("Library/VirtualFolders") }

    func adminScanAll() async throws { try await send("Library/Refresh") }

    func adminRefresh(itemId: String, replaceAll: Bool) async throws {
        try await send("Items/\(itemId)/Refresh", query: [
            "Recursive": "true",
            "MetadataRefreshMode": replaceAll ? "FullRefresh" : "Default",
            "ImageRefreshMode": replaceAll ? "FullRefresh" : "Default",
            "ReplaceAllMetadata": replaceAll ? "true" : "false",
            "ReplaceAllImages": replaceAll ? "true" : "false",
        ])
    }

    func adminUsers() async throws -> [AdminUser] { try await get("Users") }

    /// Change a few policy switches without touching the rest of the user's policy.
    func adminUpdatePolicy(userId: String, changes: [String: Any]) async throws {
        let data = try await send("Users/\(userId)", method: "GET")
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var policy = user["Policy"] as? [String: Any] else { throw JellyfinError.http(500) }
        for (k, v) in changes { policy[k] = v }
        try await send("Users/\(userId)/Policy", body: policy)
    }

    func adminTasks() async throws -> [ScheduledTask] {
        try await get("ScheduledTasks", query: ["isHidden": "false"])
    }
    func adminStartTask(_ id: String) async throws { try await send("ScheduledTasks/Running/\(id)") }
    func adminStopTask(_ id: String) async throws { try await send("ScheduledTasks/Running/\(id)", method: "DELETE") }

    func adminActivity(start: Int, limit: Int = 50) async throws -> ActivityPage {
        try await get("System/ActivityLog/Entries", query: ["startIndex": String(start), "limit": String(limit)])
    }

    func adminLogs() async throws -> [LogFile] { try await get("System/Logs") }

    func adminLog(_ name: String) async throws -> String {
        let data = try await send("System/Logs/Log", query: ["name": name], method: "GET")
        return String(decoding: data, as: UTF8.self)
    }

    func adminDevices() async throws -> [DeviceEntry] {
        let page: DevicePage = try await get("Devices")
        return page.items
    }
    func adminDeleteDevice(_ id: String) async throws { try await send("Devices", query: ["id": id], method: "DELETE") }

    func adminPlugins() async throws -> [PluginInfo] { try await get("Plugins") }

    func adminAuthorizeQuickConnect(code: String) async throws {
        try await send("QuickConnect/Authorize", query: ["code": code, "userId": userId])
    }

    func adminRestart() async throws { try await send("System/Restart") }
    func adminShutdown() async throws { try await send("System/Shutdown") }

    // MARK: Playback Reporting plugin

    private func reportQuery(_ sql: String) async throws -> [[String]] {
        let data = try await send("user_usage_stats/submit_custom_query",
                                  body: ["CustomQueryString": sql, "ReplaceUserId": true] as [String: Any])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["results"] as? [[Any]] else { return [] }
        return rows.map { $0.map { "\($0)" } }
    }

    /// nil when the Playback Reporting plugin isn't installed.
    func adminWatchStats() async -> WatchStats? {
        let since14 = "datetime('now', '-13 days', 'start of day')"
        let since30 = "datetime('now', '-30 days')"
        do {
            var stats = WatchStats()
            let dayRows = try await reportQuery("""
                SELECT date(DateCreated) AS d, SUM(PlayDuration) FROM PlaybackActivity
                WHERE DateCreated >= \(since14) GROUP BY d ORDER BY d
                """)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            var byDay: [String: Double] = [:]
            for r in dayRows where r.count >= 2 { byDay[r[0]] = (Double(r[1]) ?? 0) / 3600 }
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            stats.days = (0..<14).reversed().compactMap { back in
                guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
                return .init(date: d, hours: byDay[fmt.string(from: d)] ?? 0)
            }

            let methodRows = try await reportQuery("""
                SELECT PlaybackMethod, COUNT(*) FROM PlaybackActivity
                WHERE DateCreated >= \(since30) GROUP BY PlaybackMethod
                """)
            var buckets: [String: Int] = [:]
            for r in methodRows where r.count >= 2 {
                let m = r[0].lowercased()
                let label = m.hasPrefix("directplay") ? "Direct Play"
                    : m.hasPrefix("directstream") ? "Direct Stream"
                    : m.contains("v:direct") ? "Remux" : "Transcode"
                buckets[label, default: 0] += Int(r[1]) ?? 0
            }
            stats.methods = ["Direct Play", "Direct Stream", "Remux", "Transcode"]
                .compactMap { l in buckets[l].map { .init(label: l, count: $0) } }

            let userRows = try await reportQuery("""
                SELECT UserId, SUM(PlayDuration), COUNT(*) FROM PlaybackActivity
                WHERE DateCreated >= \(since30) GROUP BY UserId ORDER BY 2 DESC LIMIT 6
                """)
            stats.users = userRows.filter { $0.count >= 3 }.map {
                .init(name: $0[0], hours: (Double($0[1]) ?? 0) / 3600, plays: Int($0[2]) ?? 0)
            }

            let titleRows = try await reportQuery("""
                SELECT ItemName, SUM(PlayDuration), COUNT(*) FROM PlaybackActivity
                WHERE DateCreated >= \(since30) AND ItemType != 'Audio'
                GROUP BY ItemName ORDER BY 2 DESC LIMIT 6
                """)
            stats.titles = titleRows.filter { $0.count >= 3 }.map {
                .init(name: $0[0], hours: (Double($0[1]) ?? 0) / 3600, plays: Int($0[2]) ?? 0)
            }
            return stats
        } catch {
            return nil
        }
    }
}
