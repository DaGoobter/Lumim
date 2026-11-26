import SwiftUI

/// Apple TV: Studios & Networks, the same brands as on iPhone.
@MainActor @Observable
final class TVStudioCatalog {
    static let shared = TVStudioCatalog()
    private(set) var brands: [StudioBrand] = []
    private(set) var loaded = false

    func load(_ client: JellyfinClient) async {
        guard !loaded else { return }
        if let items = try? await client.studioIndex() {
            brands = StudioBrands.build(from: items)
            loaded = true
        }
    }
}

private let tvSpectrum: [Color] = [Theme.red, Theme.orange, Theme.yellow, Theme.green, Theme.blue, Theme.violet]

struct TVStudioGrid: View {
    let kind: StudioBrand.Kind
    @Environment(AppState.self) private var app
    @State private var catalog = TVStudioCatalog.shared

    var body: some View {
        let list = catalog.brands.filter { $0.kind == kind }
        Group {
            if !catalog.loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            } else if list.isEmpty {
                Text(kind == .studio ? "Your server hasn't tagged any studios yet." : "Your server hasn't tagged any networks yet.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 44) {
                    ForEach(list) { brand in
                        NavigationLink(value: brand) { TVStudioTile(brand: brand) }.buttonStyle(.card)
                    }
                }
            }
        }
        .task { if let c = app.client { await catalog.load(c) } }
    }
}

struct TVStudioTile: View {
    let brand: StudioBrand
    var body: some View {
        let (a, b) = brand.hues
        ZStack(alignment: .bottomLeading) {
            Theme.card
            RadialGradient(colors: [tvSpectrum[a], .clear], center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [tvSpectrum[b].opacity(0.9), .clear], center: UnitPoint(x: 0.85, y: 0.95), startRadius: 0, endRadius: 240)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(brand.name).font(.title3.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.7)
                Text(brand.countText).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.82))
            }
            .foregroundStyle(.white).padding(22)
        }
        .frame(height: 170)
    }
}

struct TVStudioBrandView: View {
    let brand: StudioBrand
    @Environment(AppState.self) private var app
    @State private var member: StudioBrand.Member?
    @State private var show = 0   // 0 all, 1 movies, 2 shows
    @State private var sort = "DateCreated,SortName"
    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var loadedKey: String?

    private var types: String {
        switch show {
        case 1: return "Movie"
        case 2: return "Series"
        default: return brand.movieCount > 0 && brand.showCount > 0 ? "Movie,Series" : (brand.showCount > 0 ? "Series" : "Movie")
        }
    }
    private var key: String { "\(member?.id ?? "")|\(show)|\(sort)" }

    var body: some View {
        let (a, b) = brand.hues
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(brand.kind == .studio ? "STUDIO" : "NETWORK").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(brand.name).font(.system(size: 64, weight: .heavy))
                    Text(brand.countText).font(.headline).foregroundStyle(.secondary)
                }
                if brand.members.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            Button("All") { member = nil }.buttonStyle(TVHueButtonStyle(filled: member == nil, hue: Theme.blue, expand: false))
                            ForEach(brand.members, id: \.self) { m in
                                Button(m.name) { member = m }.buttonStyle(TVHueButtonStyle(filled: member == m, hue: Theme.blue, expand: false))
                            }
                        }.padding(.vertical, 20)
                    }
                }
                HStack(spacing: 20) {
                    if brand.movieCount > 0 && brand.showCount > 0 {
                        ForEach(Array(["All", "Movies", "Shows"].enumerated()), id: \.offset) { i, t in
                            Button(t) { show = i }.buttonStyle(TVHueButtonStyle(filled: show == i, hue: Theme.blue, expand: false))
                        }
                    }
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        Text("Recently added").tag("DateCreated,SortName"); Text("Name").tag("SortName")
                        Text("Release date").tag("PremiereDate,ProductionYear,SortName"); Text("Rating").tag("CommunityRating,SortName")
                    }.pickerStyle(.menu)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 40)], spacing: 44) {
                    ForEach(items) { i in
                        TVPosterCard(item: i).onAppear { if i.id == items.last?.id { Task { await more() } } }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(80)
        }
        .background(alignment: .top) {
            ZStack {
                RadialGradient(colors: [tvSpectrum[a].opacity(0.5), .clear], center: UnitPoint(x: 0.15, y: 0), startRadius: 0, endRadius: 700)
                RadialGradient(colors: [tvSpectrum[b].opacity(0.35), .clear], center: UnitPoint(x: 1, y: 0.1), startRadius: 0, endRadius: 600)
            }
            .frame(height: 600).ignoresSafeArea()
        }
        .task(id: key) {
            if loadedKey == key && !items.isEmpty { return }
            loadedKey = key; items = []; total = .max; await more()
        }
    }

    private func more() async {
        guard let c = app.client, !loading, items.count < total else { return }
        loading = true
        let order = sort == "SortName" ? "Ascending" : "Descending"
        if let r = try? await c.browse([
            "studioIds": member?.id ?? brand.studioIds, "includeItemTypes": types, "recursive": "true",
            "sortBy": sort, "sortOrder": order, "startIndex": String(items.count), "limit": "120",
            "enableImageTypes": "Primary,Backdrop,Thumb",
        ]) {
            items += r.items; total = r.totalRecordCount ?? items.count
        } else { total = items.count }
        loading = false
    }
}
