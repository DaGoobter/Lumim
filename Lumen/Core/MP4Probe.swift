import Foundation

/// Looks inside an MP4/MOV before it plays, to spot video that Apple's player shows as a black screen:
/// HEVC tagged 'hev1' or H.264 tagged 'avc3' (setup data inside the video instead of the file header).
///
/// Reads only the file's index (a few hundred KB at most, with HTTP range requests) and remembers the answer per
/// title, so the second time it's instant. Those files then go straight to the server's repackaged stream
/// instead of waiting for the no-picture check.
enum MP4Probe {
    private static let cacheKey = "huefin.inBandSetupItems"
    private static let window = 512 * 1024

    /// Remembered results: item id → needs the server's stream.
    static func remembered(_ itemId: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Bool])?[itemId]
    }

    static func remember(_ itemId: String, needsServerStream: Bool) {
        var all = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Bool]) ?? [:]
        if all.count > 2000 { all.removeAll() }
        all[itemId] = needsServerStream
        UserDefaults.standard.set(all, forKey: cacheKey)
    }

    /// True if the file's video is tagged 'hev1' or 'avc3'. Gives up (false) after ~2 seconds or on any error.
    static func needsServerStream(itemId: String, url: URL, authorization: String) async -> Bool {
        if let known = remembered(itemId) { return known }
        let result = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await scan(url: url, authorization: authorization) }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result else { return false }   // too slow to tell: play normally (the picture check still runs)
        remember(itemId, needsServerStream: result)
        return result
    }

    private static func fetch(_ url: URL, _ auth: String, from offset: Int64, length: Int) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else { return nil }
        return data.count > length ? data.prefix(length) : data
    }

    /// Walks the top-level boxes to the 'moov' index and looks for the video sample entry's four-letter tag.
    private static func scan(url: URL, authorization: String) async -> Bool? {
        var offset: Int64 = 0
        for _ in 0..<8 {
            guard let head = await fetch(url, authorization, from: offset, length: window), head.count >= 8 else { return nil }
            var i = 0
            while i + 8 <= head.count {
                let b = [UInt8](head[(head.startIndex + i)..<(head.startIndex + i + 8)])
                var size = Int64(b[0]) << 24 | Int64(b[1]) << 16 | Int64(b[2]) << 8 | Int64(b[3])
                let type = String(bytes: b[4..<8], encoding: .ascii) ?? ""
                if size == 1 {
                    guard i + 16 <= head.count else { break }
                    let ext = [UInt8](head[(head.startIndex + i + 8)..<(head.startIndex + i + 16)])
                    size = ext.reduce(Int64(0)) { $0 << 8 | Int64($1) }
                }
                if type == "moov" {
                    // The sample description sits near the start of the index; read from here if we must.
                    let body = i == 0 ? head : (await fetch(url, authorization, from: offset + Int64(i), length: window) ?? Data())
                    return verdict(body)
                }
                if size < 8 { return nil }   // size 0 (to end of file) or broken: can't tell
                if Int64(i) + size > Int64(head.count) {
                    offset += Int64(i) + size   // jump past a box (usually the video data) we didn't download
                    break
                }
                i += Int(size)
            }
            if i + 8 > head.count && head.count < window { return nil }   // reached the end without an index
            if i + 8 > head.count { offset += Int64(i) }
        }
        return nil
    }

    private static func verdict(_ data: Data) -> Bool? {
        // 'dvhe' is the Dolby Vision form of 'hev1'.
        ["hev1", "avc3", "dvhe"].contains { data.range(of: Data($0.utf8)) != nil }
    }
}
