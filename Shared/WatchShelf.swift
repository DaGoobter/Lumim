import Foundation

/// Continue Watching, shared from the app to the iPhone widget and the Apple TV Top Shelf.
/// Kept in the app group's shared folder; when that isn't available (some sideloading tools don't set it up),
/// the widget and Top Shelf simply show "Open Huefin".
enum WatchShelf {
    #if os(tvOS)
    static let groupID = "group.com.lumenplayer.tv"
    #else
    static let groupID = "group.com.lumenplayer.app"
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

    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    private static var listFile: URL? { folder?.appendingPathComponent("continue-watching.json") }

    static func load() -> [Item] {
        guard let f = listFile, let data = try? Data(contentsOf: f) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func save(_ items: [Item]) {
        guard let f = listFile, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: f, options: .atomic)
    }

    /// Opening a deep link: huefin://play/<id> plays, huefin://item/<id> shows the page.
    static func playURL(_ id: String) -> URL { URL(string: "huefin://play/\(id)")! }
    static func itemURL(_ id: String) -> URL { URL(string: "huefin://item/\(id)")! }
}
