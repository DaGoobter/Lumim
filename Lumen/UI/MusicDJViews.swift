import SwiftUI

// MARK: - Queue actions (context menus & "…" menus)

/// Play Next / Add to Queue / Start Radio for a song, album, playlist or artist.
struct MusicItemMenuItems: View {
    @Environment(AppState.self) private var app
    let item: BaseItem

    var body: some View {
        Group {
            Button { Task { AudioPlayer.shared.playNext(await tracks(), client: app.client) } } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { Task { AudioPlayer.shared.addToQueue(await tracks(), client: app.client) } } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button { startRadio() } label: {
                Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }

    private func tracks() async -> [BaseItem] {
        guard let client = app.client else { return item.isAudio ? [item] : [] }
        switch item.type {
        case "Audio": return [item]
        case "MusicAlbum": return (try? await client.albumTracks(item.id)) ?? []
        case "Playlist": return (try? await client.playlistItems(item.id)) ?? []
        case "MusicArtist":
            return (try? await client.browse([
                "artistIds": item.id, "includeItemTypes": "Audio", "recursive": "true",
                "sortBy": "Album,ParentIndexNumber,IndexNumber", "limit": "300",
            ]).items) ?? []
        default: return []
        }
    }

    private func startRadio() {
        guard let client = app.client else { return }
        let station = Stations.radio(name: "\(item.name ?? "Song") Radio", seedId: item.id)
        Task {
            await AudioPlayer.shared.play(station: station, client: client)
            AudioPlayer.shared.showNowPlaying = true
        }
    }
}

struct MusicItemMenu: View {
    let item: BaseItem
    var compact = false

    var body: some View {
        Menu { MusicItemMenuItems(item: item) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("More")
    }
}

struct QueueRow: View {
    @Environment(AppState.self) private var app
    let entry: QueueEntry

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: DownloadManager.shared.records[entry.item.id]?.posterURL
                        ?? app.client?.albumArtURL(for: entry.item, width: 120))
                .frame(width: 40, height: 40)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(entry.item.artistLine ?? "").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

// MARK: - For You (DJ + stations)

struct ForYouView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    let library: BaseItem
    @State private var genres: [BaseItem] = []
    @State private var topArtists: [NameId] = []
    @State private var starting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            DJCard(playing: audio.station?.name == "Huefin DJ", busy: starting == "Huefin DJ") {
                start(Stations.dj(libraryId: library.id))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Stations").font(.title2.weight(.bold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StationTile(title: "Heavy Rotation", subtitle: "Your most played", symbol: "flame.fill",
                                colors: [Theme.orange, Theme.red], busy: starting == "Heavy Rotation") {
                        start(Stations.heavyRotation(libraryId: library.id))
                    }
                    StationTile(title: "Favorites Mix", subtitle: "Songs you've hearted", symbol: "heart.fill",
                                colors: [Theme.red, Theme.violet], busy: starting == "Favorites Mix") {
                        start(Stations.favorites(libraryId: library.id))
                    }
                    StationTile(title: "Throwbacks", subtitle: "Not played in a while", symbol: "clock.arrow.circlepath",
                                colors: [Theme.green, Theme.blue], busy: starting == "Throwbacks") {
                        start(Stations.throwbacks(libraryId: library.id))
                    }
                    StationTile(title: "Discover", subtitle: "Never played yet", symbol: "sparkles",
                                colors: [Theme.yellow, Theme.green], busy: starting == "Discover") {
                        start(Stations.discover(libraryId: library.id))
                    }
                }
                StationTile(title: "Shuffle Everything", subtitle: "Your whole music library", symbol: "shuffle",
                            colors: [Theme.blue, Theme.violet], busy: starting == "Shuffle All") {
                    start(Stations.shuffleAll(libraryId: library.id))
                }
            }

