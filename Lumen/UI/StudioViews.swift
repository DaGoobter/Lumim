import SwiftUI

/// Remembers the brand list per server for this launch so switching tabs is instant.
@MainActor @Observable
final class StudioCatalog {
    static let shared = StudioCatalog()
    private(set) var brands: [StudioBrand] = []
    private(set) var loadedFor: String?
    var error: String?

    func load(_ client: JellyfinClient, force: Bool = false) async {
        let key = client.baseURL.absoluteString + (client.userId ?? "")
        guard force || loadedFor != key else { return }
        do {
            brands = StudioBrands.build(from: try await client.studioIndex())
            loadedFor = key
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension Theme {
    static let spectrumColors: [Color] = [red, orange, yellow, green, blue, violet]
}

/// Grid of studio or network brands, with a search box.
struct StudioGridView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let kind: StudioBrand.Kind
    @State private var catalog = StudioCatalog.shared
    @State private var search = ""

    private var shown: [StudioBrand] {
        let list = catalog.brands.filter { $0.kind == kind }
        guard !search.isEmpty else { return list }
        return list.filter { b in
            b.name.localizedCaseInsensitiveContains(search) || b.members.contains { $0.name.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(kind == .studio ? "Find a studio" : "Find a network", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let error = catalog.error, catalog.brands.isEmpty {
                ErrorBanner(message: error) { Task { if let c = app.client { await catalog.load(c, force: true) } } }
            } else if catalog.loadedFor == nil {
                ProgressView().padding(.top, 60)
            } else if shown.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Nothing here yet" : "No matches",
                                       systemImage: kind == .studio ? "film.stack" : "tv",
                                       description: Text(search.isEmpty
                                           ? "Your server hasn't tagged any \(kind == .studio ? "studios" : "networks") yet."
                                           : "Try another name."))
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 220 : 150), spacing: 12)], spacing: 12) {
                    ForEach(shown) { brand in
                        NavigationLink(value: brand) { StudioTile(brand: brand) }
                            .buttonStyle(CardPressStyle())
                    }
                }
            }
        }
        .padding(.horizontal)
        .task { if let c = app.client { await catalog.load(c) } }
    }
}

/// A brand card washed in two spectrum colours.
struct StudioTile: View {
    let brand: StudioBrand

    var body: some View {
        let (a, b) = brand.hues
        ZStack(alignment: .bottomLeading) {
            Theme.card
            RadialGradient(colors: [Theme.spectrumColors[a], .clear], center: UnitPoint(x: 0.25, y: 0.2),
                           startRadius: 0, endRadius: 170)
            RadialGradient(colors: [Theme.spectrumColors[b].opacity(0.9), .clear], center: UnitPoint(x: 0.85, y: 0.95),
                           startRadius: 0, endRadius: 160)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name).font(.title3.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.7)
                Text(brand.countText).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.82))
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Everything from one studio or network: chips for its companies, All/Movies/Shows, and sorting.
struct StudioBrandView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let brand: StudioBrand

    enum Show: String, CaseIterable, Identifiable { case all = "All", movies = "Movies", shows = "Shows"; var id: String { rawValue } }

    @State private var member: StudioBrand.Member?
    @State private var show: Show = .all
    @State private var sort: LibraryGridView.Sort = .added
    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0

    private var types: String {
        switch show {
        case .all: return brand.movieCount > 0 && brand.showCount > 0 ? "Movie,Series" : (brand.showCount > 0 ? "Series" : "Movie")
        case .movies: return "Movie"
        case .shows: return "Series"
        }
    }

    var body: some View {
        let (a, b) = brand.hues
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(brand.kind == .studio ? "STUDIO" : "NETWORK")
                    .font(.footnote.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.75))
                Text(brand.name).font(.system(size: 44, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                Text(brand.countText).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.top, 8)

            if brand.members.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", on: member == nil) { member = nil }
                        ForEach(brand.members, id: \.self) { m in
                            chip(m.name, on: member == m) { member = m }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 12)
            }

            HStack {
                if brand.movieCount > 0 && brand.showCount > 0 {
                    Picker("Show", selection: $show) {
                        ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 240)
                }
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibraryGridView.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label(sort == .added ? "Recently added" : sort.rawValue, systemImage: "chevron.down")
                        .labelStyle(TrailingIconLabel()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal).padding(.top, 10)

            if let error { ErrorBanner(message: error) { Task { await reload() } } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 104), spacing: 12)], spacing: 18) {
                ForEach(items) { item in
                    NavigationLink(value: item) { PosterCard(item: item, fixedWidth: false) }
                        .buttonStyle(CardPressStyle())
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
        }
        .background(alignment: .top) {
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.spectrumColors[a].opacity(0.55), .clear], center: UnitPoint(x: 0.2, y: 0),
                               startRadius: 0, endRadius: 320)
                RadialGradient(colors: [Theme.spectrumColors[b].opacity(0.4), .clear], center: UnitPoint(x: 1, y: 0.15),
                               startRadius: 0, endRadius: 280)
            }
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .ignoresSafeArea()
        }
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await loadMore() } }
        .onChange(of: member) { Task { await reload() } }
        .onChange(of: show) { Task { await reload() } }
        .onChange(of: sort) { Task { await reload() } }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.bold)).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .background(on ? Color.white : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : Color.white.opacity(0.16)))
                .foregroundStyle(on ? Theme.ink : .white)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func reload() async {
        generation += 1
        items = []; total = Int.max; loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard let client = app.client, !loading, items.count < total else { return }
        loading = true
        let gen = generation
        let (by, order) = sort.api
        do {
            let r = try await client.browse([
                "studioIds": member?.id ?? brand.studioIds, "includeItemTypes": types, "recursive": "true",
                "sortBy": by, "sortOrder": order, "startIndex": String(items.count), "limit": "60",
                "enableImageTypes": "Primary,Backdrop,Thumb",
            ])
            guard gen == generation else { return }
            items += r.items
            total = r.totalRecordCount ?? items.count
            error = nil
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
        if gen == generation { loading = false }
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.title; configuration.icon.imageScale(.small) }
    }
}
