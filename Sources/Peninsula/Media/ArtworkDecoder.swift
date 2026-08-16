import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns the adapter's base64 artwork into an image sized for the notch.
///
/// `NSImage(data:)` is the obvious call and the wrong one. Album art routinely
/// arrives at 1400x1400 or larger, and decoding it materialises the entire
/// bitmap — a 3000x3000 cover is ~36MB of pixels for something displayed at
/// 96 points. Measured, that put the app's peak footprint at 135MB.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked
/// for, so the full bitmap never exists. The cost is the same JPEG parse; the
/// saving is every byte after it.
enum ArtworkDecoder {
    /// Largest size the artwork is ever drawn at, times the densest scale we
    /// might be composited onto. Anything beyond this is pixels nobody sees.
    private static let maximumPixelSize = 256

    /// Runs off the main actor.
    static func decode(base64: String) -> NSImage? {
        guard
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            return nil
        }

        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
    }
}
