import SwiftUI
import WebKit

// MARK: - Session detail

struct SessionDetailView: View {
    let session: AdminSession
    let client: JellyfinClient
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showMessage = false
    @State private var message = ""
    @State private var status: String?

    var body: some View {
        let item = session.nowPlayingItem
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { RemoteImage(url: client.backdropURL(for: item, width: 1000)) }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle).font(.title2.weight(.bold))
                        if let sub = item.episodeLabel ?? item.artistLine {
                            Text(sub).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let p = session.progress {
                        ProgressView(value: p).tint(AdminPalette.color(for: session.method))
                    }
                }

                HStack(spacing: 10) {
                    Button { command(session.isPaused ? "Unpause" : "Pause") } label: {
                        Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(PowerButtonStyle(color: AdminPalette.violet))
                    Button { command("Stop") } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(PowerButtonStyle(color: AdminPalette.red))
                    Button { showMessage = true } label: { Label("Message", systemImage: "text.bubble.fill") }
                        .buttonStyle(PowerButtonStyle(color: AdminPalette.cyan))
                }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }

                AdminCard(title: "Who", systemImage: "person.fill", tint: AdminPalette.pink) {
                    InfoRow("User", session.userName)
                    InfoRow("Device", session.deviceName)
                    InfoRow("App", [session.client, session.applicationVersion].compactMap { $0 }.joined(separator: " "))
                    InfoRow("Network", (session.isLocal ? "Home · " : "Remote · ") + (session.remoteEndPoint ?? ""))
                }

