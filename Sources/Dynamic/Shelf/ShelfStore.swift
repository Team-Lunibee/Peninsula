import AppKit
import Observation
import UniformTypeIdentifiers

/// The notch's file shelf.
///
/// Dropped files are *copied* into the app's own container rather than
/// referenced in place, so the shelf keeps working after the original is moved,
/// renamed, or deleted — which is exactly what happens when the shelf is used
/// as a staging area between Finder windows.
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private(set) var lastError: String?

    private let directory: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        directory = base
            .appendingPathComponent("Dynamic", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var isEmpty: Bool { items.isEmpty }

    func url(for item: ShelfItem) -> URL {
        item.url(in: directory)
    }

    var urls: [URL] { items.map(url(for:)) }

    // MARK: - Mutation

    enum Outcome {
        case added
        case promoted
        case failed
    }

    /// Returns how many items ended up at the front of the shelf, whether they
    /// were newly copied or already present.
    @discardableResult
    func add(contentsOf sources: [URL]) -> Int {
        var touched = 0
        for source in sources where ingest(source) != .failed {
            touched += 1
        }
        if touched > 0 {
            persist()
            Haptics.tap(.levelChange)
        }
        return touched
    }

    /// Re-dropping a file the shelf already holds moves it to the front rather
    /// than making a second copy. Two identical tiles is never what someone
    /// meant, and the gesture reads as "I want this one to hand".
    private func promote(existing index: Int) {
        guard index > 0 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
    }

    private func ingest(_ source: URL) -> Outcome {
        // Security-scoped access matters for files handed over by other apps;
        // it is a no-op for plain drags from Finder.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        if let existing = items.firstIndex(where: { $0.sourcePath == source.path }) {
            promote(existing: existing)
            return .promoted
        }

        let id = UUID()
        let itemDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        // `lastPathComponent` cannot contain a separator, so traversal is not
        // possible — but it can be "." or "..", which would resolve the
        // destination to the item directory or its parent and turn a copy into
        // something that writes outside where it was meant to.
        let filename = Self.sanitised(source.lastPathComponent)
        let destination = itemDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)

            let values = try? destination.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)

            items.insert(
                ShelfItem(
                    id: id,
                    displayName: source.deletingPathExtension().lastPathComponent,
                    storedFilename: filename,
                    addedAt: Date(),
                    byteSize: size,
                    sourcePath: source.path
                ),
                at: 0
            )
            return .added
        } catch {
            try? FileManager.default.removeItem(at: itemDirectory)
            lastError = "\(filename)을(를) 추가하지 못했습니다: \(error.localizedDescription)"
            Log.shelf.error("shelf ingest failed for \(filename, privacy: .private): \(error.localizedDescription)")
            return .failed
        }
    }

    /// Falls back to the item's own identifier when the source has no usable
    /// name, which keeps the stored path inside the item directory whatever
    /// arrives on the pasteboard.
    private static func sanitised(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "item" }
        return trimmed.replacingOccurrences(of: "/", with: "_")
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        ThumbnailCache.shared.forget(item.id)
        let itemDirectory = directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: itemDirectory)
        persist()
    }

    func removeAll() {
        for item in items {
            ThumbnailCache.shared.forget(item.id)
            let itemDirectory = directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: itemDirectory)
        }
        items.removeAll()
        persist()
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: item)])
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(url(for: item))
    }

    /// Drops items whose retention window has passed, plus any whose backing
    /// file vanished (a manually cleared container, a failed copy).
    func prune() {
        let days = Preferences.shared.shelfExpiryDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : .distantPast

        var survivors: [ShelfItem] = []
        var changed = false

        for item in items {
            let path = url(for: item).path
            let expired = days > 0 && item.addedAt < cutoff
            let missing = !FileManager.default.fileExists(atPath: path)

            if expired || missing {
                changed = true
                ThumbnailCache.shared.forget(item.id)
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
                )
            } else {
                survivors.append(item)
            }
        }

        if changed {
            items = survivors
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ShelfItem].self, from: data)) ?? []
        prune()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.shelf.error("could not write shelf index: \(error.localizedDescription)")
        }
    }
}

/// AirDrop hand-off.
enum AirDrop {
    /// `true` when the sheet was presented. AirDrop is unavailable on some
    /// hardware and configurations, so callers should fall back to a share
    /// picker when this returns `false`.
    @MainActor
    @discardableResult
    static func send(_ urls: [URL], from view: NSView?, anchor: CGRect? = nil) -> Bool {
        guard !urls.isEmpty else { return false }

        // AirDrop's window belongs to the calling app, and an accessory app
        // that has never been activated cannot put one on screen. Without this
        // the service reports success and nothing appears.
        NSApp.activate(ignoringOtherApps: true)
        view?.window?.makeKeyAndOrderFront(nil)

        if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
            return true
        }

        Log.shelf.warning("AirDrop service unavailable; falling back to the share picker")

        guard let view else { return false }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(
            relativeTo: anchor ?? CGRect(x: view.bounds.midX, y: view.bounds.minY, width: 1, height: 1),
            of: view,
            preferredEdge: .minY
        )
        return true
    }
}
