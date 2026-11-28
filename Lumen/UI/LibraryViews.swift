import SwiftUI

struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var views: [BaseItem] = []
    @State private var error: String?
    /// Libraries, Studios or Networks; remembered between launches.
    @AppStorage("huefin.libraryMode") private var mode = "libraries"

    var body: some View {
        ScrollView {
            Picker("Browse by", selection: $mode) {
                Text("Libraries").tag("libraries")
                Text("Studios").tag("studios")
                Text("Networks").tag("networks")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.top, 4)

            switch mode {
            case "studios": StudioGridView(kind: .studio).padding(.vertical)
            case "networks": StudioGridView(kind: .network).padding(.vertical)
            default:
                if let error { ErrorBanner(message: error) { Task { await load() } }.padding(.top) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(views) { lib in
                        NavigationLink(value: lib) { LibraryTile(library: lib) }
                            .buttonStyle(CardPressStyle())
                    }
                }
                .padding()
            }
        }
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .task { if views.isEmpty { await load() } }
        .refreshable {
            if mode == "libraries" { await load() }
            else if let c = app.client { await StudioCatalog.shared.load(c, force: true) }
        }
        .navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
        .navigationDestination(for: StudioBrand.self) { StudioBrandView(brand: $0) }
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            views = try await client.userViews()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A library card washed in its artwork's own color.
struct LibraryTile: View {
    @Environment(AppState.self) private var app
    let library: BaseItem
    @State private var color: ArtColor?

    var body: some View {
        let url = app.client?.imageURL(library.id, maxWidth: 700, tag: library.imageTag("primary"))
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .overlay {
                LinearGradient(colors: [.clear, (color?.background ?? Color.accentColor.opacity(0.5)).opacity(0.95)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(library.name ?? "").font(Theme.display(24, .heavy, relativeTo: .title2)).padding(16)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .sticker(20)
            .artColor(from: url, into: $color)
    }
}

struct LibraryGridView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let parent: BaseItem

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", added = "Date Added", released = "Release Date", rating = "Rating"
        var id: String { rawValue }
        var api: (String, String) {
            switch self {
            case .name: return ("SortName", "Ascending")
            case .added: return ("DateCreated,SortName", "Descending")
            case .released: return ("PremiereDate,SortName", "Descending")
            case .rating: return ("CommunityRating,SortName", "Descending")
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unwatched = "Unwatched", watched = "Watched", favorites = "Favorites", inProgress = "In Progress"
        var id: String { rawValue }
        var api: String? {
            switch self {
            case .all: return nil
            case .unwatched: return "IsUnplayed"
            case .watched: return "IsPlayed"
            case .favorites: return "IsFavorite"
            case .inProgress: return "IsResumable"
            }
        }
    }

    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var sort: Sort = .name
    @State private var filter: Filter = .all
    @State private var genre: String?
    @State private var genreList: [String] = []
    @State private var error: String?
    @State private var generation = 0

    private var filtering: Bool { filter != .all || genre != nil }

    private var query: (types: String?, recursive: Bool) {
        switch parent.collectionType ?? "" {
        case "movies": return ("Movie", true)
        case "tvshows": return ("Series", true)
        case "boxsets": return ("BoxSet", true)
        default: return (nil, false)
        }
    }

    var body: some View {
        ScrollView {
            if let error { ErrorBanner(message: error) { Task { await reload() } }.padding(.top) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 104), spacing: 12)],
                      spacing: 18) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item, fixedWidth: false) }
                        .buttonStyle(CardPressStyle())
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
            if !loading && items.isEmpty && filtering && error == nil {
                ContentUnavailableView("Nothing matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try a different filter."))
                    .padding(.top, 60)
            }
        }
        .background(Theme.background)
        .navigationTitle(parent.name ?? "Library")
        .safeAreaInset(edge: .top, spacing: 0) {
            if filtering {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if filter != .all { chip(filter.rawValue) { filter = .all } }
                        if let genre { chip(genre) { self.genre = nil } }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                .background(.ultraThinMaterial)
            }
        }
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                if !genreList.isEmpty {
                    Picker("Genre", selection: $genre) {
                        Text("Any genre").tag(String?.none)
                        ForEach(genreList, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        .task { if items.isEmpty { await loadMore() } }
        .task { if genreList.isEmpty, let client = app.client { genreList = await client.genres(parentId: parent.id) } }
        .onChange(of: sort) { Task { await reload() } }
        .onChange(of: filter) { Task { await reload() } }
        .onChange(of: genre) { Task { await reload() } }
    }

    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 6) {
                Text(text)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.gradient, in: Capsule())
            .foregroundStyle(.white)
        }
    }

    private func reload() async {
        generation += 1
        items = []
        total = Int.max
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard let client = app.client, !loading, items.count < total else { return }
        loading = true
        let gen = generation
        defer { if gen == generation { loading = false } }
        do {
            let (sortBy, order) = sort.api
            // Filters apply to what's inside folders too, so search recursively when filtering.
            let r = try await client.items(parentId: parent.id, types: query.types,
                                           recursive: query.recursive || filtering,
                                           sortBy: sortBy, sortOrder: order, start: items.count, limit: 100,
                                           filters: filter.api, genres: genre)
            guard gen == generation else { return }
            items += r.items
            total = r.totalRecordCount ?? items.count
            error = nil
        } catch {
            self.error = error.localizedDescription
            total = items.count
        }
    }
}
