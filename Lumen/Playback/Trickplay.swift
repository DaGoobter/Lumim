import SwiftUI

/// Scrubbing preview pictures from the server's trickplay images (sheets of small frames, one every few seconds).
@MainActor
final class TrickplayThumbs {
    let info: TrickplayInfo
    private let sourceId: String
    private let itemId: String
    private let client: JellyfinClient
    private var tiles: [Int: UIImage] = [:]

    private init(info: TrickplayInfo, sourceId: String, itemId: String, client: JellyfinClient) {
        self.info = info; self.sourceId = sourceId; self.itemId = itemId; self.client = client
    }

    /// This file's thumbnails, preferring a width that looks sharp in the preview. Nil when the server has none.
    static func load(client: JellyfinClient, itemId: String, mediaSourceId: String?) async -> TrickplayThumbs? {
        let x = await client.playbackExtras(itemId: itemId)
        guard let (sid, sizes) = (mediaSourceId.flatMap { id in x.trickplay[id].map { (id, $0) } }) ?? x.trickplay.first else { return nil }
        let sorted = sizes.values.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let best = sorted.first(where: { ($0.width ?? 0) >= 320 }) ?? sorted.last else { return nil }
        return TrickplayThumbs(info: best, sourceId: sid, itemId: itemId, client: client)
    }

    /// Changes only when the picture would change (for SwiftUI's .task(id:)).
    func frameIndex(at seconds: Double) -> Int { Int(seconds * 1000) / max(1, info.interval ?? 10_000) }

    /// The thumbnail for a time, cut out of its sheet (sheets are downloaded once and kept).
    func thumbnail(at seconds: Double) async -> UIImage? {
        guard let width = info.width, let interval = info.interval, interval > 0,
              let tw = info.tileWidth, let th = info.tileHeight, tw > 0, th > 0 else { return nil }
        let perTile = tw * th
        let count = info.thumbnailCount ?? Int.max
        let frame = min(max(0, Int(seconds * 1000) / interval), max(0, count - 1))
        let tileIndex = frame / perTile
        let tile: UIImage
        if let cached = tiles[tileIndex] {
            tile = cached
        } else {
            var req = URLRequest(url: client.trickplayTileURL(itemId: itemId, width: width, index: tileIndex, mediaSourceId: sourceId))
            req.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: data) else { return nil }
            tiles[tileIndex] = img
            tile = img
        }
        guard let cg = tile.cgImage else { return nil }
        let cellW = cg.width / tw, cellH = cg.height / th
        let inTile = frame % perTile
        guard let cut = cg.cropping(to: CGRect(x: (inTile % tw) * cellW, y: (inTile / tw) * cellH, width: cellW, height: cellH)) else { return nil }
        return UIImage(cgImage: cut)
    }
}

/// The preview above the progress bar while dragging: the picture at that moment (when there is one) and the time.
struct TrickplayBubble: View {
    let duration: Double
    let time: Double
    let hasPictures: Bool
    let image: UIImage?
    let timeText: String
    private let width: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
            let x = min(max(0, geo.size.width * fraction - width / 2), max(0, geo.size.width - width))
            VStack(spacing: 6) {
                if hasPictures {
                    ZStack {
                        Color.black
                        if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
                        else { ProgressView().tint(.white) }
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                }
                Text(timeText).font(.caption.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .frame(width: width)
            .offset(x: x, y: -(hasPictures ? width * 9 / 16 + 52 : 44))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        }
    }
}
