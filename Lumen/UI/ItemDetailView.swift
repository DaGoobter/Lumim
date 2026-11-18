import SwiftUI

struct ItemDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var landscape: Bool { verticalSizeClass == .compact }

    let itemId: String
    let preview: BaseItem?

    @State private var item: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [BaseItem] = []
    @State private var playRequest: PlaybackRequest?
    @State private var error: String?
    @State private var artColor: ArtColor?

    private var shown: BaseItem? { item ?? preview }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if let it = shown {
                    VStack(alignment: .leading, spacing: 0) {
                        if landscape {
                            // Phone landscape: info on the left, full artwork on the right.
                            HStack(alignment: .center, spacing: 24) {
                                VStack(alignment: .leading, spacing: 14) {
                                    titleBlock(it)
                                    metaLine(it)
                                    badges(it)
                                    actions(it)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                ArtHeader(url: app.client?.backdropURL(for: it, width: 1920),
                                          width: geo.size.width * 0.55, maxHeight: geo.size.height * 0.8)
                            }
                            .padding(.leading, 20)
                            .padding(.top, 48)
                        } else {
                            // Art runs edge to edge, up under the Dynamic Island.
                            ArtHeader(url: app.client?.backdropURL(for: it, width: 1920),
                                      width: geo.size.width, maxHeight: geo.size.height * 0.55)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            if !landscape {
                                titleBlock(it)
                                metaLine(it)
                                badges(it)
                                actions(it)
                            }
                            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                            if let overview = it.overview {
                                Text(overview).font(.callout).foregroundStyle(.white.opacity(0.85))
                            }
                            if let genres = it.genres, !genres.isEmpty {
                                Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            if it.isSeries { seasonSection }
                            if let src = it.mediaSources?.first, it.isPlayable { TechSpecs(source: src) }
                        }
                        .padding()
                        .frame(maxWidth: 900, alignment: .leading)
                    }
                } else {
                    ProgressView().padding(.top, 200).frame(maxWidth: .infinity)
                }
            }
            .ignoresSafeArea(edges: .top)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    TintedBackdrop(color: artColor)
                    AmbientGlow(url: shown.flatMap { app.client?.backdropURL(for: $0, width: 600) },
                                size: geo.size)
                }
            }
        }
        .background(Theme.background)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .artColor(from: shown.flatMap { app.client?.backdropURL(for: $0, width: 400) }, into: $artColor)
        .fullScreenCover(item: $playRequest, onDismiss: { Task { await load() } }) { PlayerScreen(request: $0) }
    }

    // MARK: Sections

    @ViewBuilder
    private func badges(_ it: BaseItem) -> some View {
        if let src = it.mediaSources?.first, !src.badges.isEmpty {
            HStack(spacing: 6) { ForEach(src.badges, id: \.self) { Badge(text: $0) } }
        }
    }

    private func titleBlock(_ it: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LogoOrTitle(url: app.client?.logoURL(for: it), title: it.displayTitle)
            if let ep = it.episodeLabel { Text(ep).font(.headline).foregroundStyle(.secondary) }
        }
        .padding(.top, 4)
    }

    private func metaLine(_ it: BaseItem) -> some View {
        let parts: [String] = [
            it.productionYear.map(String.init),
            it.officialRating,
            it.runtimeText,
            it.communityRating.map { String(format: "★ %.1f", $0) },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  ")).font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actions(_ it: BaseItem) -> some View {
        HStack(spacing: 12) {
            Button { Task { await play(it) } } label: {
                Label(it.progress != nil ? "Resume \(remaining(it))" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(PlayButtonStyle())

            if it.isPlayable { DownloadButton(item: it) }
        }
        if let p = it.progress { ProgressBar(value: p).frame(maxWidth: 260) }
    }

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        let selected = season.id == selectedSeason
                        Button(season.name ?? "Season") {
                            selectedSeason = season.id
                            Task { await loadEpisodes() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card), in: Capsule())
                        .foregroundStyle(.white)
                    }
                }
            }
            if !episodes.isEmpty, let client = app.client {
                let pending = episodes.filter { downloads.records[$0.id] == nil }
                Button {
                    Task { await downloads.startAll(pending, client: client) }
                } label: {
                    Label(pending.isEmpty ? "Season downloaded" : "Download season (\(pending.count))",
                          systemImage: pending.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(pending.isEmpty)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(episodes) { ep in EpisodeRow(episode: ep) { playRequest = PlaybackRequest(item: ep, startTicks: ep.resumeTicks) } }
            }
        }
    }

    // MARK: Logic

    private func remaining(_ it: BaseItem) -> String {
        guard let total = it.runTimeTicks else { return "" }
        let left = total - it.resumeTicks
        return left > 0 ? "· \(formatTicks(left)) left" : ""
    }

    private func play(_ it: BaseItem) async {
        if it.isSeries {
            guard let client = app.client else { return }
            let next = (try? await client.nextUp(seriesId: it.id))?.first ?? episodes.first
            if let next { playRequest = PlaybackRequest(item: next, startTicks: next.resumeTicks) }
            return
        }
        if let local = downloads.records[it.id], local.state == .completed {
            playRequest = PlaybackRequest(item: it, startTicks: local.needsSync == true ? local.resumeTicks : it.resumeTicks,
                                          localDownload: local)
        } else {
            playRequest = PlaybackRequest(item: it, startTicks: it.resumeTicks)
        }
    }

    private func load() async {
        guard let client = app.client else {
            item = downloads.records[itemId]?.item
            return
        }
        do {
            let full = try await client.item(itemId)
            item = full
            error = nil
            if full.isSeries {
                seasons = try await client.seasons(seriesId: full.id)
                if selectedSeason == nil {
                    let next = try? await client.nextUp(seriesId: full.id).first
                    selectedSeason = next?.seasonId ?? seasons.first?.id
                }
                await loadEpisodes()
            }
        } catch {
            if item == nil, let offline = downloads.records[itemId]?.item { item = offline }
            self.error = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let client = app.client, let seriesId = shown?.id, let season = selectedSeason else { return }
        episodes = (try? await client.episodes(seriesId: seriesId, seasonId: season)) ?? []
    }
}

