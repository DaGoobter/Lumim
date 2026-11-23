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
    private var session: URLSession { .shared }

    private init() {}

    var isConfigured: Bool { baseURL != nil && signedIn }

    /// Load the saved address for this Prism account and check the session.
    func activate(accountKey: String?) async {
        self.accountKey = accountKey
        signedIn = false
        canManage = false
        guard let key = accountKey, let raw = UserDefaults.standard.string(forKey: "prism.seerr.\(key)"),
              let url = URL(string: raw) else { baseURL = nil; return }
        baseURL = url
        await refreshMe()
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
        if let key = accountKey { UserDefaults.standard.removeObject(forKey: "prism.seerr.\(key)") }
        baseURL = nil
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
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JellyfinError.http(http.statusCode)
        }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }
}
