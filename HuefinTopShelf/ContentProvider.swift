import TVServices

/// Apple TV Top Shelf: when Huefin is highlighted on the Home Screen, Continue Watching appears above it,
/// and clicking an item plays it.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        let items = WatchShelf.load()
        guard !items.isEmpty else { return nil }
        let shelf = items.map { it -> TVTopShelfSectionedItem in
            let t = TVTopShelfSectionedItem(identifier: it.id)
            t.title = it.subtitle.isEmpty ? it.title : "\(it.title) · \(it.subtitle)"
            t.imageShape = .hdtv
            if let s = it.imageURL, let u = URL(string: s) { t.setImageURL(u, for: [.screenScale1x, .screenScale2x]) }
            if it.progress > 0 { t.playbackProgress = it.progress }
            t.playAction = TVTopShelfAction(url: WatchShelf.playURL(it.id))
            t.displayAction = TVTopShelfAction(url: WatchShelf.playURL(it.id))
            return t
        }
        let section = TVTopShelfItemCollection(items: shelf)
        section.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
