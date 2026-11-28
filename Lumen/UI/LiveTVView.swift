import SwiftUI

/// Live channels from the server's M3U tuners, with what's on now and next.
struct LiveTVView: View {
    @Environment(AppState.self) private var app
    @State private var channels: [BaseItem] = []
    @State private var guide: [String: [ProgramInfo]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var playRequest: PlaybackRequest?
    @AppStorage("prism.liveLayout") private var layout = "list"

    private var filtered: [BaseItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return channels }
        return channels.filter { ch in
            (ch.name ?? "").localizedCaseInsensitiveContains(q)
                || (ch.channelNumber ?? "").hasPrefix(q)
                || (nowPlaying(ch)?.title ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Group {
            if loading && channels.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if channels.isEmpty {
                ContentUnavailableView {
                    Label("No Live TV", systemImage: "tv")
                } description: {
                    Text(error ?? "Add your M3U playlist on the server under Dashboard → Live TV → Tuner Devices, and an XMLTV guide for program info.")
                } actions: {
                    Button("Reload") { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
                }
            } else if layout == "guide" {
                LiveGuideGrid(channels: filtered, guide: guide) { play($0) }
                    .searchable(text: $search, prompt: "Channels or shows")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Refresh the now/next lines every minute.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            LazyVStack(spacing: 12) {
                                ForEach(filtered) { channel in
                                    Button { play(channel) } label: {
                                        ChannelRow(channel: channel, now: nowPlaying(channel, at: context.date),
                                                   next: nextUp(channel, at: context.date), date: context.date)
                                    }
                                    .buttonStyle(CardPressStyle())
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .searchable(text: $search, prompt: "Channels or shows")
            }
        }
        .background(TintedBackdrop(color: ArtColor(hue: 0.98, saturation: 0.7, brightness: 0.8)))
        .navigationTitle("Live TV")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Layout", selection: $layout) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "calendar.day.timeline.left").tag("guide")
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .accessibilityLabel("Channel list or guide")
            }
            ToolbarItem(placement: .topBarTrailing) { AccountButton() }
        }
        .task { if channels.isEmpty { await load() } }
        .refreshable { await load() }
        .fullScreenCover(item: $playRequest) { PlayerScreen(request: $0) }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true
        do {
            channels = try await client.liveChannels()
            guide = (try? await client.liveGuide(hours: 6)) ?? [:]
            error = nil
        } catch {
            self.error = "Couldn't load channels: \(error.localizedDescription)"
        }
        loading = false
    }

    private func programs(_ channel: BaseItem) -> [ProgramInfo] { guide[channel.id] ?? [] }

    private func nowPlaying(_ channel: BaseItem, at date: Date = Date()) -> ProgramInfo? {
        programs(channel).first { ($0.start ?? .distantFuture) <= date && ($0.end ?? .distantPast) > date }
            ?? channel.currentProgram
    }

    private func nextUp(_ channel: BaseItem, at date: Date) -> ProgramInfo? {
        programs(channel).first { ($0.start ?? .distantPast) > date }
    }

    private func play(_ channel: BaseItem) {
        playRequest = PlaybackRequest(item: channel, startTicks: 0)
    }
}

struct ChannelRow: View {
    @Environment(AppState.self) private var app
    let channel: BaseItem
    let now: ProgramInfo?
    let next: ProgramInfo?
    let date: Date

    var body: some View {
        HStack(spacing: 14) {
            // Channel logo
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.wash)
                AsyncImage(url: app.client?.imageURL(channel.id, maxWidth: 240, tag: channel.imageTag("primary"))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(8)
                    } else {
                        Text(String((channel.name ?? "TV").prefix(3)).uppercased())
                            .font(.headline.weight(.heavy)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 96, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let n = channel.channelNumber, !n.isEmpty {
                        Text(n).font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                    }
                    Text(channel.name ?? "Channel").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(now?.title.isEmpty == false ? now!.title : (channel.name ?? "Live"))
                    .font(.subheadline.weight(.bold)).lineLimit(1)
                if let p = now?.progress(at: date) {
                    ProgressBar(value: p).frame(maxWidth: 220)
                }
                if let next, let start = next.start {
                    Text("Next \(start.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.primary)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sticker(18, depth: 3)
        .foregroundStyle(.primary)
    }
}
