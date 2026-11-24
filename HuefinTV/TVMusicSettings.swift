import SwiftUI

// MARK: Music

struct TVMusicView: View {
    var library: BaseItem? = nil
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @State private var lib: BaseItem?
    @State private var albums: [BaseItem] = []
    @State private var nowPlaying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let cur = audio.current {
                    Button { nowPlaying = true } label: {
                        HStack(spacing: 30) {
                            TVImage(url: app.client?.albumArtURL(for: cur, width: 300)).frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(audio.station.map { "Playing from \($0.name)" } ?? "Now playing").font(.caption).foregroundStyle(Theme.violet)
                                Text(cur.name ?? "").font(.title3.bold())
                                Text(cur.artistLine ?? "").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title)
                        }.padding(26)
                    }.buttonStyle(.card).padding(.horizontal, 80)
                }
                // The DJ and stations.
                ScrollView(.horizontal) {
                    HStack(spacing: 40) {
                        station("Huefin DJ", "Your music with a voice between sets", "waveform", [Theme.violet, Theme.red, Theme.orange]) { Stations.dj(libraryId: lib?.id) }
                        station("Heavy Rotation", "Your most played", "flame.fill", [Theme.orange, Theme.red]) { Stations.heavyRotation(libraryId: lib?.id) }
                        station("Favorites Mix", "Songs you've hearted", "heart.fill", [Theme.red, Theme.violet]) { Stations.favorites(libraryId: lib?.id) }
                        station("Throwbacks", "Not played in a while", "clock.arrow.circlepath", [Theme.green, Theme.blue]) { Stations.throwbacks(libraryId: lib?.id) }
                        station("Discover", "Never played yet", "sparkles", [Theme.yellow, Theme.green]) { Stations.discover(libraryId: lib?.id) }
                    }.padding(.horizontal, 80).padding(.vertical, 30)
                }.scrollClipDisabled()
                if !albums.isEmpty {
                    Text("Recently added albums").font(.title3.bold()).padding(.horizontal, 80)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 44), count: 6), spacing: 50) {
                        ForEach(albums) { a in
                            VStack(alignment: .leading, spacing: 8) {
                                NavigationLink(value: a) { TVImage(url: app.client?.albumArtURL(for: a, width: 520)).frame(width: 260, height: 260) }.buttonStyle(.card)
                                Text(a.name ?? "").font(.caption.bold()).lineLimit(1)
                                Text(a.artistLine ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(width: 260)
                        }
                    }.padding(.horizontal, 80)
                }
            }.padding(.vertical, 40)
        }
        .itemDestinations()
        .fullScreenCover(isPresented: $nowPlaying) { TVNowPlaying() }
        .task {
            guard let c = app.client else { return }
            let views = (try? await c.userViews()) ?? []
            lib = library ?? views.first { $0.collectionType == "music" }
            guard let lib else { return }
            albums = (try? await c.items(parentId: lib.id, types: "MusicAlbum", recursive: true, sortBy: "DateCreated", sortOrder: "Descending", start: 0, limit: 60).items) ?? []
        }
    }

    private func station(_ title: String, _ sub: String, _ icon: String, _ colors: [Color], make: @escaping () -> Station) -> some View {
        Button {
            guard let c = app.client else { return }
            Task { await audio.play(station: make(), client: c); nowPlaying = true }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title)
                Spacer()
                Text(title).font(.title3.weight(.heavy))
                Text(sub).font(.caption).opacity(0.8)
            }
            .foregroundStyle(Theme.ink).padding(28).frame(width: 380, height: 230, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        }.buttonStyle(.card)
    }
}

