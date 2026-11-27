import SwiftUI

struct LatestRow: Identifiable {
    let library: BaseItem
    let items: [BaseItem]
    var id: String { library.id }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latest: [LatestRow] = []
    @State private var myList: [BaseItem] = []
    @State private var collections: [BaseItem] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var playRequest: PlaybackRequest?
    @State private var detailItem: BaseItem?
    @State private var featuredIndex = 0
    @State private var heroColor: ArtColor?

    /// Apple TV–style featured banner: what you're watching, then the newest additions.
    private var featured: [BaseItem] {
        var out: [BaseItem] = []
        var seen = Set<String>()
        let candidates = Array(resume.prefix(2)) + latest.flatMap { Array($0.items.prefix(3)) }
        for item in candidates where !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        return Array(out.prefix(7))
    }

    private var currentFeatured: BaseItem? {
        featured.indices.contains(featuredIndex) ? featured[featuredIndex] : featured.first
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = verticalSizeClass == .compact
            // Portrait: a tall, edge-to-edge hero with the title and buttons laid over the bottom of the picture.
            let artHeight = landscape
                ? geo.size.height * 0.82
                : min(geo.size.width * (sizeClass == .regular ? 0.75 : 1.12), geo.size.height * (sizeClass == .regular ? 0.62 : 0.68))
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    if !featured.isEmpty {
                        FeaturedCarousel(items: featured, index: $featuredIndex, width: geo.size.width,
                                         artHeight: artHeight, landscape: landscape) { item in Task { await play(item) } }
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
                        Shelf("Up Next") {
                            ForEach(nextUp) { item in playableCard(item) }
                        }
                    }

                    if !myList.isEmpty {
                        Shelf("My List") {
                            ForEach(myList) { item in
                                NavigationLink(value: item) { PosterCard(item: item) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                    }

                    ForEach(latest) { row in
                        Shelf("New in \(row.library.name ?? "Library")") {
                            ForEach(row.items) { item in
                                NavigationLink(value: item) { PosterCard(item: item) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                    }

                    if !collections.isEmpty {
                        Shelf("Collections") {
                            ForEach(collections) { item in
                                NavigationLink(value: item) { PosterCard(item: item) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                    }

                    if !loaded && error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 40)
            }
            // Artwork runs to the very top, under the Dynamic Island.
            .ignoresSafeArea(edges: .top)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    TintedBackdrop(color: heroColor)
                    AmbientGlow(url: currentFeatured.flatMap { app.client?.backdropURL(for: $0, width: 600) },
                                size: geo.size)
                }
            }
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) { AccountButton().padding(.trailing, 18).padding(.top, 6) }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .artColor(from: currentFeatured.flatMap { app.client?.backdropURL(for: $0, width: 400) }, into: $heroColor)
        .onChange(of: featured.count) { _, count in if featuredIndex >= count { featuredIndex = 0 } }
        .navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
        .navigationDestination(item: $detailItem) { ItemRouter(item: $0) }
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await load() } }) { PlayerScreen(request: $0) }
    }

    /// Tap plays immediately; long-press offers details.
    private func playableCard(_ item: BaseItem) -> some View {
        Button { Task { await play(item) } } label: { LandscapeCard(item: item, titleArt: true) }
            .buttonStyle(CardPressStyle())
            .contextMenu {
                Button { Task { await play(item) } } label: { Label("Play", systemImage: "play.fill") }
                Button { detailItem = item } label: { Label("Details", systemImage: "info.circle") }
            }
    }

    /// Movies/episodes play directly; a show plays its next episode.
    private func play(_ item: BaseItem) async {
        if item.isSeries {
            guard let client = app.client,
                  let next = await client.firstEpisode(seriesId: item.id) else {
                detailItem = item
                return
            }
            playRequest = PlaybackRequest(item: next, startTicks: next.resumeTicks)
        } else if item.isPlayable {
            playRequest = PlaybackRequest(item: item, startTicks: item.resumeTicks)
        } else {
            detailItem = item
        }
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
            Task.detached(priority: .utility) { await ShelfPublisher.publish(resume: resumeItems, nextUp: nextItems, client: client) }

            let skip: Set<String> = ["music", "books", "playlists", "livetv", "photos", "boxsets"]
            var rows: [LatestRow] = []
            for lib in views where !skip.contains(lib.collectionType ?? "") {
                if let items = try? await client.latest(parentId: lib.id), !items.isEmpty {
                    rows.append(LatestRow(library: lib, items: items))
                }
            }
            latest = rows
            async let fav = client.favorites()
            async let col = client.collections()
            (myList, collections) = await (fav, col)
            error = nil
        } catch {
            self.error = "Can't reach your server. Downloads still work offline."
        }
        loaded = true
    }
}

