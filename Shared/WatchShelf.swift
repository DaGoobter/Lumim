import Foundation
import Security

/// Continue Watching, shared from the app to the iPhone widget and the Apple TV Top Shelf.
/// Kept in the app group's shared folder; when that isn't available (some sideloading tools don't set it up),
/// the widget and Top Shelf simply show "Open Huefin".
enum WatchShelf {
    #if os(tvOS)
    static let groupID = "group.app.huefin.tvshelf"
    #else
    static let groupID = "group.app.huefin.phone"
    #endif

    struct Item: Codable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        /// 0…1 watched.
        let progress: Double
        /// Picture saved next to the list (iPhone widget), or a web address (Apple TV Top Shelf).
        let imageFile: String?
        let imageURL: String?
    }

    /// Sideloading tools rename the group when they re-sign (often adding the Apple ID's team code),
    /// so use whichever group the installed copy was actually given, read from its provisioning profile.
    static let profile: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex) else { return nil }
        return try? PropertyListSerialization.propertyList(from: raw[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
    }()
    private static var entitlements: [String: Any] { profile?["Entitlements"] as? [String: Any] ?? [:] }
    static let grantedGroups: [String] = entitlements["com.apple.security.application-groups"] as? [String] ?? []

    static var folder: URL? {
        let fm = FileManager.default
        let candidates = grantedGroups.filter { $0.hasPrefix(groupID) } + [groupID] + grantedGroups
        for id in candidates { if let u = fm.containerURL(forSecurityApplicationGroupIdentifier: id) { return u } }
        return nil
    }
    private static var listFile: URL? { folder?.appendingPathComponent("continue-watching.json") }

    static func load() -> [Item] {
        let data = listFile.flatMap { try? Data(contentsOf: $0) } ?? keychainRead()
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func save(_ items: [Item]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        if let f = listFile { try? data.write(to: f, options: .atomic) }
        _ = keychainWrite(data)
    }

    // MARK: Second route: the keychain
    // When the install gives no shared folder, the app and widget can still usually share a keychain item:
    // apps sideloaded with the same Apple ID are allowed a keychain group under that Apple ID's team code.

    private static let service = "huefin.shelf", account = "continue-watching"

    /// Keychain groups this install is allowed, most likely first.
    static var keychainGroups: [String] {
        var out: [String] = []
        for g in entitlements["keychain-access-groups"] as? [String] ?? [] {
            out.append(g.hasSuffix(".*") ? String(g.dropLast(1)) + "com.huefin.shelf" : g)
        }
        let team = (profile?["ApplicationIdentifierPrefix"] as? [String])?.first ?? (profile?["TeamIdentifier"] as? [String])?.first
        if let team { out.append("\(team).com.huefin.shelf") }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted && !$0.contains("$(") }
    }

    private static var usableGroupKey: String { "huefin.shelf.keychainGroup" }

    /// True when the app managed to share through the keychain (shown in Settings).
    static var keychainWorks: Bool { UserDefaults.standard.string(forKey: usableGroupKey) != nil }

    @discardableResult
    static func keychainWrite(_ data: Data) -> Bool {
        for g in keychainGroups {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrAccessGroup as String: g]
            SecItemDelete(q as CFDictionary)
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
                UserDefaults.standard.set(g, forKey: usableGroupKey)
                return true
            }
        }
        UserDefaults.standard.removeObject(forKey: usableGroupKey)
        return false
    }

    static func keychainRead() -> Data? {
        for g in keychainGroups {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrAccessGroup as String: g,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }

    /// Opening a deep link: huefin://play/<id> plays, huefin://item/<id> shows the page.
    static func playURL(_ id: String) -> URL { URL(string: "huefin://play/\(id)")! }
    static func itemURL(_ id: String) -> URL { URL(string: "huefin://item/\(id)")! }
}
