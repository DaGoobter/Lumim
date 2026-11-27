import Foundation
import CoreGraphics

/// Text subtitles that Huefin draws itself on top of Apple's player, timed to the picture.
///
/// Why: the server's own subtitle stream for Apple's player (WebVTT inside HLS) drifts out of sync, especially
/// after a seek, and choosing any subtitle used to force the whole video onto the server's stream. Downloading the
/// subtitle file once and drawing it here keeps it in sync, keeps the original file playing untouched, makes
/// switching subtitles instant, and lets you nudge the timing.
@MainActor
final class AppSubtitles {
    struct Cue { let start: Double; let end: Double; let text: String }
    private(set) var cues: [Cue] = []
    #if canImport(Libass)
    private var ass: AssRenderer?
    #endif
    let streamIndex: Int

    /// Picture subtitles (Blu-ray, DVD) can't be downloaded as text; those still go through the server.
    static func isText(_ s: MediaStream) -> Bool {
        let c = (s.codec ?? "").lowercased()
        return !["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "xsub"].contains(c)
    }

    private init(streamIndex: Int) { self.streamIndex = streamIndex }

    /// Downloads the whole subtitle (the server converts any text format to SRT; styled ASS is kept as ASS).
    static func load(client: JellyfinClient, itemId: String, mediaSourceId: String, stream: MediaStream) async -> AppSubtitles? {
        guard let index = stream.index else { return nil }
        let codec = (stream.codec ?? "").lowercased()
        let styled = codec == "ass" || codec == "ssa"
        let r = AppSubtitles(streamIndex: index)
        #if canImport(Libass)
        if styled, let data = await fetch(client, itemId, mediaSourceId, index, "ass"), let a = AssRenderer() {
            a.addFile(0, data: data)
            if a.has(0) { r.ass = a; return r }
        }
        #endif
        guard let data = await fetch(client, itemId, mediaSourceId, index, "srt"),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        r.cues = parseSRT(text)
        return r.cues.isEmpty ? nil : r
    }

    private static func fetch(_ c: JellyfinClient, _ itemId: String, _ sourceId: String, _ index: Int, _ ext: String) async -> Data? {
        var req = URLRequest(url: c.url("Videos/\(itemId)/\(sourceId)/Subtitles/\(index)/0/Stream.\(ext)"))
        req.setValue(c.authorizationHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// What to show at `t` seconds of the video.
    func subtitle(at t: Double, videoWidth: Int, videoHeight: Int) -> EngineSubtitle? {
        #if canImport(Libass)
        if let ass {
            guard let (img, rect) = ass.render(0, atMs: Int64(t * 1000), videoWidth: max(videoWidth, 640),
                                               videoHeight: max(videoHeight, 360)) else { return nil }
            return .image(img, rect)
        }
        #endif
        // Binary search for the last cue starting at or before t.
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        // Overlapping cues: show every one that's on screen now.
        var lines: [String] = []
        var i = found
        while i >= 0 && i > found - 8 {
            if cues[i].start <= t && t < cues[i].end { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : .text(lines.joined(separator: "\n"))
    }

    static func parseSRT(_ s: String) -> [Cue] {
        var out: [Cue] = []
        let blocks = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let e = time(parts[1]) else { continue }
            var text = lines[(ti + 1)...].joined(separator: "\n")
            // Drop formatting tags (<i>, <font …>, {\an8}) — the overlay has its own style.
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(Cue(start: a, end: e, text: text)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func time(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let p = t.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