struct EpisodeRow: View {
    @Environment(AppState.self) private var app
    let episode: BaseItem
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: 150)
                    .overlay { RemoteImage(url: app.client?.imageURL(episode.id, maxWidth: 400, tag: episode.imageTag("primary"))) }
                    .overlay { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9)) }
                    .overlay(alignment: .bottom) { if let p = episode.progress { ProgressBar(value: p).padding(6) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(CardPressStyle())

            NavigationLink(value: episode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name ?? "")")
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        if let rt = episode.runtimeText { Text(rt) }
                        if episode.userData?.played == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let o = episode.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CardPressStyle())
        }
    }
}

struct DownloadButton: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: BaseItem

    var body: some View {
        let record = downloads.records[item.id]
        Button {
            guard let client = app.client else { return }
            if record?.state == .failed {
                Task { await downloads.retry(item.id, client: client) }
            } else if record?.state == .paused {
                downloads.resume(item.id)
            } else if record?.state == .downloading || record?.state == .queued {
                downloads.pause(item.id)
            } else if record == nil {
                Task { await downloads.start(item: item, client: client) }
            }
        } label: {
            Group {
            switch record?.state {
            case .completed?:
                Image(systemName: "checkmark.circle.fill")
            case .downloading?:
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: record?.progress ?? 0)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 20, height: 20)
            case .queued?:
                Image(systemName: "clock")
            case .paused?:
                Image(systemName: "pause.circle")
            case .failed?:
                Image(systemName: "exclamationmark.arrow.circlepath")
            case nil:
                Image(systemName: "arrow.down.circle")
            }
            }
            .font(.title3)
            .frame(width: 22, height: 22)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel("Download")
    }
}

struct TechSpecs: View {
    let source: MediaSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media").font(.headline)
            if let v = source.videoStream {
                spec("Video", v.displayTitle ?? v.codec ?? "")
                if let range = v.videoRangeType { spec("Range", range + (v.dvProfile.map { " (DV Profile \($0))" } ?? "")) }
            }
            ForEach(Array(source.audioStreams.enumerated()), id: \.offset) { i, a in
                spec(i == 0 ? "Audio" : "", a.displayTitle ?? a.codec ?? "")
            }
            spec("Container", source.container ?? "")
            if let size = source.size { spec("Size", formatBytes(size)) }
            if let b = source.bitrate { spec("Bitrate", String(format: "%.1f Mbps", Double(b) / 1_000_000)) }
            if !source.subtitleStreams.isEmpty { spec("Subtitles", "\(source.subtitleStreams.count) tracks") }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func spec(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}
