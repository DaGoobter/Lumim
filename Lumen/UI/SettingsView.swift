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

    @State private var djEngine: DJVoice.Engine = DJVoice.shared.engine
    @State private var kokoroURL = DJVoice.shared.kokoroURL
    @State private var kokoroVoice = DJVoice.shared.kokoroVoice
    @State private var kokoroRemoteURL = DJVoice.shared.kokoroRemoteURL
    @State private var kokoroSpeed = DJVoice.shared.kokoroSpeed
    @State private var openAIKey = DJVoice.shared.openAIKey
    @State private var openAIVoice = DJVoice.shared.openAIVoice
    @State private var elevenKey = DJVoice.shared.elevenKey
    @State private var elevenVoice = DJVoice.shared.elevenVoice
    @State private var testingVoice = false
    @State private var voiceTestResult: String?
    @State private var remoteField = ""
    @State private var localField = ""
    @State private var savingAddresses = false
    @State private var isAdmin = false

    var body: some View {
        @Bindable var app = app
        Form {
            if isAdmin, let client = app.client {
                Section {
                    NavigationLink { AdminDashboardView(client: client) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(LinearGradient(colors: [AdminPalette.violet, AdminPalette.pink],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Server Dashboard").font(.headline)
                                Text("Now playing, stats, libraries, users, logs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
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

            Section {
                Picker("Voice", selection: $djEngine) {
                    ForEach(DJVoice.Engine.allCases) { Text($0.label).tag($0) }
                }
                switch djEngine {
                case .kokoro:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kokoro address").font(.caption).foregroundStyle(.secondary)
                        TextField("192.168.1.20:8880", text: $kokoroURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Away-from-home address (optional)").font(.caption).foregroundStyle(.secondary)
                        TextField("https://yourdomain/kokoro", text: $kokoroRemoteURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Kokoro voice", selection: $kokoroVoice) {
                        ForEach([("af_heart", "Heart (warm, female)"),
                                 ("af_heart(2)+af_bella", "Heart + Bella (bright, female)"),
                                 ("af_bella", "Bella (energetic, female)"),
                                 ("af_nicole", "Nicole (soft, female)"),
                                 ("af_nova", "Nova (crisp, female)"),
                                 ("am_puck", "Puck (lively, male)"),
                                 ("am_michael", "Michael (smooth, male)"),
                                 ("am_michael+am_puck", "Michael + Puck (radio, male)"),
                                 ("am_fenrir", "Fenrir (deep, male)"),
                                 ("bm_george", "George (British, male)"),
                                 ("bf_emma", "Emma (British, female)")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Talking pace")
                            Spacer()
                            Text(String(format: "%.2f×", kokoroSpeed)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $kokoroSpeed, in: 0.9...1.3, step: 0.05)
                    }
                case .openAI:
                    SecureField("OpenAI API key", text: $openAIKey)
                    Picker("OpenAI voice", selection: $openAIVoice) {
                        ForEach(["coral", "sage", "ballad", "verse", "ash", "nova", "shimmer", "onyx", "alloy", "echo", "fable"],
                                id: \.self) { Text($0.capitalized).tag($0) }
                    }
                case .elevenLabs:
                    SecureField("ElevenLabs API key", text: $elevenKey)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice ID (from your ElevenLabs voice library)").font(.caption).foregroundStyle(.secondary)
                        TextField("21m00Tcm4TlvDq8Ikz7M", text: $elevenVoice)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                case .iPhone:
                    EmptyView()
                }
                Button {
                    saveVoice()
                    testingVoice = true
                    voiceTestResult = nil
                    Task {
                        await DJVoice.shared.say("Hey, hey! It's your Lumen DJ." + Stations.breath
                            + "So, here's how I sound." + Stations.beat + "Not bad, right? Okay, let's get you some music.")
                        voiceTestResult = DJVoice.shared.lastError.map { "Couldn't reach the voice: \($0)" }
                        testingVoice = false
                    }
                } label: {
                    HStack { Text("Test voice"); if testingVoice { Spacer(); ProgressView() } }
                }
                .disabled(testingVoice)
                if let voiceTestResult { Text(voiceTestResult).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("DJ Voice")
            } footer: {
                Text(voiceFooter)
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
        .task(id: app.session?.userName) {
            if let client = app.client { isAdmin = await client.adminIsAdministrator() } else { isAdmin = false }
        }
        .onChange(of: app.maxBitrate) { app.persistSettings() }
        .onChange(of: app.preferLocal) {
            app.persistSettings()
            app.scheduleRouteCheck()
        }
        .onChange(of: app.trackPrefs) { app.persistSettings() }
        .onChange(of: app.showBrightnessSlider) { app.persistSettings() }
        .onChange(of: app.showVolumeSlider) { app.persistSettings() }
        .onAppear {
            loadFields()
            if kokoroURL.isEmpty, let host = app.session?.localURL.flatMap({ URL(string: $0)?.host }) {
                kokoroURL = "\(host):8880"
            }
        }
        .onDisappear { saveVoice() }
        .onChange(of: djEngine) { saveVoice() }
    }

    private var voiceFooter: String {
        switch djEngine {
        case .kokoro:
            return "Free and private: a natural-sounding voice running on your own PC. Run the Kokoro installer on your PC once, then enter your PC's address above (port 8880). Try a few voices and paces; Michael + Puck or Heart + Bella sound most like radio. "
        case .openAI:
            return "Very human voices that act like a radio DJ. Uses your OpenAI API key; DJ intros cost roughly a cent per few minutes of talking."
        case .elevenLabs:
            return "The most lifelike voices. ElevenLabs has a free monthly allowance that easily covers DJ intros."
        case .iPhone:
            return "Uses the iPhone's built-in speech. For a better iPhone voice, download an Enhanced or Premium English voice in Settings → Accessibility → Spoken Content → Voices."
        }
    }

    private func saveVoice() {
        let v = DJVoice.shared
        if v.engine != djEngine { v.engine = djEngine }
        if v.kokoroURL != kokoroURL { v.kokoroURL = kokoroURL }
        if v.kokoroVoice != kokoroVoice { v.kokoroVoice = kokoroVoice }
        if v.kokoroRemoteURL != kokoroRemoteURL { v.kokoroRemoteURL = kokoroRemoteURL }
        if v.kokoroSpeed != kokoroSpeed { v.kokoroSpeed = kokoroSpeed }
        if v.openAIKey != openAIKey { v.openAIKey = openAIKey }
        if v.openAIVoice != openAIVoice { v.openAIVoice = openAIVoice }
        if v.elevenKey != elevenKey { v.elevenKey = elevenKey }
        if v.elevenVoice != elevenVoice { v.elevenVoice = elevenVoice }
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
