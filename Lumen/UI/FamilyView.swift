import SwiftUI

/// Family: see what everyone is watching, pause or stop it, and send a message to their screen.
/// Only admins and people an admin marked as "Parent" see this (the server enforces it too).
struct FamilyView: View {
    let client: JellyfinClient
    @State private var sessions: [AdminSession] = []
    @State private var loading = true
    @State private var error: String?
    @State private var messageTarget: AdminSession?
    @State private var customText = ""
    @State private var status: String?

    private let presets = ["Bedtime in 10 minutes 🌙", "Dinner's ready! 🍽️", "Last episode, then off 📺",
                           "Homework first ✏️", "Time to take a break 👋"]

    private var watching: [AdminSession] { sessions.filter { $0.nowPlayingItem != nil } }
    private var idle: [AdminSession] { sessions.filter { $0.nowPlayingItem == nil && $0.supportsRemoteControl == true } }

    var body: some View {
        List {
            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Watching now") {
                if loading && sessions.isEmpty {
                    ProgressView()
                } else if watching.isEmpty {
                    Text("Nobody is watching anything right now.").foregroundStyle(.secondary)
                }
                ForEach(watching) { s in row(s) }
            }
            if !idle.isEmpty {
                Section("Other devices") {
                    ForEach(idle) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.userName ?? "Someone").font(.body.weight(.semibold))
                                Text([s.deviceName, s.client].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { messageTarget = s } label: { Image(systemName: "bubble.left.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Family")
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(item: $messageTarget) { target in messageSheet(target) }
    }

    private func row(_ s: AdminSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RemoteImage(url: s.nowPlayingItem.map { client.posterURL(for: $0, width: 160) })
                    .frame(width: 52, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.userName ?? "Someone").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                    Text(s.nowPlayingItem?.displayTitle ?? "").font(.body.weight(.semibold)).lineLimit(1)
                    if let ep = s.nowPlayingItem?.episodeLabel { Text(ep).font(.caption).foregroundStyle(.secondary) }
                    Text([s.deviceName, s.client].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let pos = s.playState?.positionTicks, let total = s.nowPlayingItem?.runTimeTicks, total > 0 {
                        ProgressBar(value: Double(pos) / Double(total)).frame(maxWidth: 200)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { command(s, s.isPaused ? "Unpause" : "Pause") } label: {
                    Label(s.isPaused ? "Resume" : "Pause", systemImage: s.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) { command(s, "Stop") } label: { Label("Stop", systemImage: "stop.fill") }
                Button { messageTarget = s } label: { Label("Message", systemImage: "bubble.left.fill") }
            }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
            .disabled(s.supportsRemoteControl == false)
            if s.supportsRemoteControl == false {
                Text("This app doesn't accept remote control.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func messageSheet(_ target: AdminSession) -> some View {
        NavigationStack {
            List {
                Section("Quick messages") {
                    ForEach(presets, id: \.self) { p in
                        Button(p) { send(p, to: target) }
                    }
                }
                Section("Your own") {
                    TextField("Type a message", text: $customText, axis: .vertical)
                    Button("Send") { send(customText, to: target) }
                        .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Message \(target.userName ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { messageTarget = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            let all = try await client.controllableSessions()
            sessions = all.filter { $0.deviceId != JellyfinClient.deviceId }
            error = nil
        } catch {
            self.error = "Couldn't load devices: \(error.localizedDescription)"
        }
        loading = false
    }

    private func command(_ s: AdminSession, _ cmd: String) {
        Task {
            do {
                try await client.adminSessionCommand(s.id, cmd)
                status = "\(cmd == "Stop" ? "Stopped" : cmd == "Pause" ? "Paused" : "Resumed") on \(s.userName ?? "their") \(s.deviceName ?? "device")."
            } catch {
                status = "That device didn't respond."
            }
            await load()
        }
    }

    private func send(_ text: String, to s: AdminSession) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        messageTarget = nil
        customText = ""
        Task {
            do {
                try await client.adminSendMessage(s.id, header: "Message", text: t)
                status = "Sent to \(s.userName ?? "them")."
            } catch {
                status = "Couldn't send that message."
            }
        }
    }
}
