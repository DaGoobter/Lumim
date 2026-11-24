import SwiftUI

// MARK: Sign in

struct TVLoginView: View {
    @Environment(AppState.self) private var app
    var adding = false
    var done: (() -> Void)? = nil
    @AppStorage("tv.lastServer") private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var code: String?
    @State private var qcTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 140) {
            // Brand side.
            VStack(alignment: .leading, spacing: 34) {
                Image("Mark").resizable().scaledToFit().frame(width: 170, height: 170)
                    .padding(28).background(Theme.paper, in: RoundedRectangle(cornerRadius: 44))
                Text("huefin").font(.system(size: 130, weight: .black, design: .rounded))
                Capsule().fill(Theme.spectrum).frame(width: 260, height: 12)
                Text(adding ? "Add someone to this Apple TV" : "Connect to your Jellyfin server")
                    .font(.system(size: 42, weight: .medium)).foregroundStyle(.secondary)
                if let code {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("On your phone: Huefin → Settings → Quick Connect, and enter").font(.title3).foregroundStyle(.secondary)
                        Text(code).font(.system(size: 130, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.green)
                        HStack(spacing: 16) { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
                    }.padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Form side.
            VStack(alignment: .leading, spacing: 30) {
                field("Server", "e.g. 192.168.1.20:8096") {
                    TextField("Server address", text: $server)
                        .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                field("Username", nil) {
                    TextField("Username", text: $username).textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                field("Password", nil) { SecureField("Password", text: $password).textContentType(.password) }
                Button { signIn() } label: {
                    HStack(spacing: 16) { if busy && code == nil { ProgressView() }; Text("Sign In").bold() }
                }
                .buttonStyle(TVHueButtonStyle(filled: true))
                .disabled(busy || server.isEmpty || username.isEmpty)
                if code == nil {
                    Button { quickConnect() } label: { Label("Sign in with Quick Connect", systemImage: "qrcode") }
                        .buttonStyle(TVHueButtonStyle())
                        .disabled(busy || server.isEmpty)
                } else {
                    Button { qcTask?.cancel(); code = nil; busy = false } label: { Text("Cancel Quick Connect") }
                        .buttonStyle(TVHueButtonStyle())
                }
                if adding { Button { done?() } label: { Text("Cancel") }.buttonStyle(TVHueButtonStyle()) }
                if let error { Text(error).foregroundStyle(Theme.red).font(.title3) }
            }
            .frame(width: 900)
        }
        .padding(.horizontal, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.violet.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 1300)
                RadialGradient(colors: [Theme.red.opacity(0.32), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 1300)
            }
            .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .onDisappear { qcTask?.cancel() }
    }

    private func field<F: View>(_ label: String, _ hint: String?, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.headline).foregroundStyle(.secondary)
                if let hint { Text(hint).font(.callout).foregroundStyle(.tertiary) }
            }
            content().font(.title3)
        }
    }

    private func signIn() {
        busy = true; error = nil
        Task {
            do { try await app.login(server: server.trimmingCharacters(in: .whitespaces), username: username.trimmingCharacters(in: .whitespaces), password: password); done?() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func quickConnect() {
        busy = true; error = nil
        qcTask = Task {
            do {
                let start = try await app.quickConnectStart(server: server.trimmingCharacters(in: .whitespaces))
                code = start.code; busy = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    let state = try await start.client.quickConnectState(secret: start.secret)
                    if state.authenticated == true {
                        try await app.quickConnectFinish(client: start.client, info: start.info, secret: start.secret)
                        done?(); return
                    }
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; code = nil; busy = false }
        }
    }
}

// MARK: Home

struct TVHomeView: View {
    @Environment(AppState.self) private var app
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var myList: [BaseItem] = []
    @State private var latest: [(BaseItem, [BaseItem])] = []
    @State private var featured: BaseItem?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let f = featured { hero(f) }
                if !resume.isEmpty {
                    TVShelf(title: "Continue Watching") {
                        ForEach(resume) { i in TVLandscapeCard(item: i) { play(i) } }
                    }
                }
                if !nextUp.isEmpty {
                    TVShelf(title: "Up Next") { ForEach(nextUp) { i in TVLandscapeCard(item: i) { play(i) } } }
                }
                if !myList.isEmpty {
                    TVShelf(title: "My List") { ForEach(myList) { TVPosterCard(item: $0) } }
                }
                ForEach(latest, id: \.0.id) { lib, items in
                    TVShelf(title: "New in \(lib.name ?? "Library")") {
                        ForEach(items) { TVPosterCard(item: $0) }
                    }
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(100) }
            }.padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .horizontal)
        .itemDestinations()
        .task { await load() }
    }

    private func hero(_ f: BaseItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            TVImage(url: app.client?.backdropURL(for: f, width: 1920)).frame(height: 620).clipped()
            LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
            LinearGradient(colors: [Theme.background.opacity(0.9), .clear], startPoint: .leading, endPoint: .center)
            VStack(alignment: .leading, spacing: 18) {
                if let logo = app.client?.logoURL(for: f) { TVImage(url: logo, contentMode: .fit).frame(maxWidth: 560, maxHeight: 180, alignment: .leading) }
                else { Text(f.displayTitle).font(.system(size: 64, weight: .black)) }
                Text([f.episodeLabel, f.productionYear.map(String.init), f.officialRating, f.runtimeText].compactMap { $0 }.joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                Text(f.overview ?? "").lineLimit(3).frame(maxWidth: 900, alignment: .leading)
                HStack(spacing: 30) {
                    Button { play(f) } label: { Label((f.progress ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill") }
                    NavigationLink(value: f) { Label("Details", systemImage: "info.circle") }
                }
            }.padding(.horizontal, 80).padding(.bottom, 40)
        }
    }

    private func play(_ i: BaseItem) { AppRouter.shared.playRequest = PlaybackRequest(item: i, startTicks: i.resumeTicks) }

    private func load() async {
        guard let c = app.client else { return }
        async let r = (try? await c.resume()) ?? []
        async let n = (try? await c.nextUp()) ?? []
        async let fav = c.favorites()
        let views = ((try? await c.userViews()) ?? []).filter { ["movies", "tvshows", "homevideos", "mixed", nil].contains($0.collectionType) }
        var out: [(BaseItem, [BaseItem])] = []
        for v in views { if let l = try? await c.latest(parentId: v.id), !l.isEmpty { out.append((v, l)) } }
        resume = await r; nextUp = await n; myList = await fav; latest = out
        featured = resume.first ?? out.first?.1.first { $0.backdropImageTags?.isEmpty == false }
        loaded = true
    }
}

// MARK: Library

struct TVLibrariesView: View {
    @Environment(AppState.self) private var app
    @State private var views: [BaseItem] = []
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 50), count: 3), spacing: 60) {
                ForEach(views) { lib in
                    NavigationLink(value: lib) {
                        ZStack(alignment: .bottomLeading) {
                            TVImage(url: app.client?.imageURL(lib.id, maxWidth: 900, tag: lib.imageTag("Primary")))
                            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                            Text(lib.name ?? "").font(.title2.bold()).padding(24)
                        }.frame(height: 300)
                    }.buttonStyle(.card)
                }
            }.padding(80)
        }
        .itemDestinations()
        .task { views = (try? await app.client?.userViews()) ?? [] }
    }
}

