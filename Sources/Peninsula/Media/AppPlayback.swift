import AppKit
import Observation

/// The playing app's own volume, shuffle and repeat, where it has them.
///
/// MediaRemote is the wrong place to ask for any of this. Volume it does not
/// carry at all — `kAudioHardwareServiceDeviceProperty` addresses the *output
/// device*, so moving it moves notification sounds with the music — and shuffle
/// and repeat it carries only when the player bothers to publish them, which
/// Music does not: asked directly it says shuffle is on and repeat is all, while
/// the same track's now-playing payload has neither key in it.
///
/// What some players do expose is themselves. Music and Spotify are scriptable,
/// and their `sound volume`, shuffle and repeat are readable *and* writable, so
/// a control built on them shows the truth and changes it.
///
/// A browser is not scriptable this way, and no API archaeology produces one:
/// whatever a tab is playing belongs to the browser's audio session and nothing
/// outside it can address a single tab. So YouTube falls back to the system
/// slider and to whatever MediaRemote happens to report, which is the honest
/// answer rather than a broken control.
@MainActor
@Observable
final class AppPlayback {
    static let shared = AppPlayback()

    enum RepeatMode: String {
        case off, one, all

        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }

        var label: String {
            switch self {
            case .off: String(localized: "Repeat")
            case .one: String(localized: "Repeating track")
            case .all: String(localized: "Repeating all")
            }
        }
    }

    /// 0 to 1, or `nil` when the current player has no volume of its own.
    private(set) var volume: Float?
    private(set) var isShuffling: Bool?
    private(set) var repeatMode: RepeatMode?
    private(set) var bundleIdentifier: String?

    /// Checked against a list rather than probed, because probing means running
    /// an AppleScript against every app that ever plays anything, and each first
    /// attempt puts up an automation permission prompt.
    private static let scriptable: Set<String> = [
        "com.apple.Music", "com.apple.iTunes", "com.spotify.client",
    ]

    private var pollTimer: Timer?
    private var pendingVolumeWrite: Task<Void, Never>?
    /// Nobody can see these controls unless the panel is open, and asking costs
    /// an Apple Event into another process.
    private var isVisible = false
    private var lastRead: Date?

    /// How long a reading stays good enough to reuse.
    ///
    /// Opening the panel used to re-read unconditionally, which is one Apple
    /// Event per open — fine for a person, ruinous for anything that opens it in
    /// a loop, and pointless either way: nothing changes these values between
    /// two glances a second apart except this app itself, which updates them
    /// optimistically anyway.
    private static let readLifetime: TimeInterval = 2.5

    var controlsVolume: Bool { volume != nil }

    // MARK: - Lifecycle

    /// Follows whatever is playing. Called when the source app changes.
    func track(bundleIdentifier: String?) {
        guard bundleIdentifier != self.bundleIdentifier else { return }
        self.bundleIdentifier = bundleIdentifier

        pollTimer?.invalidate()
        pollTimer = nil
        clearState()
        lastRead = nil

        guard let bundleIdentifier, Self.scriptable.contains(bundleIdentifier) else { return }
        refresh(force: true)
        startPollingIfNeeded()
    }

    /// Called as the panel opens and closes.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            refresh()
            startPollingIfNeeded()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func startPollingIfNeeded() {
        guard isVisible, pollTimer == nil, appName != nil else { return }
        // Slow on purpose: this is the fallback for someone changing something
        // inside the player itself, and every tick is an Apple Event.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingVolumeWrite?.cancel()
        clearState()
        bundleIdentifier = nil
    }

    private func clearState() {
        volume = nil
        isShuffling = nil
        repeatMode = nil
    }

    // MARK: - Writing

    func set(volume newVolume: Float) {
        guard let app = appName, volume != nil else { return }
        let clamped = min(1, max(0, newVolume))
        // Optimistic, so the slider tracks the finger rather than the round trip.
        volume = clamped

        // Coalesced: a drag produces a value per frame, and each one would
        // otherwise be an Apple Event into another process.
        pendingVolumeWrite?.cancel()
        pendingVolumeWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let value = self?.volume else { return }
            // Not cached: the level is baked into the source, so caching would
            // keep a compiled script — and the OSA component behind it — for
            // every distinct volume the slider ever passed through.
            Self.run(Self.volumeScript(app: app, value: Int((value * 100).rounded())), cache: false)
        }
    }

    func toggleShuffle() {
        guard let app = appName, let current = isShuffling else { return }
        isShuffling = !current
        Self.run(Self.shuffleScript(app: app, on: !current))
    }

    func cycleRepeat() {
        guard let app = appName, let current = repeatMode else { return }
        let next = current.next
        repeatMode = next
        Self.run(Self.repeatScript(app: app, mode: next))
    }

    // MARK: - Reading

    private var appName: String? {
        switch bundleIdentifier {
        case "com.apple.Music": "Music"
        case "com.apple.iTunes": "iTunes"
        case "com.spotify.client": "Spotify"
        default: nil
        }
    }

    private func refresh(force: Bool = false) {
        guard let app = appName else { return }
        if !force, let lastRead, Date().timeIntervalSince(lastRead) < Self.readLifetime {
            return
        }
        lastRead = Date()
        // Skipped while a write is in flight: the player reports the old value
        // until it has applied the new one, and reading it back would drag the
        // slider backwards under the finger.
        guard pendingVolumeWrite == nil || pendingVolumeWrite?.isCancelled == true else { return }

        Task { [weak self] in
            let raw = await Self.read(from: app, spotify: app == "Spotify")
            guard let self, self.appName == app, let raw else { return }
            guard self.pendingVolumeWrite == nil || self.pendingVolumeWrite?.isCancelled == true
            else { return }

            let fields = raw.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return }
            self.volume = Float(fields[0]).map { $0 / 100 }
            self.isShuffling = fields[1] == "true"
            self.repeatMode = RepeatMode(rawValue: String(fields[2]))
        }
    }

    // MARK: - AppleScript
    //
    // Every script is guarded by `is running`. `NSAppleScript` targeting an app
    // by name would otherwise *launch* it, and an app that starts because a
    // volume slider polled it is a bug with a long tail.

    private static func read(from app: String, spotify: Bool) async -> String? {
        // Spotify has no three-way repeat: `repeating` is a boolean, which maps
        // onto all-or-nothing.
        let body = spotify
            ? """
              set v to sound volume
              set s to shuffling
              set r to "off"
              if repeating then set r to "all"
              """
            : """
              set v to sound volume
              set s to shuffle enabled
              set r to (song repeat as text)
              """

        let source = """
        if application "\(app)" is not running then return ""
        tell application "\(app)"
            \(body)
        end tell
        return (v as text) & "|" & (s as text) & "|" & r
        """
        return await withCheckedContinuation { continuation in
            ScriptRunner.shared.run(source) { value in
                continuation.resume(returning: (value?.isEmpty ?? true) ? nil : value)
            }
        }
    }

    private static func volumeScript(app: String, value: Int) -> String {
        """
        if application "\(app)" is running then
            tell application "\(app)" to set sound volume to \(value)
        end if
        """
    }

    private static func shuffleScript(app: String, on: Bool) -> String {
        let property = app == "Spotify" ? "shuffling" : "shuffle enabled"
        return """
        if application "\(app)" is running then
            tell application "\(app)" to set \(property) to \(on)
        end if
        """
    }

    private static func repeatScript(app: String, mode: RepeatMode) -> String {
        if app == "Spotify" {
            return """
            if application "Spotify" is running then
                tell application "Spotify" to set repeating to \(mode == .off ? "false" : "true")
            end if
            """
        }
        return """
        if application "\(app)" is running then
            tell application "\(app)" to set song repeat to \(mode.rawValue)
        end if
        """
    }

    private static func run(_ source: String, cache: Bool = true) {
        ScriptRunner.shared.run(source, cache: cache) { _ in }
    }
}

