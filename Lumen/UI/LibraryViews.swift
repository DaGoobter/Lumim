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
                    NavigationLink(value: lib) {
                        Color.clear
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { RemoteImage(url: app.client?.imageURL(lib.id, maxWidth: 700, tag: lib.imageTag("primary"))) }
                            .overlay(alignment: .bottomLeading) {
                                Text(lib.name ?? "").font(.title3.bold()).padding(12)
                                    .shadow(color: .black, radius: 6)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Theme.background)
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
    @State private var sort: Sort = .added
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
                        .buttonStyle(.plain)
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
