import SwiftUI

struct DownloadsView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var playRequest: PlaybackRequest?

    var body: some View {
        Group {
            if downloads.records.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Tap the download button on any movie or episode. Files download at full quality."))
            } else {
                List {
                    ForEach(downloads.sortedRecords) { record in
                        Button { tap(record) } label: { DownloadRow(record: record) }
                            .listRowBackground(Theme.card)
                    }
                    .onDelete { offsets in
                        let list = downloads.sortedRecords
                        for i in offsets { downloads.delete(list[i].itemId) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("Downloads")
        .fullScreenCover(item: $playRequest) { PlayerScreen(request: $0) }
    }

    private func tap(_ record: DownloadRecord) {
        switch record.state {
        case .completed:
            playRequest = PlaybackRequest(item: record.item, startTicks: record.item.resumeTicks, localDownload: record)
        case .failed:
            if let client = app.client { Task { await downloads.retry(record.itemId, client: client) } }
        default:
            break
        }
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
            if record.state == .completed { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var status: some View {
        switch record.state {
        case .queued:
            Text("Preparing…").font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: record.progress)
                Text("\(Int(record.progress * 100))% · \(record.kind.label)").font(.caption2).foregroundStyle(.secondary)
            }
        case .completed:
            Text([record.kind.label, record.sizeBytes.map(formatBytes)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text(record.errorText ?? "Failed. Tap to retry.").font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }
}
