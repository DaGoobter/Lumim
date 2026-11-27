import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Hands Continue Watching to the iPhone widget / Apple TV Top Shelf (see Shared/WatchShelf.swift).
enum ShelfPublisher {
    static func publish(resume: [BaseItem], nextUp: [BaseItem], client: JellyfinClient) async {
        guard let folder = WatchShelf.folder else { return }
        var seen = Set<String>()
        let picks = (resume + nextUp).filter { seen.insert($0.id).inserted }.prefix(8)
        var items: [WatchShelf.Item] = []
        for (n, it) in picks.enumerated() {
            let art = client.thumbCardURL(for: it, width: 640)
            var file: String? = nil
            #if !os(tvOS)
            // The widget can't count on the network, so its pictures are saved next to the list.
            if let (data, resp) = try? await URLSession.shared.data(from: art), (resp as? HTTPURLResponse)?.statusCode == 200 {
                let name = "shelf-\(n).jpg"
                if (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil { file = name }
            }
            #endif
            let sub = it.type == "Episode" ? [it.episodeLabel, it.name].compactMap { $0 }.joined(separator: " · ")
                : (it.productionYear.map(String.init) ?? "")
            items.append(WatchShelf.Item(id: it.id, title: it.displayTitle, subtitle: sub,
                                         progress: (it.progress ?? 0), imageFile: file, imageURL: art.absoluteString))
        }
        guard items != WatchShelf.load() else { return }
        WatchShelf.save(items)
        #if canImport(WidgetKit) && !os(tvOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
