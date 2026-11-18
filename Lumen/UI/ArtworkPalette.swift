import SwiftUI
import UIKit

/// A color pulled from artwork, used to tint whole screens Apple TV–style.
struct ArtColor: Sendable, Equatable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    /// Bold, readable version for backgrounds behind white text.
    var background: Color { Color(hue: hue, saturation: min(1, max(0.55, saturation * 1.15)), brightness: 0.42) }
    /// Brighter version for accents (buttons, progress, badges).
    var accent: Color { Color(hue: hue, saturation: min(1, max(0.6, saturation * 1.2)), brightness: 0.95) }
}

actor ArtworkPalette {
    static let shared = ArtworkPalette()
    private var cache: [URL: ArtColor] = [:]

    func color(for url: URL) async -> ArtColor? {
        if let hit = cache[url] { return hit }
        guard let result = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: result.0)?.cgImage,
              let color = Self.vibrantColor(in: image) else { return nil }
        cache[url] = color
        return color
    }

    /// Finds the most prominent *colorful* hue in an image (ignoring near-black, near-white and greys),
    /// so a mostly dark poster with a red title still reads as red.
    static func vibrantColor(in image: CGImage) -> ArtColor? {
        let w = 40, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let buckets = 18
        var weight = [Double](repeating: 0, count: buckets)
        var satSum = [Double](repeating: 0, count: buckets)
        var hueX = [Double](repeating: 0, count: buckets)
        var hueY = [Double](repeating: 0, count: buckets)
        var fallback = (r: 0.0, g: 0.0, b: 0.0)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            fallback.r += r; fallback.g += g; fallback.b += b
            let maxC = max(r, g, b), minC = min(r, g, b)
            let v = maxC, delta = maxC - minC
            guard v > 0.18, v < 0.98, delta > 0.12 else { continue }
            let s = delta / maxC
            var hue: Double
            if maxC == r { hue = (g - b) / delta } else if maxC == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let wgt = s * s * v
            let bucket = min(buckets - 1, Int(hue * Double(buckets)))
            weight[bucket] += wgt
            satSum[bucket] += s * wgt
            hueX[bucket] += cos(hue * 2 * .pi) * wgt
            hueY[bucket] += sin(hue * 2 * .pi) * wgt
        }

        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.6 {
            var hue = atan2(hueY[best], hueX[best]) / (2 * .pi)
            if hue < 0 { hue += 1 }
            return ArtColor(hue: hue, saturation: satSum[best] / weight[best], brightness: 0.8)
        }
        // Mostly grey/black artwork: use the average, with a hint of the app's violet.
        let n = Double(w * h)
        let ui = UIColor(red: fallback.r / n, green: fallback.g / n, blue: fallback.b / n, alpha: 1)
        var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ui.getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
        return ArtColor(hue: ss < 0.15 ? 0.72 : Double(hh), saturation: max(0.35, Double(ss)), brightness: 0.6)
    }
}

/// Full-screen backdrop that washes the page in the artwork's color, fading to near-black.
struct TintedBackdrop: View {
    let color: ArtColor?

    var body: some View {
        let base = color?.background ?? Theme.accent.opacity(0.35)
        LinearGradient(stops: [
            .init(color: base, location: 0),
            .init(color: base.opacity(0.55), location: 0.45),
            .init(color: Theme.background, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: color)
    }
}

extension View {
    /// Loads the dominant color of an image into a binding.
    func artColor(from url: URL?, into binding: Binding<ArtColor?>) -> some View {
        task(id: url) {
            guard let url else { return }
            if let c = await ArtworkPalette.shared.color(for: url) {
                withAnimation(.easeInOut(duration: 0.8)) { binding.wrappedValue = c }
            }
        }
    }
}
