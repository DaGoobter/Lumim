import SwiftUI

// MARK: - Music library

struct MusicLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let library: BaseItem

    enum MusicSection: String, CaseIterable, Identifiable {
        case albums = "Albums", artists = "Artists", songs = "Songs", playlists = "Playlists"
        var id: String { rawValue }
    }

    @State private var section: MusicSection = .albums
    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            Picker("Show", selection: $section) {
                ForEach(MusicSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            if let error { ErrorBanner(message: error) { Task { await reload() } } }

            switch section {
            case .songs:
                LazyVStack(spacing: 0) {
                    if !items.isEmpty {
                        HStack {
                            Button { play(shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(PlayButtonStyle())
                            Button { play(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding()
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, song in
                        TrackRow(track: song, number: nil, showArt: true) {
                            AudioPlayer.shared.play(items, startAt: i, client: app.client)
                        }
                        .onAppear { if song.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
            case .artists:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 110), spacing: 16)], spacing: 20) {
                    ForEach(items) { artist in
                        NavigationLink(value: artist) { ArtistCard(artist: artist) }
                            .buttonStyle(CardPressStyle())
                            .onAppear { if artist.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding()
            case .albums, .playlists:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 150), spacing: 16)], spacing: 20) {
                    ForEach(items) { album in
                        NavigationLink(value: album) { AlbumCard(album: album) }
                            .buttonStyle(CardPressStyle())
                            .onAppear { if album.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding()
            }
            if loading { ProgressView().padding() }
        }
        .background(TintedBackdrop(color: ArtColor(hue: 0.88, saturation: 0.7, brightness: 0.8)))
        .navigationTitle(library.name ?? "Music")
        .task { if items.isEmpty { await loadMore() } }
        .onChange(of: section) { Task { await reload() } }
    }

    private func play(shuffle: Bool) {
        AudioPlayer.shared.play(items, shuffle: shuffle, client: app.client)
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
            let r: ItemsResult
            switch section {
            case .albums:
                r = try await client.browse(["parentId": library.id, "includeItemTypes": "MusicAlbum", "recursive": "true",
                                             "sortBy": "SortName", "startIndex": String(items.count), "limit": "100"])
            case .artists:
                r = try await client.get("Artists/AlbumArtists", query: [
                    "userId": client.userId, "parentId": library.id, "sortBy": "SortName",
                    "startIndex": String(items.count), "limit": "100", "fields": "PrimaryImageAspectRatio",
                ])
            case .songs:
                r = try await client.browse(["parentId": library.id, "includeItemTypes": "Audio", "recursive": "true",
                                             "sortBy": "Album,ParentIndexNumber,IndexNumber,SortName",
                                             "startIndex": String(items.count), "limit": "200"])
            case .playlists:
                r = try await client.browse(["includeItemTypes": "Playlist", "recursive": "true", "mediaTypes": "Audio",
                                             "sortBy": "SortName", "startIndex": String(items.count), "limit": "100"])
            }
            items += r.items
            total = r.totalRecordCount ?? items.count
            error = nil
        } catch {
            self.error = error.localizedDescription
            total = items.count
        }
    }
}

struct AlbumCard: View {
    @Environment(AppState.self) private var app
    let album: BaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: app.client?.albumArtURL(for: album, width: 400)) }
                .overlay {
                    if album.imageTag("primary") == nil && album.albumPrimaryImageTag == nil {
                        Image(systemName: album.type == "Playlist" ? "music.note.list" : "music.note")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
            Text(album.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(album.artistLine ?? (album.childCount.map { "\($0) songs" } ?? " "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct ArtistCard: View {
    @Environment(AppState.self) private var app
    let artist: BaseItem

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: app.client?.imageURL(artist.id, maxWidth: 300, tag: artist.imageTag("primary"))) }
                .overlay {
                    if artist.imageTag("primary") == nil {
                        Text(String((artist.name ?? "?").prefix(1))).font(.largeTitle.bold()).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
            Text(artist.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
        }
    }
}

struct TrackRow: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    let track: BaseItem
    let number: Int?
    let showArt: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if showArt {
                    RemoteImage(url: app.client?.albumArtURL(for: track, width: 120))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(number.map(String.init) ?? "").font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "Track").font(.body)
                        .foregroundStyle(audio.current?.id == track.id ? Theme.accent : .white).lineLimit(1)
                    if showArt, let artist = track.artistLine {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if audio.current?.id == track.id && audio.isPlaying {
                    Image(systemName: "waveform").foregroundStyle(Theme.accent).symbolEffect(.variableColor.iterative)
                } else if let rt = track.runTimeTicks {
                    Text(clock(Double(rt) / 10_000_000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - Album / playlist

struct AlbumView: View {
    @Environment(AppState.self) private var app
    let album: BaseItem
    @State private var tracks: [BaseItem] = []
    @State private var color: ArtColor?

    private var isPlaylist: Bool { album.type == "Playlist" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RemoteImage(url: app.client?.albumArtURL(for: album, width: 800))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: (color?.background ?? .black).opacity(0.8), radius: 24, y: 12)
                    .padding(.top, 12)
                VStack(spacing: 4) {
                    Text(album.name ?? "").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    if let artist = album.artistLine {
                        Text(artist).font(.title3).foregroundStyle(color?.accent ?? Theme.accent)
                    }
                    Text([album.productionYear.map(String.init), tracks.isEmpty ? nil : "\(tracks.count) songs",
                          totalTime].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { AudioPlayer.shared.play(tracks, client: app.client) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlayButtonStyle())
                    Button { AudioPlayer.shared.play(tracks, shuffle: true, client: app.client) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal)
                .disabled(tracks.isEmpty)

                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, number: isPlaylist ? nil : (t.indexNumber ?? i + 1), showArt: isPlaylist) {
                            AudioPlayer.shared.play(tracks, startAt: i, client: app.client)
                        }
                        Divider().padding(.leading, isPlaylist ? 72 : 56).opacity(0.3)
                    }
                }
            }
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .background(TintedBackdrop(color: color))
        .navigationBarTitleDisplayMode(.inline)
        .artColor(from: app.client?.albumArtURL(for: album, width: 300), into: $color)
        .task {
            guard let client = app.client, tracks.isEmpty else { return }
            tracks = (try? await (isPlaylist ? client.playlistItems(album.id) : client.albumTracks(album.id))) ?? []
        }
    }

    private var totalTime: String? {
        let total = tracks.compactMap(\.runTimeTicks).reduce(0, +)
        guard total > 0 else { return nil }
        return formatTicks(total)
    }
}

struct ArtistView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let artist: BaseItem
    @State private var albums: [BaseItem] = []
    @State private var color: ArtColor?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                RemoteImage(url: app.client?.imageURL(artist.id, maxWidth: 600, tag: artist.imageTag("primary")))
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .padding(.top, 12)
                Text(artist.name ?? "").font(.largeTitle.weight(.heavy))
                Button {
                    Task {
                        guard let client = app.client else { return }
                        var all: [BaseItem] = []
                        for a in albums { all += (try? await client.albumTracks(a.id)) ?? [] }
                        AudioPlayer.shared.play(all, shuffle: true, client: client)
                    }
                } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(PlayButtonStyle())
                .disabled(albums.isEmpty)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 150), spacing: 16)], spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) { AlbumCard(album: album) }.buttonStyle(CardPressStyle())
                    }
                }
                .padding()
            }
        }
        .background(TintedBackdrop(color: color))
        .navigationBarTitleDisplayMode(.inline)
        .artColor(from: app.client?.imageURL(artist.id, maxWidth: 300, tag: artist.imageTag("primary")), into: $color)
        .task {
            guard let client = app.client, albums.isEmpty else { return }
            albums = (try? await client.artistAlbums(artist.id)) ?? []
        }
    }
}

