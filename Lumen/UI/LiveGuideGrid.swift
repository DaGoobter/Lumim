import SwiftUI

/// TV-guide grid: channels down the side, time across the top, programs as blocks.
struct LiveGuideGrid: View {
    @Environment(AppState.self) private var app
    let channels: [BaseItem]
    let guide: [String: [ProgramInfo]]
    let onPlay: (BaseItem) -> Void

    @State private var selected: (program: ProgramInfo, channel: BaseItem)?
    @State private var showDetail = false

    private let rowHeight: CGFloat = 64
    private let logoWidth: CGFloat = 78
    private let pointsPerMinute: CGFloat = 5
    private let hours: Double = 6

    /// Now, rounded down to the half hour.
    private var start: Date {
        let t = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 1800).rounded(.down) * 1800)
    }

    var body: some View {
        let origin = start
        let end = origin.addingTimeInterval(hours * 3600)
        let width = CGFloat(hours * 60) * pointsPerMinute
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    // Channel column
                    VStack(spacing: 4) {
                        Color.clear.frame(height: 30)
                        ForEach(channels) { ch in
                            Button { onPlay(ch) } label: { logo(ch) }
                                .buttonStyle(CardPressStyle())
                        }
                    }
                    .frame(width: logoWidth)

                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ruler(origin: origin)
                            ForEach(channels) { ch in
                                row(ch, origin: origin, end: end, now: context.date)
                            }
                        }
                        .frame(width: width, alignment: .leading)
                        .overlay(alignment: .topLeading) {
                            // Now line
                            let x = CGFloat(context.date.timeIntervalSince(origin) / 60) * pointsPerMinute
                            Rectangle().fill(Theme.red).frame(width: 2)
                                .shadow(color: Theme.red.opacity(0.8), radius: 4)
                                .offset(x: x)
                                .allowsHitTesting(false)
                        }
                        .padding(.trailing, 20)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showDetail) {
            if let selected {
                ProgramDetailSheet(program: selected.program, channel: selected.channel) {
                    showDetail = false
                    onPlay(selected.channel)
                }
            }
        }
    }

    private func ruler(origin: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Int(hours * 2), id: \.self) { i in
                let t = origin.addingTimeInterval(Double(i) * 1800)
                Text(t.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30 * pointsPerMinute, alignment: .leading)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.2)).frame(width: 1) }
            }
        }
        .frame(height: 30)
    }

    private func row(_ ch: BaseItem, origin: Date, end: Date, now: Date) -> some View {
        let programs = (guide[ch.id] ?? []).filter { ($0.end ?? .distantPast) > origin && ($0.start ?? .distantFuture) < end }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.03))
            if programs.isEmpty {
                Button { onPlay(ch) } label: {
                    Text(ch.name ?? "Live").font(.subheadline.weight(.semibold)).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(CardPressStyle())
            }
            ForEach(programs) { p in
                let s = max(p.start ?? origin, origin)
                let e = min(p.end ?? end, end)
                let x = CGFloat(s.timeIntervalSince(origin) / 60) * pointsPerMinute
                let w = max(2, CGFloat(e.timeIntervalSince(s) / 60) * pointsPerMinute - 3)
                let airing = (p.start ?? .distantFuture) <= now && (p.end ?? .distantPast) > now
                Button {
                    if airing { onPlay(ch) } else { selected = (p, ch); showDetail = true }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name ?? "Program").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([p.start?.formatted(date: .omitted, time: .shortened), p.episodeTitle]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: w, height: rowHeight, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(airing ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                            .opacity(airing ? 0.6 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if airing, let prog = p.progress(at: now) {
                            Capsule().fill(.white.opacity(0.85))
                                .frame(width: max(2, (w - 16) * prog), height: 3)
                                .padding(.horizontal, 8).padding(.bottom, 6)
                        }
                    }
                }
                .buttonStyle(CardPressStyle())
                .offset(x: x)
                .contextMenu {
                    Button { selected = (p, ch); showDetail = true } label: { Label("Details", systemImage: "info.circle") }
                    Button { onPlay(ch) } label: { Label("Watch \(ch.name ?? "channel")", systemImage: "play.fill") }
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func logo(_ ch: BaseItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08))
            AsyncImage(url: app.client?.imageURL(ch.id, maxWidth: 200, tag: ch.imageTag("primary"))) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 2) {
                        if let n = ch.channelNumber { Text(n).font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor) }
                        Text(String((ch.name ?? "TV").prefix(4)).uppercased())
                            .font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .frame(width: logoWidth - 8, height: rowHeight)
    }
}

struct ProgramDetailSheet: View {
    let program: ProgramInfo
    let channel: BaseItem
    let onWatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(channel.name ?? "Channel").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
            Text(program.name ?? "Program").font(.title2.weight(.bold))
            if let ep = program.episodeTitle, !ep.isEmpty { Text(ep).font(.headline).foregroundStyle(.secondary) }
            if let s = program.start, let e = program.end {
                Text("\(s.formatted(date: .abbreviated, time: .shortened)) – \(e.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let o = program.overview { Text(o).font(.callout) }
            Spacer()
            Button(action: onWatch) {
                Label("Watch \(channel.name ?? "channel") now", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