/// Swipeable, auto-advancing banner.
struct FeaturedCarousel: View {
    let items: [BaseItem]
    @Binding var index: Int
    let width: CGFloat
    let artHeight: CGFloat
    var landscape = false
    let onPlay: (BaseItem) -> Void

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HeroView(item: item, width: width, artHeight: artHeight, landscape: landscape,
                         page: i, pageCount: items.count) { onPlay(item) }
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: landscape ? artHeight + 16 : artHeight)
        // Advance every 8 seconds; swiping restarts the timer.
        .task(id: index) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
    }
}

/// Which page of the banner you're on, in a small frosted pill.
struct PageDots: View {
    let page: Int
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.white : Color.white.opacity(0.4))
                    .frame(width: i == page ? 18 : 7, height: 7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct HeroView: View {
    @Environment(AppState.self) private var app
    let item: BaseItem
    let width: CGFloat
    let artHeight: CGFloat
    var landscape = false
    var page = 0
    var pageCount = 1
    let onPlay: () -> Void

    private var meta: String? {
        if let ep = item.episodeLabel { return [ep, item.name].compactMap { $0 }.joined(separator: " · ") }
        return item.heroMetaLine
    }

    private var playTitle: String {
        if item.progress != nil { return item.timeLeftText.map { "Resume · \($0)" } ?? "Resume" }
        return "Play"
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoOrTitle(url: app.client?.logoURL(for: item), title: item.displayTitle, maxHeight: landscape ? 70 : 96)
                .padding(.bottom, 4)
            if let meta {
                Text(meta).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            if let overview = item.overview, !overview.isEmpty {
                Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(landscape ? 3 : 2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    Label(playTitle, systemImage: "play.fill").lineLimit(1)
                }
                .buttonStyle(PlayButtonStyle())
                Spacer(minLength: 0)
                if pageCount > 1 { PageDots(page: page, count: pageCount) }
            }
            .padding(.top, 6)
        }
    }

    var body: some View {
        if landscape {
            // Phone landscape: info on the left, artwork on the right — everything fits on one screen.
            HStack(alignment: .center, spacing: 24) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink(value: item) {
                    ArtHeader(url: app.client?.backdropURL(for: item, width: 1920), width: width * 0.56, maxHeight: artHeight)
                }
                .buttonStyle(CardPressStyle())
            }
            .padding(.leading, 24)
            .padding(.top, 12)
            .frame(width: width, height: artHeight + 16, alignment: .leading)
        } else {
            ZStack(alignment: .bottomLeading) {
                // Edge-to-edge picture that melts into the page; tap it for details.
                NavigationLink(value: item) {
                    Color.clear
                        .frame(width: width, height: artHeight)
                        .overlay { RemoteImage(url: app.client?.backdropURL(for: item, width: 1920)) }
                        .clipped()
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0.35),
                                .init(color: .black.opacity(0.55), location: 0.8),
                                .init(color: .black.opacity(0.7), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.78),
                                .init(color: .black.opacity(0), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        )
                }
                .buttonStyle(.plain)
                info
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            .frame(width: width, height: artHeight)
        }
    }
}
