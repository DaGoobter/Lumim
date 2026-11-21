import SwiftUI
import Charts

// MARK: - Look

enum AdminPalette {
    static let violet = Theme.violet
    static let blue = Theme.blue
    static let cyan = Color(red: 0.25, green: 0.85, blue: 0.95)
    static let teal = Color(red: 0.2, green: 0.85, blue: 0.7)
    static let green = Theme.green
    static let yellow = Theme.yellow
    static let orange = Theme.orange
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.62)
    static let red = Theme.red

    static func color(for method: AdminSession.Method) -> Color {
        switch method {
        case .direct: return green
        case .remux: return cyan
        case .audioOnly: return yellow
        case .transcode: return orange
        }
    }

    static func label(for method: AdminSession.Method) -> String {
        switch method {
        case .direct: return "Direct Play"
        case .remux: return "Direct Stream"
        case .audioOnly: return "Audio converting"
        case .transcode: return "Transcoding"
        }
    }

    static func methodColor(_ label: String) -> Color {
        switch label {
        case "Direct Play": return green
        case "Direct Stream": return blue
        case "Remux": return cyan
        default: return orange
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// A rounded, softly lit panel used throughout the dashboard.
struct AdminCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color = AdminPalette.violet
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.subheadline.weight(.bold)).foregroundStyle(tint)
                    }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .center))
                )
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
        )
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.18)))
    }
}

// MARK: - Model

@MainActor @Observable
final class AdminModel {
    let client: JellyfinClient
    var info: AdminSystemInfo?
    var storage: SystemStorage?
    var counts: ItemCounts?
    var sessions: [AdminSession] = []
    var tasks: [ScheduledTask] = []
    var stats: WatchStats?
    var statsUnavailable = false
    var error: String?
    var loaded = false

    init(client: JellyfinClient) { self.client = client }

    var playing: [AdminSession] { sessions.filter { $0.nowPlayingItem != nil } }
    var runningTasks: [ScheduledTask] { tasks.filter(\.isRunning) }

    func loadAll() async {
        async let i = try? client.adminSystemInfo()
        async let s = try? client.adminStorage()
        async let c = try? client.adminCounts()
        async let st = client.adminWatchStats()
        let (info, storage, counts, stats) = await (i, s, c, st)
        self.info = info
        self.storage = storage
        self.counts = counts
        self.stats = stats
        statsUnavailable = stats == nil
        if info == nil { error = "Couldn't reach the server dashboard. This needs an administrator account." }
        await refreshLive()
        loaded = true
    }

    func refreshLive() async {
        if let s = try? await client.adminSessions() {
            sessions = s.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        }
        if let t = try? await client.adminTasks() { tasks = t }
    }

    /// Keep "now playing" and task progress live while the dashboard is on screen.
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { break }
            await refreshLive()
        }
    }
}

// MARK: - Dashboard

struct AdminDashboardView: View {
    @State private var model: AdminModel
    @State private var selected: AdminSession?
    @State private var confirmRestart = false
    @State private var confirmShutdown = false
    @State private var toast: String?

