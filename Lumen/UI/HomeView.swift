import SwiftUI

struct LatestRow: Identifiable {
    let library: BaseItem
    let items: [BaseItem]
    var id: String { library.id }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latest: [LatestRow] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var playRequest: PlaybackRequest?
    @State private var detailItem: BaseItem?

    private var hero: BaseItem? { resume.first ?? nextUp.first ?? latest.first?.items.first }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let hero {
                    HeroView(item: hero, width: geo.size.width, maxHeight: geo.size.height * 0.5) { play(hero) }
                } else {
                    Spacer(minLength: 100)
                }

                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                }

                if !resume.isEmpty {
                    Shelf("Continue Watching") {
                        ForEach(resume) { item in playableCard(item) }
                    }
                }

                if !nextUp.isEmpty {
                    Shelf("Next Up") {
                        ForEach(nextUp) { item in playableCard(item) }
                    }
                }

                ForEach(latest) { row in
                    Shelf("Latest in \(row.library.name ?? "Library")") {
                        ForEach(row.items) { item in
                            NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                        }
                    }
                }

                if !loaded && error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 40)
        }
        .background(alignment: .top) {
            AmbientGlow(url: hero.flatMap { app.client?.backdropURL(for: $0, width: 600) }, size: geo.size)
        }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
        .navigationDestination(item: $detailItem) { ItemRouter(item: $0) }
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await load() } }) { PlayerScreen(request: $0) }
    }

    /// Tap plays immediately; long-press offers details.
    private func playableCard(_ item: BaseItem) -> some View {
        Button { play(item) } label: { LandscapeCard(item: item) }
            .buttonStyle(.plain)
            .contextMenu {
                Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
                Button { detailItem = item } label: { Label("Details", systemImage: "info.circle") }
            }
    }

    private func play(_ item: BaseItem) {
        playRequest = PlaybackRequest(item: item, startTicks: item.resumeTicks)
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            async let r = client.resume()
            async let n = client.nextUp()
            async let v = client.userViews()
            let (resumeItems, nextItems, views) = try await (r, n, v)
            resume = resumeItems
            nextUp = nextItems.filter { next in !resumeItems.contains { $0.id == next.id } }

            let skip: Set<String> = ["music", "books", "playlists", "livetv", "photos", "boxsets"]
            var rows: [LatestRow] = []
            for lib in views where !skip.contains(lib.collectionType ?? "") {
                if let items = try? await client.latest(parentId: lib.id), !items.isEmpty {
                    rows.append(LatestRow(library: lib, items: items))
                }
            }
            latest = rows
            error = nil
        } catch {
            self.error = "Can't reach your server. Downloads still work offline."
        }
        loaded = true
    }
}

struct HeroView: View {
    @Environment(AppState.self) private var app
    let item: BaseItem
    let width: CGFloat
    let maxHeight: CGFloat
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Full, uncropped artwork; tap it for details.
            NavigationLink(value: item) {
                ArtHeader(url: app.client?.backdropURL(for: item, width: 1920), width: width, maxHeight: maxHeight)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 12) {
                LogoOrTitle(url: app.client?.logoURL(for: item), title: item.displayTitle)
                if let ep = item.episodeLabel {
                    Text(ep).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else if let overview = item.overview {
                    Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let p = item.progress { ProgressBar(value: p).frame(maxWidth: 220) }
                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        Label(item.progress != nil ? "Resume" : "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal)
        }
    }
}
