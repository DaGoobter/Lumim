import Foundation
import AVFoundation
import Observation

enum DownloadKind: String, Codable {
    case original, hls
    var label: String { self == .original ? "Original file" : "Full-quality remux" }
}

enum DownloadState: String, Codable { case queued, downloading, completed, failed }

struct DownloadRecord: Codable, Identifiable, Hashable {
    var id: String { itemId }
    let itemId: String
    var item: BaseItem
    var kind: DownloadKind = .original
    var state: DownloadState = .queued
    var progress: Double = 0
    var relativePath: String?
    var posterPath: String?
    var mediaSourceId: String?
    var sizeBytes: Int64?
    var errorText: String?

    var localURL: URL? { relativePath.map(urlFromHome) }
    var posterURL: URL? { posterPath.map(urlFromHome) }
}

// MARK: - File locations

func downloadsDirectory() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The app's sandbox path changes between installs/updates, so we store paths relative to it.
func relativeToHome(_ url: URL) -> String {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let path = url.resolvingSymlinksInPath().path
    if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
    return path
}

func urlFromHome(_ path: String) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path)
        : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
}

// MARK: - Manager

/// Full-quality downloads:
/// - Files the phone can play natively (MP4/MOV) → the original file, byte-for-byte.
/// - Everything else (e.g. MKV) → an HLS remux saved with AVAssetDownloadTask. The video is copied
///   untouched (Dolby Vision/HDR preserved); only incompatible audio (TrueHD/DTS) is converted.
@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var records: [String: DownloadRecord] = [:]

    @ObservationIgnored private let delegate: DownloadDelegate
    @ObservationIgnored private let fileSession: URLSession
    @ObservationIgnored private let assetSession: AVAssetDownloadURLSession

    var sortedRecords: [DownloadRecord] {
        func key(_ r: DownloadRecord) -> String { r.item.displayTitle + " " + (r.item.episodeLabel ?? "") }
        return records.values.sorted { key($0) < key($1) }
    }

    private init() {
        let delegate = DownloadDelegate()
        self.delegate = delegate
        let fileConfig = URLSessionConfiguration.background(withIdentifier: "lumen.downloads.files")
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileSession = URLSession(configuration: fileConfig, delegate: delegate, delegateQueue: nil)

        let assetConfig = URLSessionConfiguration.background(withIdentifier: "lumen.downloads.hls")
        assetSession = AVAssetDownloadURLSession(configuration: assetConfig, assetDownloadDelegate: delegate,
                                                 delegateQueue: OperationQueue.main)
        load()
        reconcileInterrupted()
    }

    func start(item: BaseItem, client: JellyfinClient) async {
        if let existing = records[item.id], existing.state == .downloading || existing.state == .completed { return }
        var record = DownloadRecord(itemId: item.id, item: item)
        records[item.id] = record
        do {
            // Ask for a very high bitrate so the server never lowers quality for downloads.
            let info = try await client.playbackInfo(itemId: item.id, maxBitrate: 400_000_000)
            guard let src = info.mediaSources.first else { throw JellyfinError.noMediaSource }
            record.mediaSourceId = src.id
            record.sizeBytes = src.size

            if src.supportsDirectPlay == true {
                record.kind = .original
                let task = fileSession.downloadTask(with: client.originalDownloadURL(itemId: item.id))
                task.taskDescription = item.id
                task.resume()
            } else if let t = src.transcodingUrl, let url = client.absoluteURL(serverRelative: t) {
                record.kind = .hls
                let asset = AVURLAsset(url: url, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader],
                ])
                guard let task = assetSession.makeAssetDownloadTask(
                    asset: asset, assetTitle: item.displayTitle, assetArtworkData: nil,
                    options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 400_000_000]
                ) else { throw JellyfinError.noMediaSource }
                task.taskDescription = item.id
                task.resume()
            } else {
                throw JellyfinError.noMediaSource
            }
            record.state = .downloading
            records[item.id] = record
            save()
            await savePoster(for: item, client: client)
        } catch {
            record.state = .failed
            record.errorText = error.localizedDescription
            records[item.id] = record
            save()
        }
    }

    func retry(_ id: String, client: JellyfinClient) async {
        guard let r = records[id] else { return }
        records[id] = nil
        await start(item: r.item, client: client)
    }

    func delete(_ id: String) {
        if let r = records[id] {
            if let url = r.localURL { try? FileManager.default.removeItem(at: url) }
            if let url = r.posterURL { try? FileManager.default.removeItem(at: url) }
        }
        fileSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        assetSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        records[id] = nil
        save()
    }

    // MARK: Delegate callbacks (always on main)

    func updateProgress(_ id: String, _ value: Double) {
        guard var r = records[id], r.state != .completed else { return }
        r.state = .downloading
        r.progress = value
        records[id] = r
    }

    func finished(_ id: String, relativePath: String) {
        guard var r = records[id] else { return }
        r.relativePath = relativePath
        r.state = .completed
        r.progress = 1
        r.errorText = nil
        records[id] = r
        save()
    }

    func failed(_ id: String, _ message: String) {
        guard var r = records[id], r.state != .completed else { return }
        r.state = .failed
        r.errorText = message
        records[id] = r
        save()
    }

    // MARK: Persistence

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(records.values)) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: list.map { ($0.itemId, $0) })
    }

    /// If the app was force-quit mid-download, mark orphaned records as failed so they can be retried.
    private func reconcileInterrupted() {
        let pending = records.values.filter { $0.state == .downloading || $0.state == .queued }.map(\.itemId)
        guard !pending.isEmpty else { return }
        let assetSession = self.assetSession
        fileSession.getAllTasks { fileTasks in
            assetSession.getAllTasks { assetTasks in
                let active = Set((fileTasks + assetTasks).compactMap(\.taskDescription))
                Task { @MainActor in
                    for id in pending where !active.contains(id) {
                        DownloadManager.shared.failed(id, "Interrupted. Tap to retry.")
                    }
                }
            }
        }
    }

    private func savePoster(for item: BaseItem, client: JellyfinClient) async {
        guard let result = try? await URLSession.shared.data(from: client.posterURL(for: item, width: 500)) else { return }
        let data = result.0
        let url = downloadsDirectory().appendingPathComponent("\(item.id)-poster.jpg")
        guard (try? data.write(to: url)) != nil, var r = records[item.id] else { return }
        r.posterPath = relativeToHome(url)
        records[item.id] = r
        save()
    }
}

// MARK: - URLSession delegate (runs off the main actor, forwards to the manager)

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = JellyfinError.http(http.statusCode).localizedDescription
            Task { @MainActor in DownloadManager.shared.failed(id, msg) }
            return
        }
        // The temp file is deleted when this method returns, so move it synchronously.
        var ext = (downloadTask.response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        if ext.isEmpty { ext = "mp4" }
        let dest = downloadsDirectory().appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            let rel = relativeToHome(dest)
            Task { @MainActor in DownloadManager.shared.finished(id, relativePath: rel) }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.failed(id, msg) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in DownloadManager.shared.updateProgress(id, p) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let rel = relativeToHome(location)
        Task { @MainActor in DownloadManager.shared.finished(id, relativePath: rel) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let total = timeRangeExpectedToLoad.duration.seconds
        guard total > 0 else { return }
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        Task { @MainActor in DownloadManager.shared.updateProgress(id, min(1, loaded / total)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let msg = error.localizedDescription
        Task { @MainActor in DownloadManager.shared.failed(id, msg) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            AppDelegate.backgroundCompletionHandlers.removeValue(forKey: identifier)?()
        }
    }
}