            if !topArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Artist Radio").font(.title2.weight(.bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(topArtists, id: \.id) { artist in
                                Button { start(Stations.radio(name: "\(artist.name ?? "Artist") Radio", seedId: artist.id)) } label: {
                                    VStack(spacing: 8) {
                                        RemoteImage(url: app.client?.imageURL(artist.id, maxWidth: 240))
                                            .frame(width: 96, height: 96)
                                            .clipped()
                                            .clipShape(Circle())
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "dot.radiowaves.left.and.right")
                                                    .font(.caption.bold()).padding(6)
                                                    .background(Theme.gradient, in: Circle())
                                            }
                                        Text(artist.name ?? "").font(.caption.weight(.semibold)).lineLimit(1).frame(width: 96)
                                    }
                                }
                                .buttonStyle(CardPressStyle())
                            }
                        }
                    }
                }
            }

            if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Genre Radio").font(.title2.weight(.bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(genres) { genre in
                                Button { start(Stations.radio(name: "\(genre.name ?? "Genre") Radio", seedId: genre.id)) } label: {
                                    Text(genre.name ?? "")
                                        .font(.subheadline.weight(.bold))
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .background(genreGradient(genre.name ?? ""), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(CardPressStyle())
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding()
        .task { await load() }
    }

    private func genreGradient(_ name: String) -> LinearGradient {
        let hue = Double(abs(name.hashValue % 360)) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.75, brightness: 0.75),
                                       Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.5)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func start(_ station: Station) {
        guard let client = app.client, starting == nil else { return }
        starting = station.name
        Task {
            await audio.play(station: station, client: client)
            starting = nil
            if audio.current != nil { audio.showNowPlaying = true }
        }
    }

    private func load() async {
        guard let client = app.client, genres.isEmpty else { return }
        genres = (try? await client.musicGenres(parentId: library.id)) ?? []
        let top = await client.songs(parentId: library.id, sortBy: "PlayCount", filters: "IsPlayed", limit: 80)
        var seen = Set<String>()
        topArtists = top.compactMap { $0.artistItems?.first }.filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
    }
}

/// The big, animated Huefin DJ card.
struct DJCard: View {
    let playing: Bool
    let busy: Bool
    let action: () -> Void
    @State private var animate = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Theme.violet, Theme.red, Theme.orange, Theme.blue],
                               startPoint: animate ? .topLeading : .bottomLeading,
                               endPoint: animate ? .bottomTrailing : .topTrailing)
                    .hueRotation(.degrees(animate ? 25 : -10))
                Circle().fill(.white.opacity(0.18)).frame(width: 220).blur(radius: 40)
                    .offset(x: animate ? 160 : 60, y: animate ? -40 : -90)
                VStack(alignment: .leading, spacing: 6) {
                    Label("HUEFIN DJ", systemImage: "waveform.and.mic").font(.caption.weight(.heavy))
                    Text("Your music, mixed for you").font(.title2.weight(.heavy))
                    Text("Heavy rotation, favorites, throwbacks and new finds, with a voice between sets.")
                        .font(.footnote.weight(.medium)).opacity(0.9).lineLimit(2)
                }
                .padding(18)
                .padding(.trailing, 70)
            }
            .frame(height: 180)
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(.white).frame(width: 54, height: 54)
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: playing ? "waveform" : "play.fill")
                            .font(.title2.weight(.bold)).foregroundStyle(.black)
                            .symbolEffect(.variableColor.iterative, isActive: playing)
                    }
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Theme.violet.opacity(0.45), radius: 20, y: 10)
        }
        .buttonStyle(CardPressStyle())
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { animate = true }
        }
        .accessibilityLabel(playing ? "Huefin DJ, playing" : "Play Huefin DJ")
    }
}

struct StationTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: symbol).font(.title3.weight(.bold))
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Image(systemName: "play.circle.fill").font(.title3) }
                }
                Spacer(minLength: 10)
                Text(title).font(.headline.weight(.heavy)).lineLimit(1)
                Text(subtitle).font(.caption.weight(.medium)).opacity(0.85).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(CardPressStyle())
    }
}
