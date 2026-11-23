import SwiftUI

/// An image from the server.
struct TVImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            if let img = phase.image { img.resizable().aspectRatio(contentMode: contentMode) }
            else { Rectangle().fill(Color.white.opacity(0.06)) }
        }
    }
}

struct TVProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.spectrum).frame(width: g.size.width * min(1, max(0, value)))
            }
        }.frame(height: 6)
    }
}

/// Opens the right thing for an item when picked: plays videos, opens everything else.
@MainActor func open(_ item: BaseItem, app: AppState) -> Bool {
    if item.isLiveChannel { AppRouter.shared.playRequest = PlaybackRequest(item: item, startTicks: 0); return true }
    if item.type == "Audio" { AudioPlayer.shared.play([item], client: app.client); return true }
    return false
}

/// A poster that lifts and tilts when focused (the Apple TV "card" look).
struct TVPosterCard: View {
    let item: BaseItem
    var width: CGFloat = 250
    @Environment(AppState.self) private var app
    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottom) {
                TVImage(url: app.client?.posterURL(for: item, width: Int(width * 2)))
                if let p = item.progress { TVProgress(value: p).padding(12) }
                if item.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Theme.green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                }
            }
            .frame(width: width, height: width * 1.5)
        }
        .buttonStyle(.card)
    }
}

/// A wide card with the title underneath, for episodes and Continue Watching.
struct TVLandscapeCard: View {
    let item: BaseItem
    var width: CGFloat = 460
    var subtitle: String?
    var action: (() -> Void)?
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let action { Button(action: action) { art } } else { NavigationLink(value: item) { art } }
            }.buttonStyle(.card)
            Text(item.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Text(subtitle ?? item.episodeLabel ?? item.productionYear.map(String.init) ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: width)
    }
    private var art: some View {
        ZStack(alignment: .bottom) {
            TVImage(url: app.client?.landscapeURL(for: item, width: Int(width * 2)))
            if let p = item.progress { TVProgress(value: p).padding(14) }
        }.frame(width: width, height: width * 9 / 16)
    }
}

struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold()).padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 44) { content }.padding(.horizontal, 80).padding(.vertical, 30)
            }.scrollClipDisabled()
        }
    }
}

extension View {
    /// Every screen opens items the same way.
    func itemDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { TVItemRoute(item: $0) }
    }
}