    init(client: JellyfinClient) {
        _model = State(initialValue: AdminModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.error, model.info == nil {
                    AdminCard { Text(error).foregroundStyle(.secondary) }
                }
                nowPlaying
                countsGrid
                if let stats = model.stats { WatchStatsCard(stats: stats) }
                else if model.loaded && model.statsUnavailable {
                    AdminCard(title: "Watch stats", systemImage: "chart.bar.fill", tint: AdminPalette.pink) {
                        Text("Install the Playback Reporting plugin on your server to see hours watched, who's watching and how much is transcoded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !model.runningTasks.isEmpty { runningTasks }
                if let storage = model.storage, !storage.drives.isEmpty { StorageCard(storage: storage) }
                manage
                powerRow
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) { HeaderGlow() }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadAll() }
        .task { await model.loadAll() }
        .task { await model.poll() }
        .sheet(item: $selected) { s in
            SessionDetailView(session: s, client: model.client) { Task { await model.refreshLive() } }
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .confirmationDialog("Restart the server?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { runPower(done: "Restarting… back in a minute.") { try await model.client.adminRestart() } }
        } message: { Text("Anyone watching will be interrupted.") }
        .confirmationDialog("Shut down the server?", isPresented: $confirmShutdown, titleVisibility: .visible) {
            Button("Shut down", role: .destructive) { runPower(done: "Server is shutting down.") { try await model.client.adminShutdown() } }
        } message: { Text("You'll need to start Jellyfin on your PC again to bring it back.") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func runPower(done: String, _ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); show(done) } catch { show(error.localizedDescription) }
        }
    }

    private func show(_ text: String) {
        withAnimation(.spring) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut) { toast = nil }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.info == nil ? Color.gray : AdminPalette.green)
                    .frame(width: 9, height: 9)
                    .shadow(color: AdminPalette.green.opacity(0.8), radius: 6)
                Text(model.info == nil ? "Connecting…" : "Online")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(model.info?.serverName ?? "Your server")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                if let v = model.info?.version { Pill(text: "Jellyfin \(v)", color: AdminPalette.violet) }
                if let os = model.info?.operatingSystemDisplayName { Pill(text: os, color: AdminPalette.blue) }
                if model.info?.hasUpdateAvailable == true {
                    Pill(text: "Update available", color: AdminPalette.yellow, systemImage: "arrow.down.circle.fill")
                }
                if model.info?.hasPendingRestart == true {
                    Pill(text: "Restart needed", color: AdminPalette.orange, systemImage: "arrow.clockwise")
                }
            }
            .lineLimit(1)
        }
        .padding(.top, 12)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Now Playing").font(.title2.weight(.bold))
                if !model.playing.isEmpty {
                    Text("\(model.playing.count)")
                        .font(.caption.weight(.heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(AdminPalette.pink))
                }
                Spacer()
                NavigationLink { DevicesAdminView(client: model.client) } label: {
                    Text("\(model.sessions.count) active").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.playing.isEmpty {
                AdminCard {
                    HStack(spacing: 14) {
                        Image(systemName: "moon.stars.fill").font(.title2).foregroundStyle(AdminPalette.violet)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All quiet").font(.headline)
                            Text("Nobody is watching or listening right now.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.playing) { s in
                            Button { selected = s } label: { SessionCard(session: s, client: model.client) }
                                .buttonStyle(CardPressStyle())
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
        }
    }

    private var countsGrid: some View {
        let c = model.counts
        let tiles: [(String, Int?, String, Color)] = [
            ("Movies", c?.movieCount, "film.fill", AdminPalette.violet),
            ("Shows", c?.seriesCount, "tv.fill", AdminPalette.pink),
            ("Episodes", c?.episodeCount, "play.rectangle.on.rectangle.fill", AdminPalette.orange),
            ("Albums", c?.albumCount, "square.stack.fill", AdminPalette.cyan),
            ("Songs", c?.songCount, "music.note", AdminPalette.green),
            ("Books", c?.bookCount, "book.fill", AdminPalette.yellow),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
            ForEach(tiles, id: \.0) { t in
                StatTile(title: t.0, value: t.1, systemImage: t.2, color: t.3)
            }
        }
    }

    private var runningTasks: some View {
        AdminCard(title: "Working on it", systemImage: "gearshape.2.fill", tint: AdminPalette.cyan) {
            ForEach(model.runningTasks) { t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t.name ?? "Task").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(t.currentProgressPercentage ?? 0))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: (t.currentProgressPercentage ?? 0) / 100).tint(AdminPalette.cyan)
                }
            }
        }
    }

    private var manage: some View {
        let c = model.client
        return VStack(alignment: .leading, spacing: 12) {
            Text("Manage").font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                ManageLink("Libraries", "Scan, refresh metadata", "books.vertical.fill", AdminPalette.violet) { LibrariesAdminView(client: c) }
                ManageLink("Users", "Access, downloads, remote", "person.2.fill", AdminPalette.pink) { UsersAdminView(client: c) }
                ManageLink("Activity", "Logins, plays, changes", "waveform.path.ecg", AdminPalette.green) { ActivityAdminView(client: c) }
                ManageLink("Scheduled Tasks", "Run or stop server jobs", "clock.arrow.2.circlepath", AdminPalette.cyan) { TasksAdminView(client: c) }
                ManageLink("Logs", "Read server and FFmpeg logs", "doc.text.magnifyingglass", AdminPalette.orange) { LogsAdminView(client: c) }
                ManageLink("Devices", "Everything signed in", "iphone.gen3", AdminPalette.blue) { DevicesAdminView(client: c) }
                ManageLink("Plugins", "What's installed", "puzzlepiece.extension.fill", AdminPalette.yellow) { PluginsAdminView(client: c) }
                ManageLink("Quick Connect", "Approve a TV sign-in code", "qrcode", AdminPalette.teal) { QuickConnectAdminView(client: c) }
                ManageLink("Full Dashboard", "Everything else, from Jellyfin", "safari.fill", AdminPalette.red) { WebDashboardView(client: c) }
            }
        }
    }

    private var powerRow: some View {
        HStack(spacing: 12) {
            Button { Task { do { try await model.client.adminScanAll(); show("Scanning all libraries") } catch { show(error.localizedDescription) } } } label: {
                Label("Scan all", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(PowerButtonStyle(color: AdminPalette.violet))
            Button { confirmRestart = true } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .buttonStyle(PowerButtonStyle(color: AdminPalette.orange))
            Button { confirmShutdown = true } label: { Label("Shut down", systemImage: "power") }
                .buttonStyle(PowerButtonStyle(color: AdminPalette.red))
        }
    }
}

private struct HeaderGlow: View {
    var body: some View {
        ZStack {
            Circle().fill(AdminPalette.violet.opacity(0.45)).frame(width: 340).blur(radius: 90).offset(x: -120, y: -80)
            Circle().fill(AdminPalette.pink.opacity(0.35)).frame(width: 300).blur(radius: 90).offset(x: 140, y: -40)
            Circle().fill(AdminPalette.cyan.opacity(0.25)).frame(width: 260).blur(radius: 90).offset(x: 20, y: 60)
        }
        .frame(height: 320)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

struct PowerButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct ManageLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    let destination: () -> Destination

    init(_ title: String, _ subtitle: String, _ systemImage: String, _ color: Color,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
        self.color = color; self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: color.opacity(0.4), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        }
        .buttonStyle(CardPressStyle())
    }
}

struct StatTile: View {
    let title: String
    let value: Int?
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage).font(.headline).foregroundStyle(color)
            Text(value.map { $0.formatted() } ?? "–")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(color.opacity(0.25)))
        )
    }
}

