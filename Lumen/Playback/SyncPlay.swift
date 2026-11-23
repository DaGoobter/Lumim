import SwiftUI
import Observation

/// Watch Together, using Jellyfin's built-in SyncPlay. Everyone in a group plays, pauses and seeks together,
/// including people using Jellyfin's web app or other SyncPlay-capable clients.
@MainActor @Observable
final class SyncPlayManager {
    static let shared = SyncPlayManager()

    struct GroupInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let participants: [String]
    }

    enum Request { case pause, unpause, seek(Int64) }

    private(set) var groupId: String?
    private(set) var groupName: String?
    private(set) var participants: [String] = []
    private(set) var status: String?

    @ObservationIgnored private weak var model: PlayerModel?
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    /// serverTime ≈ localTime + offset
    @ObservationIgnored private var offset: TimeInterval = 0
    @ObservationIgnored private var playlistItemId: String?
    @ObservationIgnored private var currentItemId: String?

    private init() {}

    // MARK: Player binding

    func bind(_ model: PlayerModel) {
        self.model = model
        model.disableAutoNext()
    }

    func unbind(_ model: PlayerModel) {
        if self.model === model { self.model = nil }
    }

    /// True when this player's play/pause/seek should go through the group.
    func controls(_ model: PlayerModel) -> Bool { groupId != nil && self.model === model }

    // MARK: Groups

    func listGroups(client: JellyfinClient) async -> [GroupInfo] {
        guard let data = try? await client.send("SyncPlay/List", method: "GET"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { g in
            guard let id = g["GroupId"] as? String else { return nil }
            return GroupInfo(id: id, name: g["GroupName"] as? String ?? "Group",
                             participants: g["Participants"] as? [String] ?? [])
        }
    }

    /// Start a group around what this player is showing.
    func create(client: JellyfinClient, model: PlayerModel, name: String) async throws {
        try await connect(client: client)
        bind(model)
        try await client.send("SyncPlay/New", body: ["GroupName": name])
        // Wait briefly for GroupJoined, then hand the group our video and position.
        for _ in 0..<25 where groupId == nil { try? await Task.sleep(for: .milliseconds(200)) }
        currentItemId = model.item.id
        try await client.send("SyncPlay/SetNewQueue", body: [
            "PlayingQueue": [model.item.id], "PlayingItemPosition": 0, "StartPositionTicks": model.positionTicks,
        ])
    }

    func join(client: JellyfinClient, group: GroupInfo, model: PlayerModel?) async throws {
        try await connect(client: client)
        if let model { bind(model) }
        try await client.send("SyncPlay/Join", body: ["GroupId": group.id])
    }

    func leave() async {
        if let client { _ = try? await client.send("SyncPlay/Leave") }
        reset()
    }

    func request(_ r: Request) async {
        guard let client else { return }
        switch r {
        case .pause: _ = try? await client.send("SyncPlay/Pause")
        case .unpause: _ = try? await client.send("SyncPlay/Unpause")
        case .seek(let ticks): _ = try? await client.send("SyncPlay/Seek", body: ["PositionTicks": ticks])
        }
    }

    private func reset() {
        groupId = nil
        groupName = nil
        participants = []
        status = nil
        playlistItemId = nil
        clockTask?.cancel()
        commandTask?.cancel()
    }

    func connectionLost() {
        if groupId != nil { status = "Connection lost. Reconnecting…" }
    }

    // MARK: Connection

    private func connect(client: JellyfinClient) async throws {
        self.client = client
        await SessionSocket.shared.connect(client)
        guard SessionSocket.shared.isConnected else { throw JellyfinError.badURL }
        await syncClock(client)
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.groupId != nil, let c = self.client else { continue }
                await self.syncClock(c)
            }
        }
    }

    /// Estimates the difference between this phone's clock and the server's (NTP-style).
    private func syncClock(_ client: JellyfinClient) async {
        var best: (rtt: TimeInterval, offset: TimeInterval)?
        for _ in 0..<3 {
            let t0 = Date()
            guard let data = try? await client.send("GetUtcTime", method: "GET"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r1 = (obj["RequestReceptionTime"] as? String).flatMap(parseJellyfinDate),
                  let r2 = (obj["ResponseTransmissionTime"] as? String).flatMap(parseJellyfinDate) else { continue }
            let t3 = Date()
            let rtt = t3.timeIntervalSince(t0) - r2.timeIntervalSince(r1)
            let off = (r1.timeIntervalSince(t0) + r2.timeIntervalSince(t3)) / 2
            if best == nil || rtt < best!.rtt { best = (rtt, off) }
        }
        if let best {
            offset = best.offset
            _ = try? await client.send("SyncPlay/Ping", body: ["Ping": Int(best.rtt * 1000)])
        }
    }

    private var serverNow: Date { Date().addingTimeInterval(offset) }

    // MARK: Server messages

    func handleGroupUpdate(_ u: [String: Any]) async {
        let type = u["Type"] as? String ?? ""
        let data = u["Data"]
        switch type {
        case "GroupJoined":
            let info = data as? [String: Any] ?? [:]
            groupId = (info["GroupId"] as? String) ?? (u["GroupId"] as? String)
            groupName = info["GroupName"] as? String
            participants = info["Participants"] as? [String] ?? []
            status = nil
        case "UserJoined":
            if let name = data as? String, !participants.contains(name) { participants.append(name) }
            status = "\(data as? String ?? "Someone") joined"
        case "UserLeft":
            if let name = data as? String { participants.removeAll { $0 == name } }
            status = "\(data as? String ?? "Someone") left"
        case "GroupLeft", "NotInGroup", "GroupDoesNotExist":
            reset()
        case "LibraryAccessDenied":
            status = "Someone in the group can't access this video."
        case "StateUpdate":
            let st = (data as? [String: Any])?["State"] as? String
            if st == "Waiting" { status = "Waiting for everyone…" } else if status == "Waiting for everyone…" { status = nil }
        case "PlayQueue":
            await handlePlayQueue(data as? [String: Any] ?? [:])
        default: break
        }
    }

    private func handlePlayQueue(_ q: [String: Any]) async {
        guard let client, let list = q["Playlist"] as? [[String: Any]], !list.isEmpty else { return }
        let index = min(max(0, q["PlayingItemIndex"] as? Int ?? 0), list.count - 1)
        guard let itemId = list[index]["ItemId"] as? String else { return }
        playlistItemId = list[index]["PlaylistItemId"] as? String
        let start = (q["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0

        if let model, normalized(model.item.id) == normalized(itemId) {
            model.syncPause()
            await model.syncSeek(ticks: start)
        } else if let model {
            guard let item = try? await client.item(itemId) else { return }
            await model.switchItem(item, startTicks: start)
            model.disableAutoNext()
            await model.waitUntilReady()
            model.syncPause()
        } else {
            // Not watching anything yet: open the player; it reports ready once it binds.
            guard let item = try? await client.item(itemId) else { return }
            currentItemId = itemId
            AppRouter.shared.playRequest = PlaybackRequest(item: item, startTicks: start)
            return
        }
        currentItemId = itemId
        await sendReady()
    }

    /// Called by a player opened for the group once it's showing the video.
    func playerOpened(_ model: PlayerModel) async {
        guard groupId != nil, normalized(model.item.id) == normalized(currentItemId ?? "") else { return }
        bind(model)
        await model.waitUntilReady()
        model.syncPause()
        await sendReady()
    }

    private func sendReady() async {
        guard let client, let model, let playlistItemId else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        _ = try? await client.send("SyncPlay/Ready", body: [
            "When": f.string(from: serverNow), "PositionTicks": model.positionTicks,
            "IsPlaying": false, "PlaylistItemId": playlistItemId,
        ])
    }

    func handleCommand(_ c: [String: Any]) {
        guard let model else { return }
        let command = c["Command"] as? String ?? ""
        let ticks = (c["PositionTicks"] as? NSNumber)?.int64Value
        let when = (c["When"] as? String).flatMap(parseJellyfinDate) ?? serverNow
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self else { return }
            switch command {
            case "Unpause":
                // Start exactly at the server's moment; if that's passed, jump ahead to catch up.
                let delay = when.timeIntervalSince(self.serverNow)
                if let ticks {
                    let behind = max(0, -delay)
                    await model.syncSeek(ticks: ticks + Int64(behind * 10_000_000))
                }
                let wait = when.timeIntervalSince(self.serverNow)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                model.syncPlay()
            case "Pause":
                model.syncPause()
                if let ticks { await model.syncSeek(ticks: ticks) }
            case "Seek":
                model.syncPause()
                if let ticks { await model.syncSeek(ticks: ticks) }
                await model.waitUntilReady()
                await self.sendReady()
            case "Stop":
                model.syncPause()
            default: break
            }
        }
    }

    private func normalized(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").lowercased() }
}

#if os(iOS)
/// The Watch Together sheet: start a group with this video, join someone's, or leave.
struct SyncPlaySheet: View {
    let model: PlayerModel?
    let client: JellyfinClient
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [SyncPlayManager.GroupInfo] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    private var sync: SyncPlayManager { SyncPlayManager.shared }

    var body: some View {
        NavigationStack {
            List {
                if sync.groupId != nil {
                    Section {
                        Label(sync.groupName ?? "Watch Together", systemImage: "person.2.wave.2.fill")
                            .font(.headline)
                        ForEach(sync.participants, id: \.self) { Label($0, systemImage: "person.fill") }
                        if let status = sync.status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                        Button("Leave group", role: .destructive) { Task { await sync.leave(); dismiss() } }
                    } header: { Text("You're watching together") } footer: {
                        Text("Play, pause and seeking are shared with everyone in the group.")
                    }
                } else {
                    if let model {
                        Section {
                            Button {
                                run { try await sync.create(client: client, model: model,
                                                            name: "\(app.session?.userName ?? "Huefin")'s room") }
                            } label: {
                                Label("Start a group with “\(model.item.displayTitle)”", systemImage: "plus.circle.fill")
                            }
                        } footer: {
                            Text("Others join from Huefin (More → Watch Together) or Jellyfin's web app (the SyncPlay button).")
                        }
                    }
                    Section("Join a group") {
                        if loading {
                            ProgressView()
                        } else if groups.isEmpty {
                            Text("No groups right now.").foregroundStyle(.secondary)
                        }
                        ForEach(groups) { g in
                            Button { run { try await sync.join(client: client, group: g, model: model) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name).font(.body.weight(.semibold))
                                    Text(g.participants.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("Watch Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await refresh() }
        }
        .presentationDetents([.medium, .large])
    }

    private func refresh() async {
        loading = true
        groups = await sync.listGroups(client: client)
        loading = false
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                self.error = (error as? JellyfinError)?.errorDescription == JellyfinError.http(403).errorDescription
                    ? "Your account isn't allowed to use SyncPlay. An admin can turn it on under Users → (you) → SyncPlay."
                    : error.localizedDescription
            }
            busy = false
        }
    }
}
#endif