                AdminCard(title: "Stream", systemImage: "waveform", tint: AdminPalette.color(for: session.method)) {
                    HStack {
                        Pill(text: AdminPalette.label(for: session.method), color: AdminPalette.color(for: session.method))
                        Spacer()
                    }
                    Text(explanation).font(.footnote).foregroundStyle(.secondary)
                    if let src = item?.mediaSources?.first {
                        let v = src.mediaStreams?.first { $0.type == "Video" }
                        InfoRow("Original", [src.container?.uppercased(), v?.codec?.uppercased(),
                                             v.flatMap { $0.height }.map { "\($0)p" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let t = session.transcodingInfo {
                        InfoRow("Sending", [t.container?.uppercased(), t.videoCodec?.uppercased(), t.audioCodec?.uppercased(),
                                            t.height.map { "\($0)p" }].compactMap { $0 }.joined(separator: " · "))
                        if let b = t.bitrate { InfoRow("Bitrate", String(format: "%.1f Mbps", Double(b) / 1_000_000)) }
                        if let fps = t.framerate, fps > 0 { InfoRow("Encoding speed", String(format: "%.0f fps", fps)) }
                        if let hw = t.hardwareAccelerationType, !hw.isEmpty { InfoRow("Hardware", hw.uppercased()) }
                        if let reasons = t.transcodeReasons, !reasons.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Why it's converting").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(reasons, id: \.self) { r in
                                    Label(Self.reason(r), systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote).foregroundStyle(AdminPalette.orange)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .alert("Send a message", isPresented: $showMessage) {
            TextField("Message", text: $message)
            Button("Send") {
                let text = message
                message = ""
                Task {
                    do { try await client.adminSendMessage(session.id, header: "Message from the server", text: text); status = "Message sent." }
                    catch { status = "Couldn't send: \(error.localizedDescription)" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It pops up on \(session.deviceName ?? "their screen").") }
    }

    private var explanation: String {
        switch session.method {
        case .direct: return "Playing the original file untouched. Best quality, no work for your PC."
        case .remux: return "Original video and audio, repackaged on the fly. Full quality, very light on your PC."
        case .audioOnly: return "Original video; only the audio is being converted. Picture quality is untouched."
        case .transcode: return "Your PC is re-encoding the video for this device. Quality is reduced and it uses CPU/GPU."
        }
    }

    private func command(_ c: String) {
        Task {
            do {
                try await client.adminSessionCommand(session.id, c)
                status = c == "Stop" ? "Stopped." : "Sent."
                onChange()
                if c == "Stop" { dismiss() }
            } catch { status = error.localizedDescription }
        }
    }

    static func reason(_ r: String) -> String {
        let known: [String: String] = [
            "ContainerNotSupported": "The device can't open this file type",
            "VideoCodecNotSupported": "The device can't decode this video format",
            "AudioCodecNotSupported": "The device can't play this audio format",
            "SubtitleCodecNotSupported": "Subtitles have to be burned into the picture",
            "VideoRangeTypeNotSupported": "The screen can't show this HDR type",
            "VideoResolutionNotSupported": "The resolution is too high for the device",
            "ContainerBitrateExceedsLimit": "The file is above the quality limit set for streaming",
            "VideoBitrateNotSupported": "The video bitrate is above the device's limit",
            "AudioChannelsNotSupported": "Too many audio channels for the device",
            "VideoLevelNotSupported": "The video's encoding level is too high for the device",
            "VideoProfileNotSupported": "The video's encoding profile isn't supported",
            "AudioBitrateNotSupported": "The audio bitrate is above the device's limit",
            "DirectPlayError": "Direct play failed, so the server fell back to converting",
            "VideoBitDepthNotSupported": "The device can't decode 10-bit video",
        ]
        if let k = known[r] { return k }
        return r.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

struct InfoRow: View {
    let label: String
    let value: String?
    init(_ label: String, _ value: String?) { self.label = label; self.value = value }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Libraries

struct LibrariesAdminView: View {
    let client: JellyfinClient
    @State private var libraries: [VirtualFolder] = []
    @State private var status: String?
    @State private var confirmReplace: VirtualFolder?

    var body: some View {
        List {
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            Section {
                Button { run("Scanning all libraries") { try await client.adminScanAll() } } label: {
                    Label("Scan all libraries for new files", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ForEach(libraries) { lib in
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: icon(lib.collectionType))
                            .font(.title3.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color(lib.collectionType).gradient))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lib.name ?? "Library").font(.headline)
                            ForEach(lib.locations ?? [], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    if let p = lib.refreshProgress, lib.refreshStatus == "Active" {
                        ProgressView(value: p / 100) { Text("Scanning… \(Int(p))%").font(.caption) }.tint(color(lib.collectionType))
                    }
                    if let id = lib.itemId {
                        Button { run("Scanning \(lib.name ?? "library")") { try await client.adminRefresh(itemId: id, replaceAll: false) } } label: {
                            Label("Scan for new and changed files", systemImage: "magnifyingglass")
                        }
                        Button(role: .destructive) { confirmReplace = lib } label: {
                            Label("Replace all metadata and artwork", systemImage: "wand.and.stars")
                        }
                    }
                }
            }
        }
        .navigationTitle("Libraries")
        .task { await load(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); await load() } }
        .refreshable { await load() }
        .confirmationDialog("Replace everything for \(confirmReplace?.name ?? "this library")?",
                            isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
                            titleVisibility: .visible) {
            Button("Replace all metadata", role: .destructive) {
                if let id = confirmReplace?.itemId {
                    run("Refreshing all metadata") { try await client.adminRefresh(itemId: id, replaceAll: true) }
                }
            }
        } message: { Text("Re-downloads titles, descriptions and artwork for every item. This can take a long time on big libraries.") }
    }

    private func load() async { if let l = try? await client.adminLibraries() { libraries = l } }

    private func run(_ label: String, _ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); status = "\(label)…" } catch { status = error.localizedDescription }
            await load()
        }
    }

    private func icon(_ type: String?) -> String {
        switch type {
        case "movies": return "film.fill"
        case "tvshows": return "tv.fill"
        case "music": return "music.note"
        case "books": return "book.fill"
        case "musicvideos": return "music.note.tv"
        case "homevideos": return "video.fill"
        case "livetv": return "antenna.radiowaves.left.and.right"
        case "boxsets": return "square.stack.3d.up.fill"
        default: return "folder.fill"
        }
    }

    private func color(_ type: String?) -> Color {
        switch type {
        case "movies": return AdminPalette.violet
        case "tvshows": return AdminPalette.pink
        case "music": return AdminPalette.green
        case "books": return AdminPalette.yellow
        case "homevideos": return AdminPalette.orange
        default: return AdminPalette.blue
        }
    }
}

// MARK: - Users

struct UsersAdminView: View {
    let client: JellyfinClient
    @State private var users: [AdminUser] = []

    var body: some View {
        List(users) { u in
            NavigationLink { UserAdminDetailView(client: client, user: u) { Task { await load() } } } label: {
                HStack(spacing: 12) {
                    UserAvatar(client: client, user: u, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(u.name ?? "User").font(.headline)
                            if u.policy?.isAdministrator == true { Pill(text: "Admin", color: AdminPalette.violet) }
                            if u.policy?.isDisabled == true { Pill(text: "Disabled", color: AdminPalette.red) }
                        }
                        Text(u.lastActive.map { "Active \($0.relative)" } ?? "Never signed in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Users")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let u = try? await client.adminUsers() {
            users = u.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
    }
}

struct UserAvatar: View {
    let client: JellyfinClient
    let user: AdminUser
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [AdminPalette.violet, AdminPalette.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String((user.name ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            if let tag = user.primaryImageTag {
                RemoteImage(url: client.url("Users/\(user.id)/Images/Primary", query: ["tag": tag, "maxWidth": "200"]))
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

struct UserAdminDetailView: View {
    let client: JellyfinClient
    let user: AdminUser
    var onChange: () -> Void

    @State private var disabled = false
    @State private var remote = true
    @State private var downloads = true
    @State private var transcoding = true
    @State private var liveTV = true
    @State private var parent = false
    @State private var remoteLimit = 0
    @State private var ready = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    UserAvatar(client: client, user: user, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name ?? "User").font(.title2.weight(.bold))
                        if let d = user.lastActive { Text("Last active \(d.relative)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                Toggle("Allow sign-in", isOn: Binding(get: { !disabled }, set: { disabled = !$0 }))
                Toggle("Allow access away from home", isOn: $remote)
                Toggle("Allow downloads", isOn: $downloads)
                Toggle("Allow video transcoding", isOn: $transcoding)
                Toggle("Allow Live TV", isOn: $liveTV)
            } footer: {
                Text("Turning off transcoding means this person only gets files their device can play as-is. Changes apply right away.")
            }
            Section {
                Toggle("Parent", isOn: $parent)
            } footer: {
                Text("Parents get Family in Prism: they can see what everyone is watching, pause or stop it, and send a message to their screen (\"Bedtime in 10 minutes\"). Admins always have it.")
            }
            Section {
                Picker("Away-from-home quality", selection: $remoteLimit) {
                    Text("No limit").tag(0)
                    ForEach([40, 20, 15, 12, 10, 8, 6, 4, 3, 2], id: \.self) { Text("\($0) Mbps").tag($0 * 1_000_000) }
                }
            } footer: {
                Text("The most this person can stream when they're not on your home Wi-Fi. Anything bigger is shrunk to fit. 8 Mbps looks great on a 1080p TV; 4K originals run 25–80 Mbps, so a lower cap stops buffering on slower connections and saves your upload.")
            }
            PrismDefaultsSection(client: client, userId: user.id)
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle(user.name ?? "User")
        .onAppear {
            let p = user.policy
            disabled = p?.isDisabled ?? false
            remote = p?.enableRemoteAccess ?? true
            downloads = p?.enableContentDownloading ?? true
            transcoding = p?.enableVideoPlaybackTranscoding ?? true
            liveTV = p?.enableLiveTvAccess ?? true
            parent = p?.enableRemoteControlOfOtherUsers ?? false
            remoteLimit = p?.remoteClientBitrateLimit ?? 0
            DispatchQueue.main.async { ready = true }
        }
        .onChange(of: disabled) { _, v in save(["IsDisabled": v]) }
        .onChange(of: remote) { _, v in save(["EnableRemoteAccess": v]) }
        .onChange(of: downloads) { _, v in save(["EnableContentDownloading": v]) }
        .onChange(of: transcoding) { _, v in save(["EnableVideoPlaybackTranscoding": v]) }
        .onChange(of: liveTV) { _, v in save(["EnableLiveTvAccess": v]) }
        .onChange(of: parent) { _, v in save(["EnableRemoteControlOfOtherUsers": v]) }
        .onChange(of: remoteLimit) { _, v in save(["RemoteClientBitrateLimit": v]) }
    }

    private func save(_ changes: [String: Any]) {
        guard ready else { return }
        Task {
            do { try await client.adminUpdatePolicy(userId: user.id, changes: changes); status = "Saved."; onChange() }
            catch { status = "Couldn't save: \(error.localizedDescription)" }
        }
    }
}

// MARK: - Scheduled tasks

struct TasksAdminView: View {
    let client: JellyfinClient
    @State private var tasks: [ScheduledTask] = []

    private var groups: [(String, [ScheduledTask])] {
        Dictionary(grouping: tasks) { $0.category ?? "Other" }
            .map { ($0.key, $0.value.sorted { ($0.name ?? "") < ($1.name ?? "") }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { t in TaskRow(task: t, client: client) { Task { await load() } } }
                }
            }
        }
        .navigationTitle("Scheduled Tasks")
        .task { await load(); while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); await load() } }
        .refreshable { await load() }
    }

    private func load() async { if let t = try? await client.adminTasks() { tasks = t } }
}

private struct TaskRow: View {
    let task: ScheduledTask
    let client: JellyfinClient
    var changed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name ?? "Task").font(.subheadline.weight(.semibold))
                    if task.isRunning {
                        Text("Running").font(.caption).foregroundStyle(AdminPalette.cyan)
                    } else if let r = task.lastExecutionResult {
                        HStack(spacing: 4) {
                            Circle().fill(r.status == "Completed" ? AdminPalette.green : r.status == "Failed" ? AdminPalette.red : AdminPalette.yellow)
                                .frame(width: 6, height: 6)
                            Text([r.status, r.ended?.relative].compactMap { $0 }.joined(separator: " · "))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Never run").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task {
                        if task.isRunning { try? await client.adminStopTask(task.id) } else { try? await client.adminStartTask(task.id) }
                        changed()
                    }
                } label: {
                    Image(systemName: task.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(task.isRunning ? AdminPalette.red : AdminPalette.violet)
                }
                .buttonStyle(.plain)
            }
            if task.isRunning {
                ProgressView(value: (task.currentProgressPercentage ?? 0) / 100).tint(AdminPalette.cyan)
            }
            if let err = task.lastExecutionResult?.errorMessage, !err.isEmpty, !task.isRunning {
                Text(err).font(.caption2).foregroundStyle(AdminPalette.red).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Activity

struct ActivityAdminView: View {
    let client: JellyfinClient
    @State private var entries: [ActivityEntry] = []
    @State private var total = 0
    @State private var loading = false

    var body: some View {
        List {
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 12) {
                    let style = Self.style(for: e)
                    Image(systemName: style.0)
                        .font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(style.1.gradient))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name ?? "").font(.subheadline).lineLimit(3)
                        if let s = e.shortOverview, !s.isEmpty {
                            Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let d = e.when { Text(d.relative).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .onAppear { if e.id == entries.last?.id { Task { await more() } } }
            }
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .navigationTitle("Activity")
        .task { if entries.isEmpty { await more() } }
        .refreshable { entries = []; total = 0; await more() }
    }

    private func more() async {
        guard !loading, entries.isEmpty || entries.count < total else { return }
        loading = true
        defer { loading = false }
        if let page = try? await client.adminActivity(start: entries.count) {
            entries += page.items
            total = page.totalRecordCount ?? entries.count
        }
    }

    static func style(for e: ActivityEntry) -> (String, Color) {
        let t = e.type ?? ""
        if e.severity == "Error" || t.contains("Failed") || t.contains("Fail") { return ("exclamationmark.triangle.fill", AdminPalette.red) }
        if e.severity == "Warning" || e.severity == "Warn" { return ("exclamationmark.circle.fill", AdminPalette.orange) }
        switch t {
        case let x where x.contains("Playback"): return ("play.fill", AdminPalette.pink)
        case let x where x.contains("Authentication") || x.contains("Session"): return ("person.fill.checkmark", AdminPalette.green)
        case let x where x.contains("User"): return ("person.fill", AdminPalette.violet)
        case let x where x.contains("Plugin") || x.contains("Package"): return ("puzzlepiece.extension.fill", AdminPalette.yellow)
        case let x where x.contains("Task"): return ("gearshape.fill", AdminPalette.cyan)
        case let x where x.contains("Subtitle"): return ("captions.bubble.fill", AdminPalette.blue)
        default: return ("bell.fill", AdminPalette.blue)
        }
    }
}

// MARK: - Logs

struct LogsAdminView: View {
    let client: JellyfinClient
    @State private var files: [LogFile] = []

    var body: some View {
        List(files) { f in
            NavigationLink { LogViewer(client: client, file: f) } label: {
                HStack(spacing: 12) {
                    Image(systemName: f.name.hasPrefix("FFmpeg") ? "film.stack" : "doc.text.fill")
                        .foregroundStyle(f.name.hasPrefix("FFmpeg") ? AdminPalette.orange : AdminPalette.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(f.name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([f.modified?.relative, f.size?.bytes].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let f = try? await client.adminLogs() {
            files = f.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    /// "FFmpeg.Transcode-2026-11-17_21-36-38_…log" → "Transcode · 2026-11-17 21:36"
    static func title(_ name: String) -> String {
        if name.hasPrefix("FFmpeg."), let r = name.range(of: #"FFmpeg\.(\w+)-(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})"#, options: .regularExpression) {
            let parts = name[r].split(whereSeparator: { "-_.".contains($0) })
            if parts.count >= 7 { return "\(parts[1]) · \(parts[2])-\(parts[3])-\(parts[4]) \(parts[5]):\(parts[6])" }
        }
        return name
    }
}

struct LogViewer: View {
    let client: JellyfinClient
    let file: LogFile

    enum Level: String, CaseIterable { case all = "All", warnings = "Warnings", errors = "Errors" }

    @State private var lines: [String] = []
    @State private var raw = ""
    @State private var level: Level = .all
    @State private var search = ""
    @State private var loading = true

    private var shown: [(Int, String)] {
        lines.enumerated().filter { pair in
            let l = pair.element
            switch level {
            case .all: break
            case .warnings: if !(l.contains("[WRN]") || l.contains("[ERR]") || l.contains("[FTL]")) { return false }
            case .errors: if !(l.contains("[ERR]") || l.contains("[FTL]")) { return false }
            }
            return search.isEmpty || l.localizedCaseInsensitiveContains(search)
        }
        .map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Level", selection: $level) {
                ForEach(Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.bottom, 8)

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(shown, id: \.0) { entry in
                                Text(entry.1)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(entry.1))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.0)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .onAppear { if let last = shown.last { proxy.scrollTo(last.0, anchor: .bottom) } }
                }
            }
        }
        .navigationTitle(LogsAdminView.title(file.name))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search this log")
        .toolbar {
            ShareLink(item: raw, preview: SharePreview(file.name)) { Image(systemName: "square.and.arrow.up") }
        }
        .task {
            let text = (try? await client.adminLog(file.name)) ?? "Couldn't load this log."
            raw = text
            // Keep the most recent part; old lines are rarely what you're looking for.
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(4000).map(String.init))
            loading = false
        }
    }

    private func color(_ line: String) -> Color {
        if line.contains("[ERR]") || line.contains("[FTL]") { return AdminPalette.red }
        if line.contains("[WRN]") { return AdminPalette.yellow }
        return .primary.opacity(0.85)
    }
}

// MARK: - Devices

struct DevicesAdminView: View {
    let client: JellyfinClient
    @State private var devices: [DeviceEntry] = []
    @State private var sessions: [AdminSession] = []

    var body: some View {
        List {
            ForEach(devices) { d in
                HStack(spacing: 12) {
                    Image(systemName: icon(d))
                        .font(.headline).foregroundStyle(AdminPalette.blue)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(d.customName ?? d.name ?? "Device").font(.subheadline.weight(.semibold))
                            if sessions.contains(where: { $0.deviceId == d.id && $0.nowPlayingItem != nil }) {
                                Pill(text: "Playing", color: AdminPalette.pink)
                            }
                            if d.id == JellyfinClient.deviceId { Pill(text: "This device", color: AdminPalette.violet) }
                        }
                        Text([d.appName, d.appVersion].compactMap { $0 }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text([d.lastUserName, d.lastActive?.relative].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    if d.id != JellyfinClient.deviceId {
                        Button("Sign out", role: .destructive) {
                            Task { try? await client.adminDeleteDevice(d.id); await load() }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let d = try? await client.adminDevices() {
            devices = d.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
        sessions = (try? await client.adminSessions()) ?? []
    }

    private func icon(_ d: DeviceEntry) -> String {
        let s = "\(d.name ?? "") \(d.appName ?? "")".lowercased()
        if s.contains("roku") || s.contains("tv") || s.contains("android tv") { return "tv" }
        if s.contains("ipad") { return "ipad" }
        if s.contains("iphone") || s.contains("ios") || s.contains("android") { return "iphone" }
        if s.contains("web") || s.contains("chrome") || s.contains("firefox") || s.contains("edge") { return "globe" }
        return "desktopcomputer"
    }
}

// MARK: - Plugins

struct PluginsAdminView: View {
    let client: JellyfinClient
    @State private var plugins: [PluginInfo] = []

    var body: some View {
        List(plugins) { p in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.name ?? "Plugin").font(.subheadline.weight(.semibold))
                    Spacer()
                    Pill(text: p.status ?? "", color: p.status == "Active" ? AdminPalette.green
                         : p.status == "Restart" ? AdminPalette.orange : AdminPalette.red)
                }
                if let v = p.version { Text("Version \(v)").font(.caption).foregroundStyle(.secondary) }
                if let d = p.description, !d.isEmpty { Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
        }
        .navigationTitle("Plugins")
        .task { plugins = ((try? await client.adminPlugins()) ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") } }
    }
}

// MARK: - Quick Connect

struct QuickConnectAdminView: View {
    let client: JellyfinClient
    @State private var code = ""
    @State private var status: (String, Bool)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [AdminPalette.teal, AdminPalette.blue], startPoint: .top, endPoint: .bottom))
                .padding(.top, 30)
            Text("Approve a sign-in").font(.title2.weight(.bold))
            Text("On the TV or other device, choose Quick Connect. Type the code it shows here to sign it in as you.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focused)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08)))
                .padding(.horizontal, 40)
            Button {
                Task {
                    do { try await client.adminAuthorizeQuickConnect(code: code.trimmingCharacters(in: .whitespaces)); status = ("Approved! The device is signing in.", true); code = "" }
                    catch { status = ("That code didn't work. Check it and try again, or make sure Quick Connect is turned on in the server's settings.", false) }
                }
            } label: { Label("Approve", systemImage: "checkmark.seal.fill") }
            .buttonStyle(PowerButtonStyle(color: AdminPalette.teal))
            .padding(.horizontal, 40)
            .disabled(code.count < 6)
            if let status {
                Text(status.0).font(.footnote).foregroundStyle(status.1 ? AdminPalette.green : AdminPalette.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer()
        }
        .navigationTitle("Quick Connect")
        .onAppear { focused = true }
    }
}

// MARK: - Jellyfin's own dashboard

struct WebDashboardView: View {
    let client: JellyfinClient
    var body: some View {
        JellyfinWebView(client: client)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Full Dashboard")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Jellyfin's web dashboard, already signed in with this app's account.
struct JellyfinWebView: UIViewRepresentable {
    let client: JellyfinClient

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let base = client.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let creds: [String: Any] = [
            "Servers": [[
                "ManualAddress": base,
                "manualAddressOnly": true,
                "AccessToken": client.accessToken ?? "",
                "UserId": client.userId ?? "",
                "DateLastAccessed": Int(Date().timeIntervalSince1970 * 1000),
                "LastConnectionMode": 2,
            ] as [String: Any]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: creds),
           let json = String(data: data, encoding: .utf8) {
            let js = "try { localStorage.setItem('jellyfin_credentials', \(Self.quoted(json))); } catch (e) {}"
            config.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.allowsBackForwardNavigationGestures = true
        if let url = URL(string: base + "/web/#/dashboard") { view.load(URLRequest(url: url)) }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
