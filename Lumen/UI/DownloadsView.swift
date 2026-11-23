import SwiftUI

struct DownloadsView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var playRequest: PlaybackRequest?
    @State private var reading: (book: BaseItem, file: BookFile)?
    @State private var showReader = false
    @State private var used: Int64 = 0
    @State private var free: Int64?

    var body: some View {
        Group {
            if downloads.records.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Tap the download button on any movie or episode, or download a whole season from its page. Files download at full quality."))
            } else {
                List {
                    Section {
                        StorageBar(used: used, free: free)
                            .listRowBackground(Theme.card)
                    }
                    if !downloads.smartRules.isEmpty {
                        Section {
                            ForEach(downloads.smartRules.values.sorted { $0.name < $1.name }, id: \.seriesId) { rule in
                                HStack {
                                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                                    Text(rule.name)
                                    Spacer()
                                    Text("Next \(rule.count)").foregroundStyle(.secondary)
                                }
                                .listRowBackground(Theme.card)
                                .swipeActions {
                                    Button("Stop", role: .destructive) {
                                        downloads.setSmart(seriesId: rule.seriesId, name: rule.name, count: 0)
                                    }
                                }
                            }
                        } header: {
                            Text("Smart downloads")
                        } footer: {
                            Text("These shows keep their next unwatched episodes downloaded and clear out watched ones. Swipe to stop.")
                        }
                    }
                    ForEach(downloads.groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                Button { tap(record) } label: { DownloadRow(record: record) }
                                    .listRowBackground(Theme.card)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { downloads.delete(record.itemId) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        if record.state == .downloading || record.state == .queued {
                                            Button { downloads.pause(record.itemId) } label: {
                                                Label("Pause", systemImage: "pause.fill")
                                            }.tint(.orange)
                                        } else if record.state == .paused {
                                            Button { downloads.resume(record.itemId) } label: {
                                                Label("Resume", systemImage: "play.fill")
                                            }.tint(Theme.accent)
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                if group.records.count > 1 {
                                    Menu {
                                        Button(role: .destructive) {
                                            downloads.delete(all: group.records.map(\.itemId))
                                        } label: { Label("Delete all \(group.records.count)", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Downloads")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .fullScreenCover(item: $playRequest) { PlayerScreen(request: $0) }
        .fullScreenCover(isPresented: $showReader) {
            if let reading { BookReaderScreen(book: reading.book, file: reading.file) }
        }
        .task(id: downloads.records.count) { refreshStorage() }
        .onChange(of: downloads.records.values.filter { $0.state == .completed }.count) { refreshStorage() }
    }

    private func refreshStorage() {
        used = downloads.storageUsed()
        free = DownloadManager.freeSpace()
    }

    private func tap(_ record: DownloadRecord) {
        switch record.state {
        case .completed where record.item.isAudio:
            // Play this song/audiobook and the rest of its album/book from the downloads.
            let group = downloads.groups.first { $0.title == record.groupTitle }?.records
                .filter { $0.state == .completed && $0.item.isAudio }.map(\.item) ?? [record.item]
            let start = group.firstIndex { $0.id == record.itemId } ?? 0
            AudioPlayer.shared.play(group, startAt: start, client: app.client)
            AudioPlayer.shared.showNowPlaying = true
        case .completed where record.item.isBook:
            if let url = record.localURL {
                reading = (record.item, BookFile(url: url, kind: BookFile.kind(for: url.pathExtension)))
                showReader = true
            }
        case .completed:
            playRequest = PlaybackRequest(item: record.item, startTicks: record.resumeTicks, localDownload: record)
        case .failed:
            if let client = app.client { Task { await downloads.retry(record.itemId, client: client) } }
        case .paused:
            downloads.resume(record.itemId)
        case .downloading, .queued:
            downloads.pause(record.itemId)
        }
    }
}

struct StorageBar: View {
    let used: Int64
    let free: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(formatBytes(used)) used", systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let free { Text("\(formatBytes(free)) free").font(.caption).foregroundStyle(.secondary) }
            }
            if let free, used + free > 0 {
                ProgressBar(value: Double(used) / Double(used + free))
            }
        }
        .padding(.vertical, 4)
    }
}

struct DownloadRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 54, height: 81)
                .overlay { RemoteImage(url: record.posterURL) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let ep = record.item.episodeLabel { Text(ep).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                status
            }
            Spacer()
            if record.state == .completed { Image(systemName: record.item.isBook ? "book.circle.fill" : "play.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var status: some View {
        switch record.state {
        case .queued:
            Text("Waiting… (\(record.kind.label))").font(.caption2).foregroundStyle(.secondary)
        case .paused:
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: record.progress).opacity(0.5)
                Text("Paused · \(Int(record.progress * 100))% · tap to resume").font(.caption2).foregroundStyle(.secondary)
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: record.progress)
                Text("\(Int(record.progress * 100))% · \(record.kind.label)").font(.caption2).foregroundStyle(.secondary)
            }
        case .completed:
            Text([record.kind.label, record.sizeBytes.map(formatBytes),
                  record.needsSync == true ? "progress will sync when online" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text(record.errorText ?? "Failed. Tap to retry.").font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }
}
