import SwiftUI
import Observation

/// Requests through Seerr (Jellyseerr/Overseerr): ask for movies and shows that aren't on the server yet.
/// Signs in with the same Jellyfin username and password, once; Seerr keeps the session.
@MainActor @Observable
final class Seerr {
    static let shared = Seerr()

    struct Result: Identifiable, Hashable {
        let id: Int
        let mediaType: String
        let title: String
        let year: String?
        let overview: String?
        let posterPath: String?
        /// 5 available, 4 partly available, 3 processing, 2 pending, else not requested.
        let status: Int?
        var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
        var statusText: String? {
            switch status {
            case 5: return "Available"
            case 4: return "Partly available"
            case 3: return "Requested"
            case 2: return "Waiting for approval"
            default: return nil
            }
        }
    }

    struct Request: Identifiable, Hashable {
        let id: Int
        let status: Int   // 1 pending, 2 approved, 3 declined
        let mediaType: String
        let tmdbId: Int
        let requestedBy: String
        let mediaStatus: Int?
        var title: String?
        var posterPath: String?
    }

    private(set) var baseURL: URL?
    private(set) var signedIn = false
    private(set) var canManage = false
    private(set) var userName: String?

    @ObservationIgnored private var accountKey: String?
    /// Each Prism profile keeps its own Seerr sign-in (cookies aren't shared between profiles).
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()
    @ObservationIgnored private var cookie: String?

    private init() {}

    var isConfigured: Bool { baseURL != nil && signedIn }
    /// Found Seerr, but this profile hasn't signed in to it yet.
    var needsSignIn: Bool { baseURL != nil && !signedIn }

    /// Find Seerr for this Prism profile (saved, or found next to the Jellyfin server) and check the sign-in.
    func activate(accountKey: String?, jellyfinURL: String? = nil) async {
        guard accountKey != self.accountKey || baseURL == nil else { return }
        self.accountKey = accountKey
        signedIn = false
        canManage = false
        cookie = accountKey.flatMap { Keychain.load("seerr.\($0)") }.flatMap { String(data: $0, encoding: .utf8) }
        if let key = accountKey, let raw = UserDefaults.standard.string(forKey: "prism.seerr.\(key)"), let url = URL(string: raw) {
            baseURL = url
        } else {
            baseURL = await Self.discover(near: jellyfinURL)
        }
        if baseURL != nil, cookie != nil { await refreshMe() }
    }

    /// Seerr usually lives at requests.<your Jellyfin domain>. Confirm it's a Seerr that uses Jellyfin.
    static func discover(near jellyfinURL: String?) async -> URL? {
        guard let raw = jellyfinURL, let host = URL(string: raw)?.host, !host.isEmpty,
              host.contains("."), Int(host.split(separator: ".").last ?? "") == nil else { return nil }
        let parts = host.split(separator: ".")
        let root = parts.count > 2 && parts.first != "www" && !host.hasSuffix(".duckdns.org") ? parts.dropFirst().joined(separator: ".") : host
        let candidates = ["requests.\(host)", "requests.\(root)", "seerr.\(root)", "jellyseerr.\(root)", "request.\(root)"]
        var seen = Set<String>()
        for h in candidates where seen.insert(h).inserted {
            guard let url = URL(string: "https://\(h)"),
                  let probe = URL(string: "https://\(h)/api/v1/settings/public") else { continue }
            var req = URLRequest(url: probe)
            req.timeoutInterval = 4
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["initialized"] as? Bool == true, (obj["mediaServerType"] as? Int) == 2 {
                return url
            }
        }
        return nil
    }

    /// Sign in to requests with the same username and password used for Prism (right after Prism sign-in).
    func autoConnect(accountKey: String, jellyfinURL: String, username: String, password: String) async {
        self.accountKey = nil
        await activate(accountKey: accountKey, jellyfinURL: jellyfinURL)
        guard let base = baseURL, !signedIn else { return }
        try? await signIn(address: base.absoluteString, username: username, password: password)
    }

