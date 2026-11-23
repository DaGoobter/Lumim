import SwiftUI

/// Search everything on the server: movies, shows, episodes, collections, music, books and channels.
struct SearchView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var playRequest: PlaybackRequest?
    @State private var requestable: [Seerr.Result] = []
    @State private var requestPick: Seerr.Result?
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "prism.recentSearches") ?? []

    private struct ResultGroup: Identifiable {
        let title: String
        let items: [BaseItem]
        var id: String { title }
    }

    private var groups: [ResultGroup] {
        let order: [(String, [String])] = [
            ("Movies", ["Movie"]), ("Shows", ["Series"]), ("Episodes", ["Episode"]),
            ("Collections", ["BoxSet"]), ("Channels", ["TvChannel"]), ("Artists", ["MusicArtist"]),
            ("Albums", ["MusicAlbum"]), ("Songs", ["Audio"]), ("Books", ["Book", "AudioBook"]),
            ("Playlists", ["Playlist"]),
        ]
        return order.compactMap { title, types in
            let matched = results.filter { types.contains($0.type ?? "") }
            return matched.isEmpty ? nil : ResultGroup(title: title, items: matched)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Recent").font(.title3.weight(.bold))
                                Spacer()
                                Button("Clear") { recent = []; saveRecent() }.font(.subheadline)
                            }
                            ForEach(recent, id: \.self) { term in
                                Button { query = term } label: {
                                    Label(term, systemImage: "clock.arrow.circlepath")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .foregroundStyle(.primary)
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal, 20)
                    } else {
                        ContentUnavailableView("Search your server", systemImage: "magnifyingglass",
                                               description: Text("Movies, shows, episodes, music, books and channels."))
                            .padding(.top, 80)
                    }
                } else if searching && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if let error {
                    ErrorBanner(message: error) { Task { await run() } }
                } else {
                    if results.isEmpty && requestable.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 60)
                    }
                    ForEach(groups) { group in
                        Shelf(group.title) {
                            ForEach(group.items) { item in cell(item) }
                        }
                    }
                    if Seerr.shared.needsSignIn && !searching {
                        SeerrInlineConnect { Task { await run() } }
                            .padding(.horizontal, 20)
                    }
                    if !requestable.isEmpty {
                        Shelf("Not on your server? Request it") {
                            ForEach(requestable) { r in
                                Button { requestPick = r } label: { SeerrPoster(result: r).frame(width: 120) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Movies, shows, music…")
        .onSubmit(of: .search) { remember(query) }
        .task(id: query) {
            // Wait for typing to settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await run()
        }
        .navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
        .fullScreenCover(item: $playRequest) { PlayerScreen(request: $0) }
        .sheet(item: $requestPick) { SeerrDetailSheet(result: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { RequestsView() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .accessibilityLabel("Requests")
            }
        }
        .task(id: app.session?.key) {
            await Seerr.shared.activate(accountKey: app.session?.key, jellyfinURL: app.session?.serverURL)
        }
    }

    @ViewBuilder
    private func cell(_ item: BaseItem) -> some View {
        switch item.type ?? "" {
        case "Audio":
            Button {
                remember(query)
                audio.play([item], client: app.client)
            } label: { SquareCard(item: item) }
            .buttonStyle(CardPressStyle())
        case "TvChannel":
            Button {
                remember(query)
                playRequest = PlaybackRequest(item: item, startTicks: 0)
            } label: { SquareCard(item: item) }
            .buttonStyle(CardPressStyle())
        case "Episode":
            NavigationLink(value: item) { LandscapeCard(item: item) }
                .buttonStyle(CardPressStyle())
                .simultaneousGesture(TapGesture().onEnded { remember(query) })
        case "MusicArtist", "MusicAlbum", "Playlist":
            NavigationLink(value: item) { SquareCard(item: item) }
                .buttonStyle(CardPressStyle())
                .simultaneousGesture(TapGesture().onEnded { remember(query) })
        default:
            NavigationLink(value: item) { PosterCard(item: item) }
                .buttonStyle(CardPressStyle())
                .simultaneousGesture(TapGesture().onEnded { remember(query) })
        }
    }

    private func run() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let client = app.client else { results = []; requestable = []; return }
        if Seerr.shared.isConfigured {
            Task {
                let found = await Seerr.shared.search(term)
                if term == query.trimmingCharacters(in: .whitespaces) { requestable = found.filter { $0.status != 5 } }
            }
        }
        searching = true
        defer { searching = false }
        do {
            let found = try await client.search(term)
            guard term == query.trimmingCharacters(in: .whitespaces) else { return }
            results = found
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remember(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return }
        recent.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recent.insert(t, at: 0)
        recent = Array(recent.prefix(8))
        saveRecent()
    }

    private func saveRecent() { UserDefaults.standard.set(recent, forKey: "prism.recentSearches") }
}

/// "Can't find it? Request it": one-time password entry for people signed in before requests were set up
/// (or who signed in with Quick Connect).
struct SeerrInlineConnect: View {
    @Environment(AppState.self) private var app
    var onConnected: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Not finding it? Request it", systemImage: "plus.rectangle.on.rectangle")
                .font(.headline)
            Text("Enter your Huefin password once to turn on requests for movies and shows that aren't on the server yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit(connect)
                Button(action: connect) {
                    if busy { ProgressView() } else { Text("Turn on") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || password.isEmpty)
            }
            if failed { Text("That password didn't work.").font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func connect() {
        guard let base = Seerr.shared.baseURL, !password.isEmpty else { return }
        busy = true
        failed = false
        Task {
            do {
                try await Seerr.shared.signIn(address: base.absoluteString, username: app.session?.userName ?? "", password: password)
                onConnected()
            } catch { failed = true }
            password = ""
            busy = false
        }
    }
}

/// Square artwork card for music, channels and the like.
struct SquareCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: BaseItem

    var body: some View {
        let width: CGFloat = sizeClass == .regular ? 160 : 120
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.isLiveChannel {
                        ZStack {
                            Color.white.opacity(0.08)
                            RemoteImage(url: app.client?.imageURL(item.id, maxWidth: 300, tag: item.imageTag("primary")))
                                .padding(14)
                        }
                    } else {
                        RemoteImage(url: app.client?.albumArtURL(for: item, width: 300))
                    }
                }
                .clipShape(item.type == "MusicArtist" ? AnyShape(Circle())
                                                      : AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
            Text(item.name ?? "").font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.artistLine ?? item.channelNumber ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
    }
}