/// Runs AppleScript on one serial queue, from a cache of compiled scripts.
///
/// `NSAppleScript` is expensive in a way that does not show up until it is used
/// in a loop: each instance compiles its source and holds an OSA component, and
/// building a fresh one per call — which is the obvious way to write this —
/// added 20MB of resident memory and four threads to an idle app. Compiling
/// once and reusing costs a dictionary lookup.
///
/// The queue is not an optimisation. `NSAppleScript` is documented as not
/// thread-safe, and executing the same instance from two tasks at once is a
/// crash waiting for a slow disk.
///
/// Caching is opt-out rather than automatic, because the cache is keyed on the
/// source text. That is right for the scripts whose text is fixed — the reader
/// on its timer, and the handful of shuffle and repeat variants — and wrong for
/// any script with a value interpolated into it, which would deposit a fresh
/// entry per distinct value and never drop one.
final class ScriptRunner: @unchecked Sendable {
    static let shared = ScriptRunner()

    private let queue = DispatchQueue(label: "kr.lunibee.peninsula.applescript")
    private var compiled: [String: NSAppleScript] = [:]

    func run(
        _ source: String,
        cache: Bool = true,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async { [self] in
            let script: NSAppleScript?
            if cache, let existing = compiled[source] {
                script = existing
            } else {
                script = NSAppleScript(source: source)
                if cache, let script { compiled[source] = script }
            }

            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error {
                Log.media.error("applescript failed: \(error, privacy: .public)")
                completion(nil)
                return
            }
            completion(result?.stringValue)
        }
    }
}
