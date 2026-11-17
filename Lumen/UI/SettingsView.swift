import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    private struct BitrateOption: Hashable {
        let label: String
        let value: Int
    }

    private let bitrates: [BitrateOption] = [
        .init(label: "Maximum (200 Mbps)", value: 200_000_000),
        .init(label: "120 Mbps", value: 120_000_000),
        .init(label: "80 Mbps", value: 80_000_000),
        .init(label: "40 Mbps", value: 40_000_000),
        .init(label: "20 Mbps", value: 20_000_000),
        .init(label: "10 Mbps", value: 10_000_000),
        .init(label: "4 Mbps", value: 4_000_000),
    ]

    var body: some View {
        @Bindable var app = app
        Form {
            if let s = app.session {
                Section("Server") {
                    LabeledContent("Name", value: s.serverName ?? "Jellyfin")
                    LabeledContent("Address", value: s.serverURL)
                    LabeledContent("User", value: s.userName)
                }
            }

            Section {
                Picker("Max streaming quality", selection: $app.maxBitrate) {
                    ForEach(bitrates, id: \.self) { Text($0.label).tag($0.value) }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Keep this at Maximum for untouched Direct Play. Lower it only if remote playback stutters; the server will then re-encode, which loses Dolby Vision. Downloads always use full quality.")
            }

            Section("This device") {
                capability("Dolby Vision", DeviceCapabilities.dolbyVision)
                capability("HDR10", DeviceCapabilities.hdr10)
                capability("HLG", DeviceCapabilities.hlg)
                capability("HEVC hardware decode", DeviceCapabilities.hevc)
                capability("AV1 hardware decode", DeviceCapabilities.av1)
            }

            Section {
                Button("Sign Out", role: .destructive) { Task { await app.logout() } }
            } footer: {
                Text("Lumen \(JellyfinClient.version) · Downloads stay on this device after signing out.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .onChange(of: app.maxBitrate) { app.persistSettings() }
    }

    private func capability(_ name: String, _ supported: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(supported ? Theme.accent : .secondary)
        }
    }
}