    func signIn(address: String, username: String, password: String) async throws {
        var raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw) else { throw JellyfinError.badURL }
        baseURL = url
        _ = try await call("POST", "auth/jellyfin", body: ["username": username, "password": password])
        if let key = accountKey { UserDefaults.standard.set(raw, forKey: "prism.seerr.\(key)") }
        await refreshMe()
        if !signedIn { throw JellyfinError.http(401) }
    }

    func signOut() async {
        _ = try? await call("POST", "auth/logout")
        if let key = accountKey {
            UserDefaults.standard.removeObject(forKey: "prism.seerr.\(key)")
            Keychain.delete("seerr.\(key)")
        }
        cookie = nil
        signedIn = false
    }

    private func refreshMe() async {
        guard let obj = try? await call("GET", "auth/me") as? [String: Any], obj["id"] != nil else {
            signedIn = false
            return
        }
        signedIn = true
        userName = obj["displayName"] as? String ?? obj["jellyfinUsername"] as? String
        let perms = obj["permissions"] as? Int ?? 0
        canManage = perms & 2 != 0 || perms & 16 != 0   // ADMIN or MANAGE_REQUESTS
    }

    // MARK: Browse & request

    func search(_ q: String) async -> [Result] {
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        guard let obj = try? await call("GET", "search?query=\(encoded)&page=1") as? [String: Any] else { return [] }
        return parse(obj["results"])
    }

    func trending() async -> [Result] {
        guard let obj = try? await call("GET", "discover/trending?page=1") as? [String: Any] else { return [] }
        return parse(obj["results"])
    }

    func request(_ r: Result) async throws {
        var body: [String: Any] = ["mediaType": r.mediaType, "mediaId": r.id]
        if r.mediaType == "tv" { body["seasons"] = "all" }
        _ = try await call("POST", "request", body: body)
    }

    func requests() async -> [Request] {
        guard let obj = try? await call("GET", "request?take=40&skip=0&sort=added&filter=all") as? [String: Any],
              let list = obj["results"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let id = r["id"] as? Int, let media = r["media"] as? [String: Any],
                  let tmdb = media["tmdbId"] as? Int else { return nil }
            let by = (r["requestedBy"] as? [String: Any])?["displayName"] as? String ?? ""
            return Request(id: id, status: r["status"] as? Int ?? 1, mediaType: media["mediaType"] as? String ?? "movie",
                           tmdbId: tmdb, requestedBy: by, mediaStatus: media["status"] as? Int)
        }
    }

    func details(_ r: Request) async -> (title: String?, poster: String?) {
        guard let obj = try? await call("GET", "\(r.mediaType == "tv" ? "tv" : "movie")/\(r.tmdbId)") as? [String: Any]
        else { return (nil, nil) }
        return ((obj["title"] ?? obj["name"]) as? String, obj["posterPath"] as? String)
    }

    func approve(_ id: Int) async throws { _ = try await call("POST", "request/\(id)/approve") }
    func decline(_ id: Int) async throws { _ = try await call("POST", "request/\(id)/decline") }

    private func parse(_ raw: Any?) -> [Result] {
        (raw as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? Int, let type = r["mediaType"] as? String, type == "movie" || type == "tv" else { return nil }
            let date = (r["releaseDate"] ?? r["firstAirDate"]) as? String
            return Result(id: id, mediaType: type, title: (r["title"] ?? r["name"]) as? String ?? "Untitled",
                          year: date.map { String($0.prefix(4)) }, overview: r["overview"] as? String,
                          posterPath: r["posterPath"] as? String,
                          status: (r["mediaInfo"] as? [String: Any])?["status"] as? Int)
        }
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        guard let base = baseURL, let url = URL(string: base.absoluteString + "/api/v1/" + path) else { throw JellyfinError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            // Keep the session cookie Seerr hands out at sign-in, per profile.
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            let found = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { $0.name == "connect.sid" }
            if let c = found.first {
                cookie = "\(c.name)=\(c.value)"
                if let key = accountKey, let d = cookie?.data(using: .utf8) { Keychain.save(d, key: "seerr.\(key)") }
            }
            if !(200..<300).contains(http.statusCode) { throw JellyfinError.http(http.statusCode) }
        }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }
}
