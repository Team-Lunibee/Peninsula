import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns system events into notch banners.
///
/// Everything here is something that already happened somewhere else — a
/// charger went in, a download finished, a screenshot landed. The notch's job
/// is to say so once and get out of the way, which is what a Live Activity is
/// for and what a notification centre entry is bad at.
@MainActor
final class LiveActivityCenter {
    private let power = PowerMonitor()
    private var downloads: FolderWatcher?
    private var screenshots: FolderWatcher?

    private weak var model: NotchViewModel?
    private var preferences: Preferences { .shared }

    /// Batches files that land together — unzipping into Downloads should be
    /// one banner, not forty.
    private var pendingArrivals: [URL] = []
    private var arrivalFlush: Task<Void, Never>?

    var batteryPercentage: Int? { power.snapshot?.percentage }
    var isCharging: Bool { power.snapshot?.isCharging ?? false }
    var isPluggedIn: Bool { power.snapshot?.isPluggedIn ?? false }

    func start(model: NotchViewModel) {
        self.model = model

        power.onEvent = { [weak self] event in self?.announce(event) }
        power.start()

        guard preferences.fileActivitiesEnabled else { return }
        startWatchingFolders()
    }

    func stop() {
        arrivalFlush?.cancel()
        power.stop()
        downloads?.stop()
        screenshots?.stop()
        downloads = nil
        screenshots = nil
    }

    func setFileWatchingEnabled(_ enabled: Bool) {
        if enabled {
            startWatchingFolders()
        } else {
            downloads?.stop()
            screenshots?.stop()
            downloads = nil
            screenshots = nil
        }
    }

    private func startWatchingFolders() {
        guard downloads == nil else { return }

        let downloadsFolder = URL.downloadsLocation
        let screenshotFolder = URL.screenshotLocation

        downloads = FolderWatcher(url: downloadsFolder) { [weak self] url in
            self?.queueArrival(url)
        }
        downloads?.start()

        // Screenshots usually go to the Desktop, which is also where people
        // dump everything else — but a second watcher on the same folder would
        // double-report, so only add it when the two differ.
        if screenshotFolder.standardizedFileURL != downloadsFolder.standardizedFileURL {
            screenshots = FolderWatcher(url: screenshotFolder) { [weak self] url in
                self?.queueArrival(url)
            }
            screenshots?.start()
        }
    }

    // MARK: - Power

    private func announce(_ event: PowerMonitor.Event) {
        guard preferences.powerActivitiesEnabled else { return }

        // Shaped after the real island's charge banner: the words on the left,
        // the reading and a battery on the right, and nothing in between. No
        // leading badge — a tinted circle in front of "Charging" competes with the
        // battery it is describing — and no remaining-time subtitle, which
        // crowds the trailing region the percentage needs.
        let info: ActivityInfo = switch event {
        case .pluggedIn(let percentage):
            ActivityInfo(
                symbol: nil,
                tint: .green,
                title: String(localized: "Charging"),
                subtitle: nil,
                trailingValue: "\(percentage)%",
                level: Double(percentage) / 100
            )
        case .unplugged(let percentage):
            ActivityInfo(
                symbol: nil,
                tint: .white,
                title: String(localized: "On battery"),
                subtitle: remainingSubtitle,
                trailingValue: "\(percentage)%",
                level: Double(percentage) / 100
            )
        case .charged:
            ActivityInfo(
                symbol: nil,
                tint: .green,
                title: String(localized: "Fully charged"),
                subtitle: nil,
                trailingValue: "100%",
                level: 1
            )
        case .low(let percentage):
            ActivityInfo(
                symbol: nil,
                tint: .orange,
                title: String(localized: "Low battery"),
                subtitle: nil,
                trailingValue: "\(percentage)%",
                level: Double(percentage) / 100
            )
        }

        model?.present(.info(info))
    }

    private var remainingSubtitle: String? {
        guard let minutes = power.snapshot?.minutesRemaining else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0
            ? String(localized: "\(hours)h \(rest)m left")
            : String(localized: "\(rest)m left")
    }

    // MARK: - Files

    private func queueArrival(_ url: URL) {
        pendingArrivals.append(url)
        arrivalFlush?.cancel()
        arrivalFlush = Task { [weak self] in
            // Long enough that an archive expanding reads as one event, short
            // enough that the banner still feels immediate.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flushArrivals()
        }
    }

