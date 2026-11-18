import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio

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

    @State private var remoteField = ""
    @State private var localField = ""
    @State private var savingAddresses = false

    var body: some View {
        @Bindable var app = app
        Form {
            if let s = app.session {
                Section("Server") {
                    LabeledContent("Name", value: s.serverName ?? "Jellyfin")
                    LabeledContent("User", value: s.userName)
                    LabeledContent("Connected via") {
                        Label(app.route == .local ? "Home network" : "Remote",
                              systemImage: app.route == .local ? "house.fill" : "globe")
                            .foregroundStyle(app.route == .local ? Theme.accent : .secondary)
                    }
                    if app.route == .remote, app.preferLocal {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Home address check").font(.caption).foregroundStyle(.secondary)
                            Text(app.localStatus).font(.footnote)
                        }
                    }
                    Button("Check connection now") { Task { await app.recheckConnection() } }
                }

                Section {
                    Toggle("Use home network when available", isOn: $app.preferLocal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote address").font(.caption).foregroundStyle(.secondary)
                        TextField("https://example.duckdns.org", text: $remoteField)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Home network address").font(.caption).foregroundStyle(.secondary)
                        TextField(app.session?.localURL.map { "Auto: \($0)" } ?? "Auto-detect (e.g. 192.168.1.20:8096)",
                                  text: $localField)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button {
                        savingAddresses = true
                        Task {
                            await app.updateAddresses(remote: remoteField, local: localField)
                            loadFields()
                            savingAddresses = false
                        }
                    } label: {
                        HStack {
                            Text("Save & reconnect")
                            if savingAddresses { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(savingAddresses || remoteField.isEmpty)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("At home Lumen talks to your server directly over Wi‑Fi (faster, full quality, no internet needed); everywhere else it uses your remote address. It switches automatically. Leave the home address empty to auto-detect it.")
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

            Section {
                Picker("Audio language", selection: $app.trackPrefs.audioLanguage) {
                    Text("File default").tag("")
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Subtitles", selection: $app.trackPrefs.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Subtitle language", selection: $app.trackPrefs.subtitleLanguage) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text("Audio & Subtitles")
            } footer: {
                Text("Applied automatically when something starts playing; change tracks anytime with the captions button in the player. Picture-based subtitles (PGS, VobSub) are only used when you pick them yourself, because they force the server to re-encode the video and Dolby Vision is lost. To search OpenSubtitles from the player, install the Open Subtitles plugin on your Jellyfin server (Dashboard → Plugins → Catalog) and sign in with your opensubtitles.com account.")
            }

            Section {
                Toggle("Brightness slider (left side)", isOn: $app.showBrightnessSlider)
                Toggle("Volume slider (right side)", isOn: $app.showVolumeSlider)
                Toggle("DJ voice between music sets", isOn: Binding(get: { audio.djVoiceEnabled },
                                                                    set: { audio.setDJVoice($0) }))
            } header: {
                Text("Player")
            } footer: {
                Text("Pinch the video to zoom, or double-tap to switch between Fit and Fill.")
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
                Text("Lumen \(JellyfinClient.version) (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")) · Downloads stay on this device after signing out.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Settings")
        .onChange(of: app.maxBitrate) { app.persistSettings() }
        .onChange(of: app.preferLocal) {
            app.persistSettings()
            app.scheduleRouteCheck()
        }
        .onChange(of: app.trackPrefs) { app.persistSettings() }
        .onChange(of: app.showBrightnessSlider) { app.persistSettings() }
        .onChange(of: app.showVolumeSlider) { app.persistSettings() }
        .onAppear { loadFields() }
    }

    private func loadFields() {
        remoteField = app.session?.serverURL ?? ""
        localField = app.session?.localURLIsManual == true ? (app.session?.localURL ?? "") : ""
    }

    private func capability(_ name: String, _ supported: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(supported ? Theme.accent : .secondary)
        }
    }
}
