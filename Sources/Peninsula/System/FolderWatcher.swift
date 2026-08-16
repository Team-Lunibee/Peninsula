import Foundation

/// Reports files appearing in a directory.
///
/// Uses a kqueue file-system source rather than `NSMetadataQuery`: this only
/// needs "something changed here", the directory is re-read on each event, and
/// a Spotlight query would both cost more and miss folders that are not
/// indexed.
final class FolderWatcher: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "kr.lunibee.peninsula.folder-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var known: Set<String> = []

    /// Called on the main actor with each newly appeared file.
    private let onArrival: @MainActor (URL) -> Void

    /// Partial downloads land as these and then get renamed; announcing them
    /// would fire on every browser download twice.
    private static let ignoredExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "tmp",
    ]

    init(url: URL, onArrival: @escaping @MainActor (URL) -> Void) {
        self.url = url
        self.onArrival = onArrival
    }

    func start() {
        queue.async { [self] in
            guard source == nil else { return }

            descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                Log.shelf.error("cannot watch \(self.url.path, privacy: .private)")
                return
            }

            known = Self.contents(of: url)
            // A TCC denial reads as an empty directory rather than an error,
            // so the count is worth recording: zero items in a folder that is
            // obviously not empty means the app was denied access.
            Log.shelf.info(
                "watching \(self.url.lastPathComponent, privacy: .private): \(self.known.count) existing items"
            )

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { [weak self] in
                guard let self, self.descriptor >= 0 else { return }
                close(self.descriptor)
                self.descriptor = -1
            }
            source.resume()
            self.source = source
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            known.removeAll()
        }
    }

    private func scan() {
        let current = Self.contents(of: url)
        let arrivals = current.subtracting(known)
        known = current

        for name in arrivals {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !Self.ignoredExtensions.contains(ext), !name.hasPrefix(".") else { continue }

            Log.shelf.info("arrival: \(name, privacy: .private)")
            let file = url.appendingPathComponent(name)
            let handler = onArrival
            Task { @MainActor in handler(file) }
        }
    }

    private static func contents(of url: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return Set(names)
    }

    deinit {
        source?.cancel()
    }
}

extension URL {
    /// Where macOS is currently told to save screenshots. Falls back to the
    /// Desktop, which is the default when the preference has never been set.
    @MainActor
    static var screenshotLocation: URL {
        let desktop = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")

        guard
            let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
            !raw.isEmpty
        else { return desktop }

        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    @MainActor
    static var downloadsLocation: URL {
        FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }
}
