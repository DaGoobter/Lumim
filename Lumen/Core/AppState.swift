import SwiftUI
import Observation
import Security
import Network

struct StoredSession: Codable {
    /// The address used to sign in (normally the remote domain).
    var serverURL: String
    var serverName: String?
    var userId: String
    var userName: String
    var token: String
    var serverId: String?
    /// The server's home-network address, used automatically when it's reachable.
    var localURL: String?
    var localURLIsManual: Bool?
}

@MainActor @Observable
final class AppState {
    enum Route: Equatable { case local, remote }

    private(set) var session: StoredSession? = nil
    private(set) var client: JellyfinClient? = nil
    private(set) var route: Route = .remote

    /// Bits per second. High by default so the server prefers untouched (direct) playback.
    var maxBitrate: Int = 200_000_000
    /// Switch to the server's local address when on the same network (faster, no internet round-trip).
    var preferLocal: Bool = true
    /// Default audio/subtitle choices.
    var trackPrefs = TrackPreferences.load()

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    func persistSettings() {
        UserDefaults.standard.set(maxBitrate, forKey: "lumen.maxBitrate")
        UserDefaults.standard.set(preferLocal, forKey: "lumen.preferLocal")
        trackPrefs.save()
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "lumen.maxBitrate")
        if saved > 0 { maxBitrate = saved }
        if UserDefaults.standard.object(forKey: "lumen.preferLocal") != nil {
            preferLocal = UserDefaults.standard.bool(forKey: "lumen.preferLocal")
        }
        if let data = Keychain.load("session"),
           let s = try? JSONDecoder().decode(StoredSession.self, from: data),
           let url = URL(string: s.serverURL) {
            session = s
            client = JellyfinClient(baseURL: url, deviceName: UIDevice.current.name, token: s.token, userId: s.userId)
        }
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRouteCheck() }
        }
        monitor.start(queue: DispatchQueue(label: "lumen.network-monitor"))
    }

    // MARK: Local / remote routing

    /// Re-check which address to use (after a network change or when the app comes to the foreground).
    func scheduleRouteCheck() {
        routeTask?.cancel()
        routeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await refreshRoute()
        }
    }

    func refreshRoute() async {
        guard var s = session, let remote = URL(string: s.serverURL) else { return }

        // Learn the server's LAN address once (unless the user typed their own).
        if s.localURL == nil, s.localURLIsManual != true, let c = client,
           let addr = await c.localAddress(), !addr.isEmpty {
            s.localURL = addr
            save(s)
        }

        var target = remote
        var newRoute = Route.remote
        if preferLocal, let l = s.localURL, let localURL = URL(string: l), localURL != remote,
           await Self.probe(localURL, serverId: s.serverId) {
            target = localURL
            newRoute = .local
        }
        route = newRoute
        if client?.baseURL != target {
            client = JellyfinClient(baseURL: target, deviceName: UIDevice.current.name, token: s.token, userId: s.userId)
        }
        // Back online: resume queued downloads and push any offline watch progress.
        if let client { DownloadManager.shared.attach(client: client) }
    }

    /// Quick reachability check that also confirms it's the same server (not some other device on this Wi-Fi).
    static func probe(_ url: URL, serverId: String?) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("System/Info/Public"))
        req.timeoutInterval = 2.5
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.waitsForConnectivity = false
        guard let result = try? await URLSession(configuration: config).data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder.jellyfin.decode(PublicSystemInfo.self, from: result.0) else { return false }
        return serverId == nil || info.id == serverId
    }

    /// Edit addresses from Settings. Empty local = auto-detect again.
    func updateAddresses(remote: String, local: String) async {
        guard var s = session else { return }
        if let r = Self.candidateURLs(remote).first { s.serverURL = r.absoluteString }
        let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            s.localURL = nil
            s.localURLIsManual = nil
        } else if let l = Self.candidateURLs(trimmed).last {   // last = http:// when no scheme typed
            s.localURL = l.absoluteString
            s.localURLIsManual = true
        }
        save(s)
        await refreshRoute()
    }

    private func save(_ s: StoredSession) {
        session = s
        if let data = try? JSONEncoder().encode(s) { Keychain.save(data, key: "session") }
    }

    // MARK: Sign in / out

    func login(server: String, username: String, password: String) async throws {
        // 1. Find a reachable address (try https first if no scheme was typed).
        var reachable: (JellyfinClient, PublicSystemInfo)?
        var lastError: Error = JellyfinError.badURL
        for url in Self.candidateURLs(server) {
            let c = JellyfinClient(baseURL: url, deviceName: UIDevice.current.name)
            do {
                let info = try await c.publicInfo()
                reachable = (c, info)
                break
            } catch {
                lastError = error
            }
        }
        guard let found = reachable else { throw lastError }
        let (client, info) = found

        // 2. Sign in.
        let auth = try await client.authenticate(username: username, password: password)
        client.accessToken = auth.accessToken
        client.userId = auth.user.id
        let s = StoredSession(serverURL: client.baseURL.absoluteString, serverName: info.serverName,
                              userId: auth.user.id, userName: auth.user.name, token: auth.accessToken,
                              serverId: info.id, localURL: nil, localURLIsManual: nil)
        save(s)
        self.client = client
        route = .remote
        Task { await refreshRoute() }
    }

    func logout() async {
        if let client { _ = try? await client.send("Sessions/Logout") }
        Keychain.delete("session")
        session = nil
        client = nil
    }

    static func candidateURLs(_ raw: String) -> [URL] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        for suffix in ["/web/index.html", "/web/", "/web", "/"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        guard !s.isEmpty else { return [] }
        let candidates = s.contains("://") ? [s] : ["https://" + s, "http://" + s]
        return candidates.compactMap(URL.init(string:))
    }
}

enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Lumen",
         kSecAttrAccount as String: key]
    }

    static func save(_ data: Data, key: String) {
        SecItemDelete(base(key) as CFDictionary)
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}