struct TVItemRoute: View {
    let item: BaseItem
    var body: some View {
        switch item.type {
        case "CollectionFolder", "UserView":
            if item.collectionType == "music" { TVMusicView(library: item) }
            else if item.collectionType == "livetv" { TVLiveView() }
            else { TVGrid(parent: item) }
        case "Folder", "BoxSet": TVGrid(parent: item)
        case "Playlist": if item.mediaType == "Audio" { TVAlbumView(album: item) } else { TVGrid(parent: item) }
        case "MusicAlbum": TVAlbumView(album: item)
        case "MusicArtist": TVArtistView(artist: item)
        case "Book": VStack(spacing: 20) { Image(systemName: "book").font(.system(size: 80)); Text("Read books in Huefin on your phone, tablet or PC.").font(.title3) }
        default: TVDetailView(start: item)
        }
    }
}

struct TVGrid: View {
    let parent: BaseItem
    @Environment(AppState.self) private var app
    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var sort = "SortName"

    private var types: (String?, Bool) {
        switch parent.collectionType {
        case "movies": return ("Movie", true)
        case "tvshows": return ("Series", true)
        case "boxsets": return ("BoxSet", true)
        case "books": return ("AudioBook", true)
        default: return (nil, false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 20) {
                    Text(parent.name ?? "").font(.title.bold())
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        Text("Name").tag("SortName"); Text("Recently added").tag("DateCreated,SortName")
                        Text("Release date").tag("PremiereDate,ProductionYear,SortName"); Text("Rating").tag("CommunityRating,SortName")
                    }.pickerStyle(.menu)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 48), count: 6), spacing: 60) {
                    ForEach(items) { i in
                        TVPosterCard(item: i).onAppear { if i.id == items.last?.id { Task { await more() } } }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }.padding(80)
        }
        .task(id: sort) { items = []; total = .max; await more() }
    }

    private func more() async {
        guard let c = app.client, !loading, items.count < total else { return }
        loading = true
        let order = sort == "SortName" ? "Ascending" : "Descending"
        if let r = try? await c.items(parentId: parent.id, types: types.0, recursive: types.1, sortBy: sort, sortOrder: order, start: items.count, limit: 120) {
            items += r.items; total = r.totalRecordCount ?? items.count
        } else { total = items.count }
        loading = false
    }
}

