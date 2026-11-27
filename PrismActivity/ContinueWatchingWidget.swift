import WidgetKit
import SwiftUI

/// Home Screen widget: what you're in the middle of, one tap to keep watching.
struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ShelfProvider()) { entry in
            ContinueWatchingView(entry: entry)
                .containerBackground(Color(red: 0.035, green: 0.031, blue: 0.067), for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off in Huefin.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShelfEntry: TimelineEntry {
    let date: Date
    let items: [WatchShelf.Item]
}

struct ShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry { ShelfEntry(date: .now, items: []) }
    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        completion(ShelfEntry(date: .now, items: WatchShelf.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        // The app refreshes the widget whenever Home loads; this is just a safety net.
        completion(Timeline(entries: [ShelfEntry(date: .now, items: WatchShelf.load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ContinueWatchingView: View {
    let entry: ShelfEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.8))
                Text("Open Huefin to fill this in").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else if family == .systemSmall, let it = entry.items.first {
            card(it, big: true).widgetURL(WatchShelf.playURL(it.id))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Watching").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                let count = family == .systemLarge ? 4 : 2
                let rows = Array(entry.items.prefix(count))
                if family == .systemLarge {
                    ForEach(rows, id: \.id) { it in Link(destination: WatchShelf.playURL(it.id)) { row(it) } }
                } else {
                    HStack(spacing: 10) {
                        ForEach(rows, id: \.id) { it in Link(destination: WatchShelf.playURL(it.id)) { card(it, big: false) } }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func image(_ it: WatchShelf.Item) -> some View {
        ZStack {
            Color.white.opacity(0.08)
            if let name = it.imageFile, let folder = WatchShelf.folder,
               let ui = UIImage(contentsOfFile: folder.appendingPathComponent(name).path) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func bar(_ p: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: g.size.width * max(0.03, p))
            }
        }
        .frame(height: 3)
    }

    private func card(_ it: WatchShelf.Item, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            image(it).aspectRatio(16 / 9, contentMode: .fit)
            if it.progress > 0 { bar(it.progress) }
            Text(it.title).font(.caption.weight(.semibold)).lineLimit(1)
            if !it.subtitle.isEmpty { Text(it.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(big ? 2 : 1) }
        }
    }

    private func row(_ it: WatchShelf.Item) -> some View {
        HStack(spacing: 10) {
            image(it).frame(width: 110, height: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !it.subtitle.isEmpty { Text(it.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if it.progress > 0 { bar(it.progress) }
            }
        }
    }
}
