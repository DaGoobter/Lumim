import Foundation
import AVFoundation
import Observation

enum DownloadKind: String, Codable {
    case original, hls
    var label: String { self == .original ? "Original file" : "Full-quality remux" }
}

enum DownloadState: String, Codable { case queued, downloading, paused, completed, failed }

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
    var queuedAt: Date?
    /// Watch position from offline viewing, waiting to be sent to the server.
    var localPositionTicks: Int64?
    var localPlayed: Bool?
    var needsSync: Bool?

    var localURL: URL? { relativePath.map(urlFromHome) }
    var posterURL: URL? { posterPath.map(urlFromHome) }

    /// Where to resume: offline progress wins if it hasn't been synced yet.
    var resumeTicks: Int64 {
        if needsSync == true, let local = localPositionTicks { return local }
        return localPositionTicks ?? item.resumeTicks
    }

    /// Groups episodes under their show in the Downloads tab.
    var groupTitle: String { item.type == "Episode" ? (item.seriesName ?? "TV") : "Movies" }
}

struct DownloadGroup: Identifiable {
    let title: String
    let records: [DownloadRecord]
    var id: String { title }
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

/// Total bytes of a file or folder (HLS downloads are folders).
func diskSize(of url: URL) -> Int64 {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total: Int64 = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}

// MARK: - Manager

/// Full-quality downloads:
/// - Files the phone can play natively (MP4/MOV) → the original file, byte-for-byte.
/// - Everything else (e.g. MKV) → an HLS remux saved with AVAssetDownloadTask. The video is copied
///   untouched (Dolby Vision/HDR preserved); only incompatible audio (TrueHD/DTS) is converted.
/// Downloads run a couple at a time so a whole season doesn't start a dozen server jobs at once.
@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let maxConcurrent = 2

    private(set) var records: [String: DownloadRecord] = [:]

    @ObservationIgnored private let delegate: DownloadDelegate
    @ObservationIgnored private let fileSession: URLSession
    @ObservationIgnored private let assetSession: AVAssetDownloadURLSession
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var syncing = false

    var sortedRecords: [DownloadRecord] {
        func key(_ r: DownloadRecord) -> String { r.groupTitle + " " + r.item.displayTitle + " " + (r.item.episodeLabel ?? "") }
        return records.values.sorted { key($0) < key($1) }
    }

    /// Downloads grouped by show (movies together), for the Downloads tab.
    var groups: [DownloadGroup] {
        let grouped = Dictionary(grouping: sortedRecords, by: \.groupTitle)
        return grouped.keys.sorted { a, b in
            if a == "Movies" { return true }
            if b == "Movies" { return false }
            return a < b
        }.map { DownloadGroup(title: $0, records: grouped[$0] ?? []) }
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

    /// Called whenever the app has a (new) server connection.
    func attach(client: JellyfinClient) {
        self.client = client
        pumpQueue()
        Task { await syncOfflineProgress() }
    }

    // MARK: Queue

    func start(item: BaseItem, client: JellyfinClient) async {
        self.client = client
        if let existing = records[item.id], existing.state != .failed { return }
        var record = DownloadRecord(itemId: item.id, item: item)
        record.queuedAt = Date()
        records[item.id] = record
        save()
        pumpQueue()
        await savePoster(for: item, client: client)
    }

    /// Queue every episode in a list (e.g. a season). Already-downloaded ones are skipped.
    func startAll(_ items: [BaseItem], client: JellyfinClient) async {
        for item in items where item.isPlayable { await start(item: item, client: client) }
    }

    func retry(_ id: String, client: JellyfinClient) async {
        guard let r = records[id] else { return }
        records[id] = nil
        await start(item: r.item, client: client)
    }

    private func pumpQueue() {
        guard let client else { return }
        let active = records.values.filter { $0.state == .downloading }.count
        guard active < Self.maxConcurrent else { return }
        let next = records.values
            .filter { $0.state == .queued }
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }
            .prefix(Self.maxConcurrent - active)
        for r in next {
            var marked = r
            marked.state = .downloading
            records[r.itemId] = marked
            Task { await begin(r.itemId, client: client) }
        }
    }

    private func begin(_ id: String, client: JellyfinClient) async {
        guard var record = records[id] else { return }
        let item = record.item
        do {
            // Ask for a very high bitrate so the server never lowers quality for downloads.
            let info = try await client.playbackInfo(itemId: item.id, maxBitrate: 400_000_000)
            guard let src = info.mediaSources.first else { throw JellyfinError.noMediaSource }
            guard records[id] != nil else { return }   // deleted meanwhile
            record.mediaSourceId = src.id
            record.sizeBytes = src.size
            // Keep the full media info so offline Stream Info and badges work.
            if record.item.mediaSources == nil, let full = try? await client.item(item.id) { record.item = full }

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
            records[id] = record
            save()
        } catch {
            record.state = .failed
            record.errorText = error.localizedDescription
            records[id] = record
            save()
            pumpQueue()
        }
    }