// MARK: Detail

struct TVDetailView: View {
    let start: BaseItem
    @Environment(AppState.self) private var app
    @State private var item: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var season: BaseItem?
    @State private var episodes: [BaseItem] = []
    @State private var similar: [BaseItem] = []

    private var i: BaseItem { item ?? start }
    private var showId: String? { i.isSeries ? i.id : (i.type == "Season" ? i.seriesId : nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                ZStack(alignment: .bottomLeading) {
                    TVImage(url: app.client?.backdropURL(for: i, width: 1920)).frame(height: 760).clipped()
                    LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
                    LinearGradient(colors: [Theme.background.opacity(0.92), .clear], startPoint: .leading, endPoint: .center)
                    VStack(alignment: .leading, spacing: 18) {
                        if let logo = app.client?.logoURL(for: i), i.type != "Episode" { TVImage(url: logo, contentMode: .fit).frame(maxWidth: 600, maxHeight: 200, alignment: .leading) }
                        else { Text(i.displayTitle).font(.system(size: 60, weight: .black)) }
                        if let e = i.episodeLabel { Text(e).font(.title3.weight(.semibold)) }
                        Text(([i.productionYear.map(String.init), i.officialRating, i.runtimeText, i.communityRating.map { String(format: "★ %.1f", $0) }].compactMap { $0 } + (i.mediaSources?.first?.badges ?? [])).joined(separator: "  ·  "))
                            .foregroundStyle(.secondary)
                        Text(i.overview ?? "").lineLimit(4).frame(maxWidth: 1000, alignment: .leading)
                        HStack(spacing: 30) {
                            if i.isPlayable || i.isSeries {
                                Button { Task { await play() } } label: { Label((i.progress ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill") }
                            }
                            if (i.progress ?? 0) > 0 {
                                Button { AppRouter.shared.playRequest = PlaybackRequest(item: i, startTicks: 0) } label: { Label("From Start", systemImage: "arrow.counterclockwise") }
                            }
                            Button { Task { await toggleWatched() } } label: {
                                Image(systemName: i.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle")
                            }
                            Button { Task { _ = await app.client?.setFavorite(i.id, !(i.userData?.isFavorite ?? false)); await reload() } } label: {
                                Image(systemName: i.userData?.isFavorite == true ? "heart.fill" : "heart")
                            }
                        }
                        if let p = i.progress { TVProgress(value: p).frame(width: 400) }
                    }.padding(.horizontal, 80).padding(.bottom, 30)
                }
                if !seasons.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 20) {
                            ForEach(seasons) { s in
                                Button(s.name ?? "Season") { season = s }
                                    .tint(s.id == season?.id ? Theme.blue : nil)
                            }
                        }.padding(.horizontal, 80).padding(.vertical, 20)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 44) {
                            ForEach(episodes) { e in
                                TVLandscapeCard(item: e, width: 420, subtitle: "\(e.indexNumber.map { "\($0). " } ?? "")\(e.name ?? "")") {
                                    AppRouter.shared.playRequest = PlaybackRequest(item: e, startTicks: e.resumeTicks)
                                }
                            }
                        }.padding(.horizontal, 80).padding(.vertical, 30)
                    }.scrollClipDisabled()
                }
                if !similar.isEmpty { TVShelf(title: "More Like This") { ForEach(similar) { TVPosterCard(item: $0, width: 220) } } }
            }.padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .horizontal)
        .task(id: start.id) { await reload() }
        .task(id: season?.id) {
            guard let s = season, let sid = showId else { return }
            episodes = (try? await app.client?.episodes(seriesId: sid, seasonId: s.id)) ?? []
        }
    }

    private func reload() async {
        guard let c = app.client else { return }
        item = try? await c.item(start.id)
        if seasons.isEmpty, let sid = showId {
            seasons = (try? await c.seasons(seriesId: sid)) ?? []
            season = i.type == "Season" ? seasons.first { $0.id == i.id }
                : seasons.first { ($0.userData?.unplayedItemCount ?? 0) > 0 && ($0.indexNumber ?? 0) > 0 } ?? seasons.first
        }
        if similar.isEmpty { similar = await c.similar(i.seriesId ?? i.id) }
    }

    private func toggleWatched() async {
        guard let c = app.client else { return }
        if i.userData?.played == true { _ = try? await c.send("UserPlayedItems/\(i.id)", method: "DELETE") }
        else { await c.markPlayed(i.id) }
        await reload()
    }

    private func play() async {
        if i.isSeries {
            let next = (try? await app.client?.nextUp(seriesId: i.id))?.first ?? episodes.first
            if let next { AppRouter.shared.playRequest = PlaybackRequest(item: next, startTicks: next.resumeTicks) }
        } else { AppRouter.shared.playRequest = PlaybackRequest(item: i, startTicks: i.resumeTicks) }
    }
}

