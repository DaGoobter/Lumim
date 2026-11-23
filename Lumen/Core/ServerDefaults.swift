import SwiftUI

/// Prism settings an admin sets per person on the server (stored in Jellyfin's per-user display
/// preferences). Each phone applies them when the admin changes them; people can still adjust after.
enum ServerDefaults {
    static let prefsId = "usersettings"
    static let client = "prism"

    struct Values: Equatable {
        var maxBitrate: Int?
        var autoSkipIntro: Bool?
        var autoSkipCredits: Bool?
        var engine: String?
    }

    private static func load(_ api: JellyfinClient, userId: String) async -> [String: Any]? {
        guard let data = try? await api.send("DisplayPreferences/\(prefsId)", query: ["userId": userId, "client": client], method: "GET"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func read(_ api: JellyfinClient, userId: String) async -> (Values, version: String?) {
        let custom = (await load(api, userId: userId))?["CustomPrefs"] as? [String: Any] ?? [:]
        func str(_ k: String) -> String? { (custom[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let v = Values(maxBitrate: str("prism.maxBitrate").flatMap(Int.init),
                       autoSkipIntro: str("prism.autoSkipIntro").map { $0 == "true" },
                       autoSkipCredits: str("prism.autoSkipCredits").map { $0 == "true" },
                       engine: str("prism.engine"))
        return (v, str("prism.defaultsVersion"))
    }

    /// Admin: save defaults for someone.
    static func write(_ api: JellyfinClient, userId: String, values: Values) async throws {
        var obj = await load(api, userId: userId) ?? ["Id": prefsId, "Client": client, "SortBy": "SortName",
                                                       "SortOrder": "Ascending", "RememberIndexing": false,
                                                       "RememberSorting": false, "ScrollDirection": "Horizontal",
                                                       "ShowBackdrop": true, "ShowSidebar": false, "PrimaryImageHeight": 250,
                                                       "PrimaryImageWidth": 250, "CustomPrefs": [String: String]()]
        var custom = obj["CustomPrefs"] as? [String: Any] ?? [:]
        custom["prism.maxBitrate"] = values.maxBitrate.map(String.init) ?? ""
        custom["prism.autoSkipIntro"] = values.autoSkipIntro.map { $0 ? "true" : "false" } ?? ""
        custom["prism.autoSkipCredits"] = values.autoSkipCredits.map { $0 ? "true" : "false" } ?? ""
        custom["prism.engine"] = values.engine ?? ""
        custom["prism.defaultsVersion"] = String(Int(Date().timeIntervalSince1970))
        obj["CustomPrefs"] = custom
        try await api.send("DisplayPreferences/\(prefsId)", query: ["userId": userId, "client": client], body: obj)
    }

    /// Apply new defaults from the admin, once per change.
    @MainActor static func apply(app: AppState) async {
        guard let api = app.client, let uid = app.session?.userId else { return }
        let (v, version) = await read(api, userId: uid)
        guard let version else { return }
        let key = "prism.appliedDefaults.\(uid)"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        if let b = v.maxBitrate, b > 0 { app.maxBitrate = b; app.persistSettings() }
        if let x = v.autoSkipIntro { UserDefaults.standard.set(x, forKey: PlaybackPrefs.keys.autoIntro) }
        if let x = v.autoSkipCredits { UserDefaults.standard.set(x, forKey: PlaybackPrefs.keys.autoCredits) }
        if let x = v.engine { UserDefaults.standard.set(x, forKey: PlaybackPrefs.keys.engine) }
    }
}

/// Admin screen section: Prism defaults for one person.
struct PrismDefaultsSection: View {
    let client: JellyfinClient
    let userId: String
    @State private var values = ServerDefaults.Values()
    @State private var loaded = false
    @State private var status: String?

    var body: some View {
        Section {
            Picker("Streaming quality", selection: Binding(get: { values.maxBitrate ?? 0 }, set: { values.maxBitrate = $0 == 0 ? nil : $0 })) {
                Text("Their choice").tag(0)
                ForEach([200, 40, 20, 10, 8, 4], id: \.self) { Text($0 == 200 ? "Maximum" : "\($0) Mbps").tag($0 * 1_000_000) }
            }
            Picker("Skip intros", selection: Binding(get: { values.autoSkipIntro.map { $0 ? 1 : 2 } ?? 0 },
                                                     set: { values.autoSkipIntro = $0 == 0 ? nil : $0 == 1 })) {
                Text("Their choice").tag(0); Text("Automatically").tag(1); Text("Ask (button)").tag(2)
            }
            Picker("Credits", selection: Binding(get: { values.autoSkipCredits.map { $0 ? 1 : 2 } ?? 0 },
                                                 set: { values.autoSkipCredits = $0 == 0 ? nil : $0 == 1 })) {
                Text("Their choice").tag(0); Text("Go straight to next episode").tag(1); Text("Show countdown").tag(2)
            }
            Picker("Player", selection: Binding(get: { values.engine ?? "" }, set: { values.engine = $0.isEmpty ? nil : $0 })) {
                Text("Their choice").tag("")
                ForEach(PlaybackEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Button("Send to their Prism") {
                Task {
                    do { try await ServerDefaults.write(client, userId: userId, values: values); status = "Saved. Their Prism picks it up next time it opens." }
                    catch { status = "Couldn't save: \(error.localizedDescription)" }
                }
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Prism defaults")
        } footer: {
            Text("Set up Prism for them from here. They can still change things on their phone afterward.")
        }
        .task {
            guard !loaded else { return }
            loaded = true
            values = await ServerDefaults.read(client, userId: userId).0
        }
    }
}
