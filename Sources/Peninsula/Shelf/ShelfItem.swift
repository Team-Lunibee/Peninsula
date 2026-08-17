import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    /// Filename inside the shelf directory. Stored relative so the store keeps
    /// working if the container moves between OS versions.
    var storedFilename: String
    var addedAt: Date
    var byteSize: Int64
    /// Where the file came from, used to recognise a re-drop of something the
    /// shelf already holds. Optional so indexes written before this existed
    /// still decode.
    var sourcePath: String?

    func url(in directory: URL) -> URL {
        directory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(storedFilename)
    }

    var contentType: UTType? {
        UTType(filenameExtension: (storedFilename as NSString).pathExtension)
    }
}

/// Thumbnails for shelf items, generated once and reused.
///
/// QuickLook renders off the main actor and can take a beat for large files, so
/// the icon shows first and the thumbnail replaces it when it arrives.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var cache: [UUID: NSImage] = [:]
    private var order: [UUID] = []
    private var inFlight: Set<UUID> = []
    private var icons: [UUID: NSImage] = [:]

    /// The shelf itself has no hard limit, so neither would this.
    private static let limit = 120

    func cached(_ id: UUID) -> NSImage? { cache[id] }

    /// The placeholder a tile shows until its thumbnail arrives.
    ///
    /// Cached per item rather than fetched per draw. `NSWorkspace.icon(forFile:)`
    /// is a round trip to IconServices, and the tile that calls it re-evaluates
    /// its body on every hover, every scroll frame and every shelf change — so a
    /// shelf of files QuickLook cannot thumbnail was asking the system for the
    /// same icons over and over for as long as the panel stayed open.
    ///
    /// Keyed by item, not by file extension, because an icon is not a function
    /// of the extension: an app carries its own, and so does any file with a
    /// custom icon resource. Sharing the thumbnail cache's key also means
    /// `forget(_:)` already clears both.
    func icon(for id: UUID, url: URL) -> NSImage {
        if let existing = icons[id] { return existing }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = icon
        return icon
    }

    func thumbnail(for item: ShelfItem, url: URL, size: CGSize) async -> NSImage? {
        if let existing = cache[item.id] { return existing }
        guard !inFlight.contains(item.id) else { return nil }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard let representation else { return nil }

        let image = NSImage(cgImage: representation.cgImage, size: size)
        if cache[item.id] == nil {
            order.append(item.id)
        }
        cache[item.id] = image

        while order.count > Self.limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return image
    }

    func forget(_ id: UUID) {
        cache.removeValue(forKey: id)
        icons.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}