// MARK: Search

struct TVSearchView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var requests: [Seerr.Result] = []
    @State private var requested: Set<Int> = []
    @State private var picked: Seerr.Result?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ForEach([("Movies", ["Movie"]), ("Shows", ["Series"]), ("Episodes", ["Episode"]), ("Channels", ["TvChannel"]), ("Music", ["MusicAlbum", "MusicArtist", "Audio"])], id: \.0) { title, types in
                    let list = results.filter { types.contains($0.type ?? "") }
                    if !list.isEmpty {
                        TVShelf(title: title) {
                            ForEach(list) { r in
                                if r.type == "Episode" { TVLandscapeCard(item: r, width: 420) }
                                else if r.isLiveChannel || r.type == "Audio" { TVLandscapeCard(item: r, width: 360) { _ = open(r, app: app) } }
                                else { TVPosterCard(item: r, width: 220) }
                            }
                        }
                    }
                }
                if !requests.isEmpty {
                    TVShelf(title: "Not on your server? Request it") {
                        ForEach(requests) { r in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { picked = r } label: {
                                    ZStack(alignment: .bottom) {
                                        TVImage(url: r.posterURL)
                                        Text(requested.contains(r.id) ? "Requested ✓" : (r.statusText ?? "Request"))
                                            .font(.caption.bold()).padding(8).frame(maxWidth: .infinity).background(Theme.violet.opacity(0.9))
                                    }.frame(width: 220, height: 330)
                                }.buttonStyle(.card)
                                Text(r.title).font(.caption).lineLimit(1).frame(width: 220, alignment: .leading)
                            }
                        }
                    }
                }
            }.padding(.vertical, 40)
        }
        .searchable(text: $query, prompt: "Movies, shows, channels, music")
        .sheet(item: $picked) { r in TVSeerrDetail(result: r, alreadyRequested: requested.contains(r.id)) { requested.insert(r.id) } }
        .itemDestinations()
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; requests = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            results = (try? await app.client?.search(q)) ?? []
            await Seerr.shared.activate(accountKey: app.session?.key, jellyfinURL: app.session?.serverURL)
            if Seerr.shared.isConfigured {
                let have = Set(results.compactMap { $0.name?.lowercased() })
                requests = await Seerr.shared.search(q).filter { $0.status != 5 && !have.contains($0.title.lowercased()) }
            }
        }
    }
}

// MARK: Live TV

struct TVLiveView: View {
    @Environment(AppState.self) private var app
    @State private var channels: [BaseItem] = []
    @State private var guide: [String: [ProgramInfo]] = [:]
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible(), spacing: 40)], spacing: 40) {
                ForEach(channels) { ch in
                    let now = guide[ch.id]?.first { ($0.start ?? .distantFuture) <= Date() && ($0.end ?? .distantPast) > Date() } ?? ch.currentProgram
                    let next = guide[ch.id]?.first { ($0.start ?? .distantPast) > Date() }
                    Button { AppRouter.shared.playRequest = PlaybackRequest(item: ch, startTicks: 0) } label: {
                        HStack(spacing: 28) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08))
                                Text(String((ch.name ?? "TV").prefix(3)).uppercased()).font(.headline).foregroundStyle(.secondary)
                                if ch.imageTag("Primary") != nil { TVImage(url: app.client?.imageURL(ch.id, maxWidth: 300, tag: ch.imageTag("Primary")), contentMode: .fit).padding(10) }
                            }.frame(width: 180, height: 110)
                            VStack(alignment: .leading, spacing: 6) {
                                Text([ch.channelNumber, ch.name].compactMap { $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(Theme.orange)
                                Text(now?.title ?? ch.name ?? "Live").font(.headline).lineLimit(1)
                                if let next, let s = next.start { Text("Next \(s.formatted(date: .omitted, time: .shortened)) · \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                        }.padding(20)
                    }.buttonStyle(.card)
                }
            }.padding(80)
            if !loaded { ProgressView() } else if channels.isEmpty { Text("No Live TV on this server.").foregroundStyle(.secondary) }
        }
        .task {
            channels = (try? await app.client?.liveChannels()) ?? []
            guide = (try? await app.client?.liveGuide(hours: 4)) ?? [:]
            loaded = true
        }
    }
}