// MARK: - Mini player & Now Playing

struct MiniPlayer: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        if let item = audio.current {
            HStack(spacing: 12) {
                RemoteImage(url: app.client?.albumArtURL(for: item, width: 120))
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(item.artistLine ?? item.album ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { audio.togglePlay() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                Button { audio.isAudiobook ? audio.skip(by: 30) : audio.next() } label: {
                    Image(systemName: audio.isAudiobook ? "goforward.30" : "forward.fill").font(.title3)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(audio.isAudiobook ? "Forward 30 seconds" : "Next")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(Theme.gradient)
                        .frame(width: g.size.width * (audio.duration > 0 ? audio.currentTime / audio.duration : 0), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { audio.showNowPlaying = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @Environment(\.dismiss) private var dismiss
    @State private var color: ArtColor?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false

    var body: some View {
        if let item = audio.current {
            VStack(spacing: 22) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)

                if showQueue {
                    queueList
                } else {
                    RemoteImage(url: app.client?.albumArtURL(for: item, width: 1000))
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                        .scaleEffect(audio.isPlaying ? 1 : 0.88)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: audio.isPlaying)
                        .padding(.horizontal, 28)
                        .frame(maxHeight: 420)
                }

                VStack(spacing: 4) {
                    Text(item.name ?? "").font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    Text([item.artistLine, item.album].compactMap { $0 }.joined(separator: " — "))
                        .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.horizontal)

                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrubbing ? scrubValue : audio.currentTime }, set: { scrubValue = $0 }),
                           in: 0...max(audio.duration, 1)) { editing in
                        if editing { scrubValue = audio.currentTime; scrubbing = true }
                        else { audio.seek(to: scrubValue); scrubbing = false }
                    }
                    .tint(.white)
                    HStack {
                        Text(clock(scrubbing ? scrubValue : audio.currentTime))
                        Spacer()
                        Text("-" + clock(max(0, audio.duration - (scrubbing ? scrubValue : audio.currentTime))))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 28)

                HStack(spacing: 44) {
                    if audio.isAudiobook {
                        Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                            .accessibilityLabel("Back 15 seconds")
                    } else {
                        Button { audio.previous() } label: { Image(systemName: "backward.fill") }
                            .accessibilityLabel("Previous")
                    }
                    Button { audio.togglePlay() } label: {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52)).frame(width: 70, height: 70)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                    if audio.isAudiobook {
                        Button { audio.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                            .accessibilityLabel("Forward 30 seconds")
                    } else {
                        Button { audio.next() } label: { Image(systemName: "forward.fill") }
                            .disabled(!audio.hasNext)
                            .accessibilityLabel("Next")
                    }
                }
                .font(.system(size: 30))
                .foregroundStyle(.white)

                HStack {
                    if audio.isAudiobook {
                        Menu {
                            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                                Button("\(r.formatted())×") { audio.setRate(Float(r)) }
                            }
                        } label: {
                            Text("\(Double(audio.rate).formatted())×").font(.headline)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.white.opacity(0.15), in: Capsule())
                        }
                    } else {
                        Button { withAnimation { showQueue.toggle() } } label: {
                            Image(systemName: "list.bullet").font(.title3)
                                .padding(10)
                                .background(Color.white.opacity(showQueue ? 0.25 : 0), in: Circle())
                        }
                        .accessibilityLabel("Queue")
                    }
                    Spacer()
                    RoutePicker().frame(width: 38, height: 38)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
            .background(TintedBackdrop(color: color))
            .artColor(from: app.client?.albumArtURL(for: item, width: 300), into: $color)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(audio.queue.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t, number: nil, showArt: true) { audio.jump(to: i) }
                            .id(i)
                            .opacity(i < audio.index ? 0.5 : 1)
                    }
                }
            }
            .onAppear { proxy.scrollTo(audio.index, anchor: .top) }
        }
        .frame(maxHeight: 420)
    }
}

/// Adds the mini player above the tab bar on every screen of a tab.
struct MiniPlayerInset: ViewModifier {
    @Environment(AudioPlayer.self) private var audio

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer().animation(.spring(response: 0.4, dampingFraction: 0.85), value: audio.current?.id)
            }
    }
}

/// Presents Now Playing (attach once, at the root).
struct NowPlayingPresenter: ViewModifier {
    @Environment(AudioPlayer.self) private var audio

    func body(content: Content) -> some View {
        @Bindable var audio = audio
        content.sheet(isPresented: $audio.showNowPlaying) {
            NowPlayingView().presentationDragIndicator(.hidden)
        }
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
    func withNowPlaying() -> some View { modifier(NowPlayingPresenter()) }
}
