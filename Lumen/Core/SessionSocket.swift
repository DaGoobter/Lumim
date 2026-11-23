import SwiftUI
import Observation

/// Prism's live line to the server. It lets a parent (or admin) pause, stop or message this device,
/// and carries Watch Together (SyncPlay) updates.
@MainActor @Observable
final class SessionSocket {
    static let shared = SessionSocket()

    /// A message someone sent to this device ("Bedtime in 10 minutes").
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let header: String
        let text: String
    }
    var notice: Notice?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    private init() {}

    var isConnected: Bool { socket != nil }

    func connect(_ client: JellyfinClient) async {
        if socket != nil, self.client === client { return }
        disconnect()
        self.client = client
        // Tell the server this device can be controlled and can show messages.
        _ = try? await client.send("Sessions/Capabilities/Full", body: [
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportsMediaControl": true,
            "SupportedCommands": ["DisplayMessage", "Play", "Pause", "Seek", "Stop", "PlayPause", "SetVolume"],
        ])
        guard var comps = URLComponents(url: client.baseURL.appendingPathComponent("socket"), resolvingAgainstBaseURL: false)
        else { return }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "api_key", value: client.accessToken),
                            URLQueryItem(name: "deviceId", value: JellyfinClient.deviceId)]
        guard let url = comps.url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.socket === task else { return }
                try? await task.send(.string(#"{"MessageType":"KeepAlive"}"#))
            }
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        keepAlive?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await task.receive() else {
                // Dropped (network change, server restart): try again shortly.
                guard socket === task else { return }
                socket = nil
                SyncPlayManager.shared.connectionLost()
                if let client {
                    reconnectTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        await self?.connect(client)
                    }
                }
                return
            }
            let data: Data?
            switch message {
            case .string(let s): data = s.data(using: .utf8)
            case .data(let d): data = d
            @unknown default: data = nil
            }
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["MessageType"] as? String else { continue }
            let payload = obj["Data"]
            switch type {
            case "SyncPlayGroupUpdate":
                await SyncPlayManager.shared.handleGroupUpdate(payload as? [String: Any] ?? [:])
            case "SyncPlayCommand":
                SyncPlayManager.shared.handleCommand(payload as? [String: Any] ?? [:])
            case "Playstate":
                handlePlaystate(payload as? [String: Any] ?? [:])
            case "GeneralCommand":
                handleGeneral(payload as? [String: Any] ?? [:])
            default:
                break
            }
        }
    }

    private func handlePlaystate(_ d: [String: Any]) {
        let command = d["Command"] as? String ?? ""
        let ticks = (d["SeekPositionTicks"] as? NSNumber)?.int64Value
        if let player = PlayerModel.active {
            switch command {
            case "Pause": player.syncPause()
            case "Unpause": player.syncPlay()
            case "PlayPause": player.isPlaying ? player.syncPause() : player.syncPlay()
            case "Stop": player.syncPause(); PlayerModel.requestClose()
            case "Seek": if let ticks { Task { await player.syncSeek(ticks: ticks) } }
            default: break
            }
        } else {
            let audio = AudioPlayer.shared
            switch command {
            case "Pause": audio.pause()
            case "Unpause", "PlayPause": audio.togglePlay()
            case "Stop": audio.stop()
            case "NextTrack": audio.next()
            case "PreviousTrack": audio.previous()
            case "Seek": if let ticks { audio.seek(to: Double(ticks) / 10_000_000) }
            default: break
            }
        }
    }

    private func handleGeneral(_ d: [String: Any]) {
        guard (d["Name"] as? String) == "DisplayMessage" else { return }
        let args = d["Arguments"] as? [String: Any] ?? [:]
        let text = args["Text"] as? String ?? ""
        guard !text.isEmpty else { return }
        notice = Notice(header: args["Header"] as? String ?? "Message", text: text)
    }
}

/// Banner for messages sent to this device.
struct NoticeBanner: View {
    let notice: SessionSocket.Notice
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.title3).foregroundStyle(Theme.spectrum)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.header).font(.subheadline.weight(.bold))
                Text(notice.text).font(.subheadline)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .padding(.horizontal, 16)
    }
}
