import AppKit

/// Pulls a usable accent colour out of album artwork.
///
/// Averaging the whole image tends toward mud, so this buckets a downsampled
/// copy by hue and picks the most vivid bucket that carries real weight —
/// closer to how the artwork reads to the eye.
enum ArtworkPalette {
    private static let sampleEdge = 24
    private static let bucketCount = 24

    private struct Bucket {
        var score: Double = 0
        var samples: Double = 0
        /// Hue is circular, so it is averaged as unit vectors rather than
        /// numerically — otherwise reds either side of 0 average to cyan.
        var hueX: Double = 0
        var hueY: Double = 0
        var saturation: Double = 0
        var brightness: Double = 0
    }

    /// Call off the main actor: artwork decoding must never block the notch.
    static func accent(for image: NSImage) -> NSColor? {
        guard let pixels = downsample(image), !pixels.isEmpty else { return nil }

        var buckets = [Bucket](repeating: Bucket(), count: bucketCount)

        for pixel in pixels {
            let (hue, saturation, brightness) = hsb(pixel)

            // Near-black, near-white and washed-out pixels dominate most covers
            // without saying anything about their colour.
            guard brightness > 0.15, brightness < 0.97, saturation > 0.2 else { continue }

            let index = min(bucketCount - 1, Int(hue * Double(bucketCount)))
            // Vivid pixels count for more than merely present ones.
            let score = saturation * saturation * brightness
            let angle = hue * 2 * .pi

            buckets[index].score += score
            buckets[index].samples += 1
            buckets[index].hueX += cos(angle) * score
            buckets[index].hueY += sin(angle) * score
            buckets[index].saturation += saturation
            buckets[index].brightness += brightness
        }

        guard
            let best = buckets.indices.max(by: { buckets[$0].score < buckets[$1].score }),
            buckets[best].samples > 0
        else { return nil }

        let bucket = buckets[best]
        var hue = atan2(bucket.hueY, bucket.hueX) / (2 * .pi)
        if hue < 0 { hue += 1 }

        // Push toward a colour that stays legible as a tint on near-black
        // chrome: keep it saturated, keep it bright enough to read.
        let saturation = min(1, max(0.55, bucket.saturation / bucket.samples))
        let brightness = min(1, max(0.72, bucket.brightness / bucket.samples))

        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func hsb(_ pixel: SIMD3<Double>) -> (hue: Double, saturation: Double, brightness: Double) {
        let r = pixel.x, g = pixel.y, b = pixel.z
        let maxComponent = max(r, g, b)
        let minComponent = min(r, g, b)
        let delta = maxComponent - minComponent

        var hue: Double = 0
        if delta > 0 {
            if maxComponent == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxComponent == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        let saturation = maxComponent == 0 ? 0 : delta / maxComponent
        return (hue, saturation, maxComponent)
    }

    private static func downsample(_ image: NSImage) -> [SIMD3<Double>]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let edge = sampleEdge
        var raw = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn: Bool = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: edge,
                height: edge,
                bitsPerComponent: 8,
                bytesPerRow: edge * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return nil }

        var pixels: [SIMD3<Double>] = []
        pixels.reserveCapacity(edge * edge)
        for index in stride(from: 0, to: raw.count, by: 4) {
            let alpha = Double(raw[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            pixels.append(SIMD3(
                Double(raw[index]) / 255,
                Double(raw[index + 1]) / 255,
                Double(raw[index + 2]) / 255
            ))
        }
        return pixels
    }
}
