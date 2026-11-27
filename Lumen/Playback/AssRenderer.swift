#if canImport(Libass)
import Foundation
import CoreGraphics
import Libass

/// Styled subtitles (ASS/SSA: the fonts, colours, outlines, positions, signs and karaoke that anime releases use),
/// drawn by libass — the same renderer mpv uses — so the native engine shows them exactly as intended.
final class AssRenderer {
    private let library: OpaquePointer
    private var renderer: OpaquePointer?
    private var tracks: [Int32: UnsafeMutablePointer<ASS_Track>] = [:]
    private let lock = NSLock()
    private var size = (w: 0, h: 0)
    private var cached: (track: Int32, image: CGImage, rect: CGRect)?
    private var buffer: [UInt8] = []

    init?() {
        guard let lib = ass_library_init() else { return nil }
        library = lib
    }

    deinit {
        for t in tracks.values { ass_free_track(t) }
        if let renderer { ass_renderer_done(renderer) }
        ass_library_done(library)
    }

    /// Fonts that come inside the file (MKV attachments) — anime styles usually depend on them.
    func addFont(name: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ass_add_font(library, name, p, Int32(data.count))
        }
    }

    /// An embedded subtitle track; `header` is the track's style section (its codec private data).
    func addTrack(_ id: Int32, header: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard tracks[id] == nil, let t = ass_new_track(library) else { return }
        if let header, !header.isEmpty {
            header.withUnsafeBytes { raw in
                if let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) { ass_process_codec_private(t, p, Int32(header.count)) }
            }
        }
        tracks[id] = t
    }

    /// A whole .ass/.ssa file (subtitles stored next to the video).
    func addFile(_ id: Int32, data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard tracks[id] == nil else { return }
        var bytes = [CChar](repeating: 0, count: data.count + 1)
        data.withUnsafeBytes { raw in
            if let p = raw.baseAddress { memcpy(&bytes, p, data.count) }
        }
        if let t = ass_read_memory(library, &bytes, data.count, nil) { tracks[id] = t }
    }

    func has(_ id: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return tracks[id] != nil }

    /// One subtitle event as read from the file (libass skips ones it has already seen, so seeking back is fine).
    func add(_ id: Int32, data: UnsafePointer<UInt8>, size: Int, startMs: Int64, durationMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let t = tracks[id] else { return }
        data.withMemoryRebound(to: CChar.self, capacity: size) { ass_process_chunk(t, $0, Int32(size), startMs, durationMs) }
    }

    /// The subtitles at `ms`, as a picture and where it goes (0…1 of the video frame). Only redrawn when it changes.
    func render(_ id: Int32, atMs ms: Int64, videoWidth: Int, videoHeight: Int) -> (CGImage, CGRect)? {
        lock.lock(); defer { lock.unlock() }
        guard let t = tracks[id], videoWidth > 0, videoHeight > 0 else { return nil }
        // Draw at up to 1920 wide: sharp on any screen without the cost of a 4K canvas.
        let scale = min(1, 1920 / Double(videoWidth))
        let w = Int(Double(videoWidth) * scale), h = Int(Double(videoHeight) * scale)
        if renderer == nil {
            guard let r = ass_renderer_init(library) else { return nil }
            renderer = r
            ass_set_fonts(r, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        }
        guard let r = renderer else { return nil }
        if size.w != w || size.h != h {
            ass_set_frame_size(r, Int32(w), Int32(h))
            ass_set_storage_size(r, Int32(w), Int32(h))
            size = (w, h); cached = nil
        }
        var changed: Int32 = 0
        let first = ass_render_frame(r, t, ms, &changed)
        if changed == 0, let c = cached, c.track == id { return (c.image, c.rect) }
        guard let first else { cached = nil; return nil }

        // Bounding box of everything on screen, so only that area is composited.
        var minX = w, minY = h, maxX = 0, maxY = 0
        var img: UnsafeMutablePointer<ASS_Image>? = first
        while let i = img?.pointee {
            if i.w > 0 && i.h > 0 {
                minX = min(minX, Int(i.dst_x)); minY = min(minY, Int(i.dst_y))
                maxX = max(maxX, Int(i.dst_x + i.w)); maxY = max(maxY, Int(i.dst_y + i.h))
            }
            img = i.next
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(w, maxX); maxY = min(h, maxY)
        guard maxX > minX, maxY > minY else { cached = nil; return nil }
        let bw = maxX - minX, bh = maxY - minY
        if buffer.count < bw * bh * 4 { buffer = [UInt8](repeating: 0, count: bw * bh * 4) }
        else { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, bw * bh * 4) } }

        buffer.withUnsafeMutableBufferPointer { out in
            var img: UnsafeMutablePointer<ASS_Image>? = first
            while let i = img?.pointee {
                defer { img = i.next }
                guard i.w > 0, i.h > 0, let bitmap = i.bitmap else { continue }
                let c = i.color
                let r = UInt32((c >> 24) & 0xFF), g = UInt32((c >> 16) & 0xFF), b = UInt32((c >> 8) & 0xFF)
                let opacity = 255 - UInt32(c & 0xFF)
                for y in 0..<Int(i.h) {
                    let oy = Int(i.dst_y) + y - minY
                    guard oy >= 0, oy < bh else { continue }
                    for x in 0..<Int(i.w) {
                        let ox = Int(i.dst_x) + x - minX
                        guard ox >= 0, ox < bw else { continue }
                        let k = UInt32(bitmap[y * Int(i.stride) + x]) * opacity / 255
                        guard k > 0 else { continue }
                        let o = (oy * bw + ox) * 4
                        let inv = 255 - k
                        // Premultiplied "over".
                        out[o]     = UInt8((r * k + UInt32(out[o]) * inv) / 255)
                        out[o + 1] = UInt8((g * k + UInt32(out[o + 1]) * inv) / 255)
                        out[o + 2] = UInt8((b * k + UInt32(out[o + 2]) * inv) / 255)
                        out[o + 3] = UInt8((255 * k + UInt32(out[o + 3]) * inv) / 255)
                    }
                }
            }
        }
        let data = Data(buffer[0..<(bw * bh * 4)])
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let rect = CGRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h), width: Double(bw) / Double(w), height: Double(bh) / Double(h))
        cached = (id, image, rect)
        return (image, rect)
    }
}
#endif
