import SwiftUI

struct LibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var views: [BaseItem] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error { ErrorBanner(message: error) { Task { await load() } }.padding(.top) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(views) { lib in
                    NavigationLink(value: lib) { LibraryTile(library: lib) }
                        .buttonStyle(CardPressStyle())
                }
            }
            .padding()
        }
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Library")
        .task { if views.isEmpty { await load() } }
        .refreshable { await load() }
        .navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
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
                LinearGradient(colors: [.clear, (color?.background ?? Theme.accent.opacity(0.5)).opacity(0.95)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(library.name ?? "").font(.title2.weight(.heavy)).padding(16)
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder((color?.accent ?? .white).opacity(0.35), lineWidth: 1))
            .shadow(color: (color?.background ?? .black).opacity(0.6), radius: 16, y: 8)
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

    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var sort: Sort = .name
    @State private var error: String?

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
        }
        .background(Theme.background)
        .navigationTitle(parent.name ?? "Library")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }
        .task { if items.isEmpty { await loadMore() } }
        .onChange(of: sort) { Task { await reload() } }
    }

    private func reload() async {
        items = []
        total = Int.max
        await loadMore()
    }

    private func loadMore() async {
        guard let client = app.client, !loading, items.count < total else { return }
        loading = true
        defer { loading = false }
        do {
            let (sortBy, order) = sort.api
            let r = try await client.items(parentId: parent.id, types: query.types, recursive: query.recursive,
                                           sortBy: sortBy, sortOrder: order, start: items.count, limit: 100)
            items += r.items
            total = r.totalRecordCount ?? items.count
            error = nil
        } catch {
            self.error = error.localizedDescription
            total = items.count
        }
    }
}