struct TVAlbumView: View {
    let album: BaseItem
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @State private var tracks: [BaseItem] = []
    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 20) {
                TVImage(url: app.client?.albumArtURL(for: album, width: 900)).frame(width: 500, height: 500).clipShape(RoundedRectangle(cornerRadius: 24))
                Text(album.name ?? "").font(.title2.bold())
                Text(album.artistLine ?? "").foregroundStyle(Theme.violet)
                HStack(spacing: 24) {
                    Button { audio.play(tracks, client: app.client) } label: { Label("Play", systemImage: "play.fill") }
                    Button { audio.play(tracks, shuffle: true, client: app.client) } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { if let c = app.client { Task { await audio.play(station: Stations.radio(name: "\(album.name ?? "Album") Radio", seedId: album.id), client: c) } } } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                }
            }.frame(width: 500)
            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { n, t in
                    Button { audio.play(tracks, startAt: n, client: app.client) } label: {
                        HStack {
                            Text(t.indexNumber.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                            Text(t.name ?? "")
                            Spacer()
                            Text(t.runtimeText ?? "").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(80)
        .task { tracks = (try? await (album.type == "Playlist" ? app.client?.playlistItems(album.id) : app.client?.albumTracks(album.id))) ?? [] }
    }
}

struct TVArtistView: View {
    let artist: BaseItem
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @State private var albums: [BaseItem] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(spacing: 40) {
                    Text(artist.name ?? "").font(.largeTitle.bold())
                    Button { if let c = app.client { Task { await audio.play(station: Stations.radio(name: "\(artist.name ?? "Artist") Radio", seedId: artist.id), client: c) } } } label: {
                        Label("Artist Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 44), count: 6), spacing: 50) {
                    ForEach(albums) { a in
                        VStack(alignment: .leading) {
                            NavigationLink(value: a) { TVImage(url: app.client?.albumArtURL(for: a, width: 520)).frame(width: 260, height: 260) }.buttonStyle(.card)
                            Text(a.name ?? "").font(.caption.bold()).lineLimit(1)
                        }.frame(width: 260)
                    }
                }
            }.padding(80)
        }
        .task { albums = (try? await app.client?.artistAlbums(artist.id)) ?? [] }
    }
}

/// Full-screen Now Playing with the DJ's line.
struct TVNowPlaying: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    var body: some View {
        ZStack {
            if let cur = audio.current {
                TVImage(url: app.client?.albumArtURL(for: cur, width: 600)).blur(radius: 80).opacity(0.5).ignoresSafeArea()
                HStack(spacing: 90) {
                    TVImage(url: app.client?.albumArtURL(for: cur, width: 1000)).frame(width: 640, height: 640).clipShape(RoundedRectangle(cornerRadius: 30))
                    VStack(alignment: .leading, spacing: 24) {
                        if let s = audio.station { Text("Playing from \(s.name)").foregroundStyle(Theme.violet) }
                        Text(cur.name ?? "").font(.system(size: 56, weight: .heavy)).lineLimit(2)
                        Text(cur.artistLine ?? "").font(.title2).foregroundStyle(.secondary)
                        if let line = audio.djLine {
                            HStack(alignment: .top, spacing: 14) { Image(systemName: "mic.fill").foregroundStyle(Theme.violet); Text(line) }
                                .padding(24).background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                        }
                        if audio.duration > 0 { ProgressView(value: min(audio.currentTime, audio.duration), total: audio.duration).tint(Theme.violet) }
                        HStack(spacing: 40) {
                            Button { audio.previous() } label: { Image(systemName: "backward.fill") }
                            Button { audio.togglePlay() } label: { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill") }
                            Button { audio.next() } label: { Image(systemName: "forward.fill") }
                            Button { audio.stop() } label: { Image(systemName: "stop.fill") }
                        }.font(.title)
                    }.frame(maxWidth: 900, alignment: .leading)
                }
            } else {
                Text("Nothing playing").font(.title2).foregroundStyle(.secondary)
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: Settings

struct TVSettingsView: View {
    @Environment(AppState.self) private var app
    @State private var adding = false
    @State private var groups: [SyncPlayManager.GroupInfo] = []
    @State private var sync = SyncPlayManager.shared
    @AppStorage(PlaybackPrefs.keys.autoIntro) private var autoIntro = false
    @AppStorage(PlaybackPrefs.keys.autoCredits) private var autoCredits = false
    @AppStorage("prism.askWhoIsWatching") private var askWho = true

    var body: some View {
        @Bindable var app = app
        List {
            Section("Who's watching") {
                ForEach(app.accounts, id: \.key) { a in
                    Button { app.switchTo(a) } label: {
                        HStack {
                            Text(a.userName).bold()
                            Text(a.serverName ?? a.serverURL).foregroundStyle(.secondary)
                            Spacer()
                            if a.key == app.session?.key { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                        }
                    }
                    .contextMenu { Button("Sign out \(a.userName)", role: .destructive) { Task { await app.remove(a) } } }
                }
                Button("Add someone") { adding = true }
                Toggle("Ask who's watching when Huefin opens", isOn: $askWho)
            }
            Section("Watch Together") {
                if sync.groupId != nil {
                    Text("In \(sync.groupName ?? "a group") with \(sync.participants.joined(separator: ", "))")
                    Button("Leave group", role: .destructive) { Task { await sync.leave() } }
                } else {
                    ForEach(groups) { g in
                        Button("Join \(g.name)") { if let c = app.client { Task { try? await sync.join(client: c, group: g, model: nil) } } }
                    }
                    Button("Look for groups") { Task { if let c = app.client { groups = await sync.listGroups(client: c) } } }
                    Text("Someone starts a group from Huefin on their phone or PC (or Jellyfin's web app); join it here and play, pause and seeking are shared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Playback") {
                Picker("Streaming quality", selection: $app.maxBitrate) {
                    ForEach([200, 120, 80, 40, 20, 10], id: \.self) { m in Text(m == 200 ? "Maximum" : "\(m) Mbps").tag(m * 1_000_000) }
                }
                .onChange(of: app.maxBitrate) { _, _ in app.persistSettings() }
                Toggle("Skip intros automatically", isOn: $autoIntro)
                Toggle("Go straight to the next episode at the credits", isOn: $autoCredits)
            }
            Section("Connection") {
                LabeledContent("Using", value: app.route == .local ? "Home network" : "Remote address")
                LabeledContent("Server", value: app.session?.serverURL ?? "")
                Button("Check connection") { Task { await app.recheckConnection() } }
            }
            Section {
                Button("Sign out", role: .destructive) { Task { await app.logout() } }
            } footer: { Text("Huefin for Apple TV \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") }
        }
        .frame(maxWidth: 1300)
        .fullScreenCover(isPresented: $adding) { TVLoginView(adding: true) { adding = false } }
    }
}

struct TVProfilePicker: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let hues = [Theme.red, Theme.blue, Theme.orange, Theme.green, Theme.violet]
    var body: some View {
        VStack(spacing: 70) {
            Text("Who's watching?").font(.system(size: 64, weight: .heavy))
            HStack(spacing: 70) {
                ForEach(Array(app.accounts.enumerated()), id: \.element.key) { n, a in
                    Button { app.switchTo(a); dismiss() } label: {
                        VStack(spacing: 20) {
                            Text(String(a.userName.prefix(1)).uppercased()).font(.system(size: 90, weight: .black)).foregroundStyle(Theme.ink)
                                .frame(width: 220, height: 220).background(hues[n % hues.count])
                        }
                    }.buttonStyle(.card)
                    .overlay(alignment: .bottom) { Text(a.userName).font(.title3.bold()).offset(y: 60) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