    // MARK: Pause / resume / delete

    func pause(_ id: String) {
        guard var r = records[id], r.state == .downloading || r.state == .queued else { return }
        let wasQueued = r.state == .queued
        r.state = .paused
        records[id] = r
        save()
        if !wasQueued { forEachTask(id) { $0.suspend() } }
        pumpQueue()
    }

    func resume(_ id: String) {
        guard var r = records[id], r.state == .paused else { return }
        let assetSession = self.assetSession
        fileSession.getAllTasks { fileTasks in
            assetSession.getAllTasks { assetTasks in
                let task = (fileTasks + assetTasks).first { $0.taskDescription == id }
                task?.resume()
                let found = task != nil
                Task { @MainActor in
                    guard var rec = DownloadManager.shared.records[id] else { return }
                    // No live task (e.g. app was restarted): queue it to start fresh.
                    rec.state = found ? .downloading : .queued
                    rec.queuedAt = rec.queuedAt ?? Date()
                    DownloadManager.shared.records[id] = rec
                    DownloadManager.shared.save()
                    DownloadManager.shared.pumpQueue()
                }
            }
        }
        r.state = .downloading
        records[id] = r
    }

    func delete(_ id: String) {
        if let r = records[id] {
            if let url = r.localURL { try? FileManager.default.removeItem(at: url) }
            if let url = r.posterURL { try? FileManager.default.removeItem(at: url) }
        }
        forEachTask(id) { $0.cancel() }
        records[id] = nil
        save()
        pumpQueue()
    }

    func delete(all ids: [String]) { for id in ids { delete(id) } }

    private func forEachTask(_ id: String, _ body: @escaping @Sendable (URLSessionTask) -> Void) {
        fileSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach(body) }
        assetSession.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach(body) }
    }

    // MARK: Storage

    func storageUsed() -> Int64 {
        records.values.reduce(0) { total, r in
            total + (r.localURL.map(diskSize) ?? 0) + (r.posterURL.map(diskSize) ?? 0)
        }
    }

    static func freeSpace() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Offline progress

    /// Remember where offline playback got to; synced to the server when back online.
    func recordOfflineProgress(_ id: String, ticks: Int64) {
        guard var r = records[id] else { return }
        r.localPositionTicks = ticks
        if let total = r.item.runTimeTicks, total > 0 {
            r.localPlayed = Double(ticks) / Double(total) > 0.9
        }
        r.needsSync = true
        records[id] = r
        save()
    }

    func syncOfflineProgress() async {
        guard let client, !syncing else { return }
        syncing = true
        defer { syncing = false }
        for r in records.values where r.needsSync == true {
            let played = r.localPlayed == true
            let ok = await client.updateUserData(itemId: r.itemId,
                                                 positionTicks: played ? 0 : (r.localPositionTicks ?? 0),
                                                 played: played)
            guard ok, var rec = records[r.itemId] else { continue }
            rec.needsSync = false
            records[r.itemId] = rec
        }
        save()
    }

    // MARK: Delegate callbacks (always on main)

    func updateProgress(_ id: String, _ value: Double) {
        guard var r = records[id], r.state == .downloading || r.state == .queued else { return }
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
        pumpQueue()
    }

    func failed(_ id: String, _ message: String) {
        guard var r = records[id], r.state != .completed, r.state != .paused else { return }
        r.state = .failed
        r.errorText = message
        records[id] = r
        save()
        pumpQueue()
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

    /// If the app was force-quit mid-download, re-queue orphaned downloads so they start again.
    private func reconcileInterrupted() {
        let pending = records.values.filter { $0.state == .downloading }.map(\.itemId)
        guard !pending.isEmpty else { return }
        let assetSession = self.assetSession
        fileSession.getAllTasks { fileTasks in
            assetSession.getAllTasks { assetTasks in
                let active = Set((fileTasks + assetTasks).compactMap(\.taskDescription))
                Task { @MainActor in
                    let manager = DownloadManager.shared
                    for id in pending where !active.contains(id) {
                        guard var r = manager.records[id] else { continue }
                        r.state = .queued
                        r.progress = 0
                        manager.records[id] = r
                    }
                    manager.save()
                    manager.pumpQueue()
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