    private func flushArrivals() {
        let arrivals = pendingArrivals
        pendingArrivals.removeAll()
        guard !arrivals.isEmpty else { return }

        // AirDrop first: it is a download as far as the folder is concerned,
        // but it is not one as far as the person watching is concerned.
        let airDropped = arrivals.filter { FileOrigin.of($0) == .airDrop }
        if !airDropped.isEmpty {
            announceAirDrop(airDropped)
            let rest = arrivals.filter { !airDropped.contains($0) }
            guard !rest.isEmpty else { return }
            return announceDownload(rest)
        }

        announceDownload(arrivals)
    }

    /// Announces an AirDrop and, unless told otherwise, puts it on the shelf.
    ///
    /// Receiving is entirely macOS's affair — the file is already in Downloads
    /// by the time anything here runs. What the island can add is the part that
    /// is actually missing: knowing it arrived, and having it to hand instead of
    /// going to find it.
    private func announceAirDrop(_ urls: [URL]) {
        guard let first = urls.first else { return }

        let label = urls.count == 1
            ? first.lastPathComponent
            : String(localized: "\(first.lastPathComponent) and \(urls.count - 1) others")

        // The directory entry appears when the transfer *starts*, so this is
        // genuinely "receiving", not "received". Saying so is the whole value
        // the island can add here — macOS's own AirDrop UI is a notification
        // that has already scrolled away by the time a large file lands.
        model?.present(
            .info(ActivityInfo(
                symbol: "arrow.down.circle.dotted",
                tint: .blue,
                title: String(localized: "Receiving AirDrop"),
                subtitle: label,
                trailingValue: nil
            )),
            for: 30
        )

        Task { @MainActor [weak self] in
            var settled: [URL] = []
            for url in urls where await FileManager.default.waitUntilStable(url) {
                settled.append(url)
            }

            // Same banner, updated in place rather than staged behind the first
            // one — `present` absorbs an activity of the same kind.
            self?.model?.present(
                .info(ActivityInfo(
                    symbol: "airplayaudio",
                    tint: .blue,
                    title: settled.isEmpty
                        ? String(localized: "AirDrop transfer stopped")
                        : String(localized: "AirDrop received"),
                    subtitle: label,
                    trailingValue: nil
                )),
                for: 3.0
            )

            guard !settled.isEmpty else { return }
            guard let self, self.preferences.shelfEnabled, self.preferences.airDropToShelf
            else { return }
            self.onAirDropReceived?(settled)
        }
    }

    /// Wired to the controller, which owns the shelf.
    var onAirDropReceived: (([URL]) -> Void)?

    private func announceDownload(_ arrivals: [URL]) {
        guard let first = arrivals.first else { return }
        let isScreenshot = arrivals.allSatisfy(Self.looksLikeScreenshot)
        let info = ActivityInfo(
            symbol: isScreenshot ? "camera.viewfinder" : "arrow.down.circle.fill",
            tint: isScreenshot ? .purple : .cyan,
            title: isScreenshot
                ? String(localized: "Screenshot saved")
                : String(localized: "Download finished"),
            subtitle: arrivals.count == 1
                ? first.lastPathComponent
                : String(localized: "\(first.lastPathComponent) and \(arrivals.count - 1) others"),
            trailingValue: nil
        )

        model?.present(.info(info), for: 3.0)
    }

    /// macOS names screenshots with a prefix in *its own* language, not in the
    /// app's, so this has to match every language the system might be set to
    /// rather than the one Dynamic is currently displaying. The list below
    /// covers the languages this app ships in; anything else falls through and
    /// is announced as a download, which is wrong but harmless.
    ///
    /// The image dimensions matching a display would be the real giveaway, but
    /// that costs a decode per arriving file to correct a one-word label.
    private static let screenshotPrefixes = [
        "screenshot",       // en
        "스크린샷",           // ko
        "スクリーンショット",   // ja
        "截屏",              // zh-Hans
        "captura de pantalla", // es
        "capture d’écran",   // fr
        "capture d'écran",   // fr, straight apostrophe
        "bildschirmfoto",   // de
        "cleanshot",        // third-party, but common enough to be worth it
    ]

    private static func looksLikeScreenshot(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
        return isImage && screenshotPrefixes.contains { name.contains($0) }
    }
}
