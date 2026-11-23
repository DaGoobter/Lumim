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

    /// Identifies one user on one server.
    var key: String { (serverId ?? serverURL) + "|" + userId }
}

@MainActor @Observable
final class AppState {
    enum Route: Equatable { case local, remote }

    private(set) var session: StoredSession? = nil
    /// Every account signed in on this device (any number of users and servers).
    private(set) var accounts: [StoredSession] = []
    private(set) var client: JellyfinClient? = nil
    private(set) var route: Route = .remote
    /// Why the home address is or isn't being used (shown in Settings).
    private(set) var localStatus: String = "Checking…"

    /// Player overlays.
    var showBrightnessSlider: Bool = true
    var showVolumeSlider: Bool = true

    /// Bits per second. High by default so the server prefers untouched (direct) playback.
    var maxBitrate: Int = 200_000_000
    /// Switch to the server's local address when on the same network (faster, no internet round-trip).
    var preferLocal: Bool = true
    /// Default audio/subtitle choices.
    var trackPrefs = TrackPreferences.load()

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var retriedAfterPrompt = false

    func persistSettings() {
        UserDefaults.standard.set(maxBitrate, forKey: "lumen.maxBitrate")
        UserDefaults.standard.set(preferLocal, forKey: "lumen.preferLocal")
        UserDefaults.standard.set(showBrightnessSlider, forKey: "lumen.showBrightness")
        UserDefaults.standard.set(showVolumeSlider, forKey: "lumen.showVolume")
        trackPrefs.save()
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "lumen.maxBitrate")
        if saved > 0 { maxBitrate = saved }
        if UserDefaults.standard.object(forKey: "lumen.showBrightness") != nil {
            showBrightnessSlider = UserDefaults.standard.bool(forKey: "lumen.showBrightness")
        }
        if UserDefaults.standard.object(forKey: "lumen.showVolume") != nil {
            showVolumeSlider = UserDefaults.standard.bool(forKey: "lumen.showVolume")
        }
        if UserDefaults.standard.object(forKey: "lumen.preferLocal") != nil {
            preferLocal = UserDefaults.standard.bool(forKey: "lumen.preferLocal")
        }
        if let data = Keychain.load("accounts"),
           let list = try? JSONDecoder().decode([StoredSession].self, from: data) {
            accounts = list
        }
        if let data = Keychain.load("session"),
           let s = try? JSONDecoder().decode(StoredSession.self, from: data),
           let url = URL(string: s.serverURL) {
            session = s
            client = JellyfinClient(baseURL: url, deviceName: UIDevice.current.name, token: s.token, userId: s.userId)
            if !accounts.contains(where: { $0.key == s.key }) {
                accounts.append(s)
                persistAccounts()
            }
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
        if !preferLocal {
            localStatus = "Off"
        } else if let l = s.localURL, let localURL = URL(string: l) {
            // If no port was typed, also try Jellyfin's default 8096.
            var candidates = [localURL]
            if localURL.port == nil, var comps = URLComponents(url: localURL, resolvingAgainstBaseURL: false) {
                comps.port = 8096
                if let withPort = comps.url { candidates.append(withPort) }
            }
            var lastProblem = "Not reachable"
            for candidate in candidates where candidate != remote {
                if let problem = await Self.probe(candidate, serverId: s.serverId) {
                    lastProblem = problem
                } else {
                    target = candidate
                    newRoute = .local
                    if candidate.absoluteString != l {
                        s.localURL = candidate.absoluteString
                        save(s)
                    }
                    break
                }
            }
            localStatus = newRoute == .local ? "Connected" : lastProblem
        } else {
            localStatus = "No home address yet"
        }

        route = newRoute
        if client?.baseURL != target {
            client = JellyfinClient(baseURL: target, deviceName: UIDevice.current.name, token: s.token, userId: s.userId)
        }
        // Back online: resume queued downloads and push any offline watch progress.
        if let client { DownloadManager.shared.attach(client: client) }

        // The first local connection triggers iOS's "Local Network" permission prompt and may time out
        // while it's on screen, so check once more shortly after.
        if newRoute == .remote, preferLocal, s.localURL != nil, !retriedAfterPrompt {
            retriedAfterPrompt = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                await refreshRoute()
            }
        }
    }

    /// Quick reachability check that also confirms it's the same server (not some other device on this Wi-Fi).
    /// Returns nil when reachable, otherwise a short, human explanation.
    static func probe(_ url: URL, serverId: String?) async -> String? {
        var req = URLRequest(url: url.appendingPathComponent("System/Info/Public"))
        req.timeoutInterval = 3
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let info = try? JSONDecoder.jellyfin.decode(PublicSystemInfo.self, from: data) else {
                return "Something answered at \(url.host ?? "that address"), but it isn't Jellyfin"
            }
            if let serverId, let id = info.id, id != serverId {
                return "A different Jellyfin server answered at that address"
            }
            return nil
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return "Timed out. Check the address and port, and that Local Network access is on for Prism (iPhone Settings → Privacy & Security → Local Network)"
            case .cannotConnectToHost:
                return "Connection refused at \(url.host ?? "")\(url.port.map { ":\($0)" } ?? ""). Wrong port? Jellyfin's default is 8096"
            case .notConnectedToInternet, .networkConnectionLost:
                return "Can't reach the home network. Are you on your home Wi‑Fi, and is Local Network access on for Prism (iPhone Settings → Privacy & Security → Local Network)?"
            case .cannotFindHost, .dnsLookupFailed:
                return "Couldn't find \(url.host ?? "that host"). Try the server's IP address instead"
            case .appTransportSecurityRequiresSecureConnection:
                return "Blocked by iOS security for plain http"
            default:
                return error.localizedDescription
            }
        } catch {
            return error.localizedDescription
        }
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
        retriedAfterPrompt = false
        localStatus = "Checking…"
        await refreshRoute()
    }

    func recheckConnection() async {
        retriedAfterPrompt = false
        localStatus = "Checking…"
        await refreshRoute()
    }

    private func save(_ s: StoredSession) {
        session = s
        if let data = try? JSONEncoder().encode(s) { Keychain.save(data, key: "session") }
        if let i = accounts.firstIndex(where: { $0.key == s.key }) { accounts[i] = s } else { accounts.append(s) }
        persistAccounts()
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { Keychain.save(data, key: "accounts") }
    }

    // MARK: Accounts

    /// Switch to another saved user or server.
    func switchTo(_ account: StoredSession) {
        guard account.key != session?.key, let url = URL(string: account.serverURL) else { return }
        AudioPlayer.shared.stop()
        save(account)
        client = JellyfinClient(baseURL: url, deviceName: UIDevice.current.name, token: account.token, userId: account.userId)
        route = .remote
        retriedAfterPrompt = false
        localStatus = "Checking…"
        Task { await refreshRoute() }
    }

    /// Forget a saved account (signs it out on the server too).
    func remove(_ account: StoredSession) async {
        if account.key == session?.key { await logout(); return }
        if let url = URL(string: account.serverURL) {
            let c = JellyfinClient(baseURL: url, deviceName: UIDevice.current.name, token: account.token, userId: account.userId)
            _ = try? await c.send("Sessions/Logout")
        }
        accounts.removeAll { $0.key == account.key }
        persistAccounts()
    }

    // MARK: Sign in / out

    func login(server: String, username: String, password: String) async throws {
        let (client, info) = try await connect(server: server)
        let auth = try await client.authenticate(username: username, password: password)
        adopt(client: client, info: info, auth: auth)
    }

    /// Quick Connect: ask the server for a code that a signed-in device approves.
    func quickConnectStart(server: String) async throws -> (client: JellyfinClient, info: PublicSystemInfo, secret: String, code: String) {
        let (client, info) = try await connect(server: server)
        guard await client.quickConnectEnabled() else { throw QuickConnectError.disabled }
        let r = try await client.quickConnectInitiate()
        return (client, info, r.secret, r.code ?? "")
    }

    /// Waits (up to 5 minutes) for the code to be approved, then signs in.
    func quickConnectFinish(client: JellyfinClient, info: PublicSystemInfo, secret: String) async throws {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            if let state = try? await client.quickConnectState(secret: secret), state.authenticated == true {
                let auth = try await client.quickConnectAuthenticate(secret: secret)
                adopt(client: client, info: info, auth: auth)
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw QuickConnectError.expired
    }

    private func adopt(client: JellyfinClient, info: PublicSystemInfo, auth: AuthResult) {
        AudioPlayer.shared.stop()
        client.accessToken = auth.accessToken
        client.userId = auth.user.id
        let s = StoredSession(serverURL: client.baseURL.absoluteString, serverName: info.serverName,
                              userId: auth.user.id, userName: auth.user.name, token: auth.accessToken,
                              serverId: info.id, localURL: nil, localURLIsManual: nil)
        // Signing in again as someone already saved keeps their learned home address.
        var merged = s
        if let old = accounts.first(where: { $0.key == s.key }) {
            merged.localURL = old.localURL
            merged.localURLIsManual = old.localURLIsManual
        }
        save(merged)
        self.client = client
        route = .remote
        retriedAfterPrompt = false
        Task { await refreshRoute() }
    }

    private func connect(server: String) async throws -> (JellyfinClient, PublicSystemInfo) {
        // Find a reachable address (try https first if no scheme was typed).
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
        return found
    }

    /// Signs out the current account; switches to another saved one if there is one.
    func logout() async {
        if let client { _ = try? await client.send("Sessions/Logout") }
        AudioPlayer.shared.stop()
        let current = session?.key
        accounts.removeAll { $0.key == current }
        persistAccounts()
        Keychain.delete("session")
        session = nil
        client = nil
        if let next = accounts.first { switchTo(next) }
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

enum QuickConnectError: LocalizedError {
    case disabled, expired
    var errorDescription: String? {
        switch self {
        case .disabled: return "Quick Connect is turned off on this server. An admin can turn it on in Dashboard → General."
        case .expired: return "The code expired. Get a new one and try again."
        }
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
