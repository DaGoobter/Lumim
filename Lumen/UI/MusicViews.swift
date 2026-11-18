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
                        .clipped()
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
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RemoteImage(url: app.client?.albumArtURL(for: album, width: 800)) }
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
                    CollectionDownloadButton(items: tracks)
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
                    .clipped()
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

/// Downloads a whole album/playlist; shows progress across its tracks.
struct CollectionDownloadButton: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let items: [BaseItem]

    var body: some View {
        let states = items.map { downloads.records[$0.id]?.state }
        let done = states.filter { $0 == .completed }.count
        let active = states.filter { $0 == .downloading || $0 == .queued }.count
        let allDone = !items.isEmpty && done == items.count
        Button {
            guard let client = app.client, !allDone else { return }
            Task { await downloads.startAll(items, client: client) }
        } label: {
            Image(systemName: allDone ? "checkmark.circle.fill" : (active > 0 ? "arrow.down.circle.dotted" : "arrow.down.circle"))
                .font(.title3)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel(allDone ? "Downloaded" : (active > 0 ? "Downloading \(done) of \(items.count)" : "Download all"))
    }
}

// MARK: - Mini player & Now Playing

/// Apple Music–style floating mini player.
struct MiniPlayer: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio

    var body: some View {
        if let item = audio.current {
            HStack(spacing: 12) {
                RemoteImage(url: app.client?.albumArtURL(for: item, width: 120))
                    .frame(width: 40, height: 40)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let artist = item.artistLine {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { audio.togglePlay() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                Button { audio.isAudiobook ? audio.skip(by: 30) : audio.next() } label: {
                    Image(systemName: audio.isAudiobook ? "goforward.30" : "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .disabled(!audio.isAudiobook && !audio.hasNext)
                .accessibilityLabel(audio.isAudiobook ? "Forward 30 seconds" : "Next")
            }
            .foregroundStyle(.primary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 56)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .contentShape(Capsule())
            .onTapGesture { audio.showNowPlaying = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Apple Music–style Now Playing: edge-to-edge artwork melting into a blurred wash of the same art.
struct NowPlayingView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var volume = SystemVolume()

    var body: some View {
        if let item = audio.current {
            GeometryReader { geo in
                let artURL = DownloadManager.shared.records[item.id]?.posterURL ?? app.client?.albumArtURL(for: item, width: 1200)
                let artSize = min(geo.size.width, geo.size.height * 0.52)
                ZStack(alignment: .top) {
                    // Blurred artwork wash behind everything.
                    RemoteImage(url: artURL)
                        .frame(width: geo.size.width + 200, height: geo.size.height + 200)
                        .blur(radius: 70)
                        .overlay(Color.black.opacity(0.35))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        if showQueue {
                            queueHeader(item: item, artURL: artURL)
                                .padding(.top, geo.safeAreaInsets.top + 24)
                            queueList
                        } else {
                            // Full-width artwork that fades into the background.
                            Color.clear
                                .frame(width: artSize, height: artSize)
                                .overlay { RemoteImage(url: artURL) }
                                .clipped()
                                .mask(LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.72),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom))
                                .scaleEffect(audio.isPlaying ? 1 : 0.94, anchor: .top)
                                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: audio.isPlaying)
                                .onTapGesture { dismiss() }
                            titleRow(item: item)
                                .padding(.horizontal, 28)
                                .padding(.top, -24)
                        }

                        Spacer(minLength: 12)
                        controls
                            .padding(.horizontal, 28)
                            .padding(.bottom, geo.safeAreaInsets.bottom + 12)
                    }
                    .frame(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
                    .ignoresSafeArea()

                    Capsule().fill(.white.opacity(0.4)).frame(width: 38, height: 5)
                        .padding(.top, 8)
                        .onTapGesture { dismiss() }
                }
            }
            .foregroundStyle(.white)
            .overlay { SystemVolumeHost(volume: volume).frame(width: 1, height: 1).opacity(0.01) }
        } else {
            Color.black.onAppear { dismiss() }
        }
    }

    private func titleRow(item: BaseItem) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "").font(.title3.weight(.bold)).lineLimit(1)
                Text(item.artistLine ?? item.album ?? "").font(.title3).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(spacing: 26) {
            // Scrubber
            VStack(spacing: 6) {
                ThinSlider(value: audio.currentTime, range: 0...max(audio.duration, 1)) { audio.seek(to: $0) }
                HStack {
                    Text(clock(audio.currentTime))
                    Spacer()
                    Text("-" + clock(max(0, audio.duration - audio.currentTime)))
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }

            // Transport
            HStack {
                Spacer()
                if audio.isAudiobook {
                    Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .accessibilityLabel("Back 15 seconds")
                } else {
                    Button { audio.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                }
                Spacer()
                Button { audio.togglePlay() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 50))
                        .frame(width: 70, height: 70)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                Spacer()
                if audio.isAudiobook {
                    Button { audio.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                        .accessibilityLabel("Forward 30 seconds")
                } else {
                    Button { audio.next() } label: { Image(systemName: "forward.fill") }
                        .disabled(!audio.hasNext)
                        .accessibilityLabel("Next")
                }
                Spacer()
            }
            .font(.system(size: 34))

            // Volume
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").font(.caption)
                ThinSlider(value: Double(volume.level), range: 0...1) { volume.set(Float($0)) }
                Image(systemName: "speaker.wave.3.fill").font(.caption)
            }
            .foregroundStyle(.white.opacity(0.6))

            // Bottom row
            HStack {
                if audio.isAudiobook {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                            Button("\(r.formatted())×") { audio.setRate(Float(r)) }
                        }
                    } label: {
                        Text("\(Double(audio.rate).formatted())×").font(.subheadline.weight(.bold))
                            .frame(width: 44, height: 32)
                    }
                    .accessibilityLabel("Playback speed")
                } else {
                    Color.clear.frame(width: 44, height: 32)
                }
                Spacer()
                RoutePicker().frame(width: 32, height: 32)
                Spacer()
                Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showQueue.toggle() } } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 32)
                        .background(Color.white.opacity(showQueue ? 0.25 : 0), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Up Next")
            }
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func queueHeader(item: BaseItem, artURL: URL?) -> some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 64)
                .overlay { RemoteImage(url: artURL) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "").font(.headline).lineLimit(1)
                Text(item.artistLine ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Up Next").font(.headline).padding(.horizontal).padding(.top, 18).padding(.bottom, 6)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(audio.queue.enumerated()), id: \.offset) { i, t in
                            TrackRow(track: t, number: nil, showArt: true) { audio.jump(to: i) }
                                .id(i)
                                .opacity(i < audio.index ? 0.45 : 1)
                        }
                    }
                }
            }
            .onAppear { proxy.scrollTo(audio.index, anchor: .top) }
        }
    }
}

/// Apple Music–style thin slider: no knob, thickens while dragging.
struct ThinSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let shown = dragValue ?? value
            let fraction = min(1, max(0, (shown - range.lowerBound) / span))
            let active = dragValue != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(active ? 1 : 0.75)).frame(width: geo.size.width * fraction)
            }
            .frame(height: active ? 12 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(1, max(0, g.location.x / geo.size.width))
                        dragValue = range.lowerBound + f * span
                    }
                    .onEnded { _ in
                        if let v = dragValue { onCommit(v) }
                        dragValue = nil
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 24)
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
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.black)
                .presentationCornerRadius(36)
        }
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
    func withNowPlaying() -> some View { modifier(NowPlayingPresenter()) }
}