// MARK: - Now playing card

struct SessionCard: View {
    let session: AdminSession
    let client: JellyfinClient

    var body: some View {
        let item = session.nowPlayingItem
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if let item {
                        RemoteImage(url: item.isAudio ? client.posterURL(for: item, width: 600)
                                                      : client.backdropURL(for: item, width: 800))
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Pill(text: AdminPalette.label(for: session.method), color: AdminPalette.color(for: session.method))
                    if session.isPaused { Pill(text: "Paused", color: .white, systemImage: "pause.fill") }
                    Spacer()
                    Image(systemName: session.isLocal ? "house.fill" : "globe")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text(item?.displayTitle ?? "").font(.headline).lineLimit(1)
                if let ep = item?.episodeLabel ?? item?.artistLine {
                    Text(ep).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(session.userName ?? "Someone").fontWeight(.semibold)
                    Text("·")
                    Text(session.deviceName ?? session.client ?? "")
                }
                .font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                if let p = session.progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(AdminPalette.color(for: session.method)).frame(width: g.size.width * p)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: AdminPalette.color(for: session.method).opacity(0.25), radius: 16, y: 8)
    }
}

// MARK: - Watch stats

struct WatchStatsCard: View {
    let stats: WatchStats

    var body: some View {
        AdminCard(title: "Watch time · last 14 days", systemImage: "chart.bar.fill", tint: AdminPalette.pink) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", stats.totalHours))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("hours").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart(stats.days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", d.hours))
                    .foregroundStyle(LinearGradient(colors: [AdminPalette.pink, AdminPalette.violet], startPoint: .top, endPoint: .bottom))
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .frame(height: 150)

            if !stats.methods.isEmpty {
                Divider().overlay(.white.opacity(0.08))
                HStack(spacing: 18) {
                    Chart(stats.methods) { m in
                        SectorMark(angle: .value("Plays", m.count), innerRadius: .ratio(0.62), angularInset: 2)
                            .foregroundStyle(AdminPalette.methodColor(m.label))
                            .cornerRadius(4)
                    }
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it's played · 30 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let total = max(1, stats.methods.reduce(0) { $0 + $1.count })
                        ForEach(stats.methods) { m in
                            HStack(spacing: 8) {
                                Circle().fill(AdminPalette.methodColor(m.label)).frame(width: 8, height: 8)
                                Text(m.label).font(.footnote)
                                Spacer()
                                Text("\(m.count * 100 / total)%").font(.footnote.monospacedDigit().weight(.semibold))
                            }
                        }
                    }
                }
            }

            if !stats.users.isEmpty {
                Divider().overlay(.white.opacity(0.08))
                Text("Top viewers · 30 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let top = max(0.01, stats.users.first?.hours ?? 1)
                ForEach(stats.users) { u in
                    RankRow(name: u.name, detail: String(format: "%.1f h", u.hours), fraction: u.hours / top, color: AdminPalette.violet)
                }
            }
            if !stats.titles.isEmpty {
                Divider().overlay(.white.opacity(0.08))
                Text("Most watched · 30 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let top = max(0.01, stats.titles.first?.hours ?? 1)
                ForEach(stats.titles) { t in
                    RankRow(name: t.name, detail: "\(t.plays) plays", fraction: t.hours / top, color: AdminPalette.orange)
                }
            }
        }
    }
}

struct RankRow: View {
    let name: String
    let detail: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline).lineLimit(1)
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(color.gradient).frame(width: max(6, g.size.width * fraction))
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Storage

struct StorageCard: View {
    let storage: SystemStorage

    var body: some View {
        AdminCard(title: "Storage", systemImage: "internaldrive.fill", tint: AdminPalette.blue) {
            ForEach(Array(storage.drives.enumerated()), id: \.offset) { pair in
                let entry = pair.element
                let d = entry.drive
                let color: Color = d.fraction > 0.9 ? AdminPalette.red : d.fraction > 0.75 ? AdminPalette.orange : AdminPalette.blue
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(d.driveLabel).font(.subheadline.weight(.bold))
                        Text(entry.uses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\((d.freeSpace ?? 0).bytes) free").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.1))
                            Capsule().fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * d.fraction)
                        }
                    }
                    .frame(height: 10)
                    Text("\((d.usedSpace ?? 0).bytes) of \(d.total.bytes) used")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
