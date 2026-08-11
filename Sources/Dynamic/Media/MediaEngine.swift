import AppKit
import Observation
import SwiftUI

/// Everything the notch knows about playback.
///
/// Owns the adapter bridge, keeps the decoded artwork and its accent colour in
/// sync with the current track, and exposes transport controls. Playback
/// position is deliberately *not* stored here — views extrapolate it from the
/// snapshot with a `TimelineView`, so there is no timer running when nothing is
/// on screen.
@MainActor
@Observable
final class MediaEngine {
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var accent: Color = .white
    private(set) var sourceIcon: NSImage?
    private(set) var sourceName: String?
    /// Set when the perl entitlement path stops working, so the UI can explain
    /// itself instead of silently showing nothing.
    private(set) var unavailableReason: String?

    /// Bumped on every track change so views can key transitions off it.
    private(set) var trackToken = 0

    let lyrics = LyricsService()

    /// True once playback has been stopped long enough that the notch should
    /// stop advertising it.
    ///
    /// A paused track stays in MediaRemote indefinitely — quit the player and
    /// it can still be the "now playing" item hours later. Without this the
    /// compact pill would be permanent, which defeats the whole point of a
    /// resting state that is indistinguishable from the cutout.
    private(set) var isDormant = true

    private var dormancyTask: Task<Void, Never>?

    private var bridge: MediaRemoteBridge?
    private var accumulator = NowPlayingAccumulator()
    private var loadedArtworkFingerprint: String?
    private var artworkTask: Task<Void, Never>?

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }
    var hasTrack: Bool { nowPlaying != nil }
    var isFavorite: Bool { nowPlaying?.isLiked ?? false }

    /// The adapter has no favourite command, so this rides on AppleScript and
    /// only Music.app answers it.
    var supportsFavorite: Bool {
        nowPlaying?.bundleIdentifier == "com.apple.Music"
    }

    func start() {
        guard bridge == nil else { return }
        guard let bridge = MediaRemoteBridge() else {
            unavailableReason = "번들에 미디어 어댑터가 없습니다."
            return
        }

        bridge.onPayload = { [weak self] payload, isDiff in
            self?.ingest(payload: payload, isDiff: isDiff)
        }
        bridge.onUnavailable = { [weak self] reason in
            self?.unavailableReason = reason
            self?.clear()
        }

        self.bridge = bridge
        bridge.start()

        Task {
            // A failing probe means a macOS update closed the perl hole; say so
            // rather than looking broken.
            if await bridge.probe() == false {
                self.unavailableReason = "이 macOS 버전에서 재생 정보 접근이 차단되어 있습니다."
            }
        }
    }

    func stop() {
        dormancyTask?.cancel()
        isDormant = true
        bridge?.stop()
        bridge = nil
        artworkTask?.cancel()
        clear()
    }

    // MARK: - Ingest

    /// Test seam for `Bench`: pushes a synthetic payload through the real
    /// ingest path so profiling sees the panel a real track produces.
    func ingestForBench(_ payload: [String: Any]) {
        ingest(payload: payload, isDiff: false)
    }

    private func ingest(payload: [String: Any], isDiff: Bool) {
        accumulator.apply(payload: payload, isDiff: isDiff)
        unavailableReason = nil

        guard let snapshot = accumulator.snapshot() else {
            clear()
            return
        }

        let previous = nowPlaying
        nowPlaying = snapshot

        let trackChanged = previous?.title != snapshot.title
            || previous?.artist != snapshot.artist
            || previous?.bundleIdentifier != snapshot.bundleIdentifier
        if trackChanged {
            trackToken &+= 1
            if Preferences.shared.lyricsEnabled {
                lyrics.update(for: snapshot)
            } else {
                lyrics.reset()
            }
        }

        if previous?.bundleIdentifier != snapshot.bundleIdentifier {
            updateSource(bundleIdentifier: snapshot.bundleIdentifier)
        }

        updateDormancy(isPlaying: snapshot.isPlaying)

        if snapshot.artworkFingerprint != loadedArtworkFingerprint {
            loadArtwork(fingerprint: snapshot.artworkFingerprint, base64: accumulator.artworkBase64)
            // Once decoded there is no reason to keep several hundred kilobytes
            // of base64 alive; the fingerprint is what tells us whether the next
            // payload carries something new.
            accumulator.dropArtworkPayload()
        }
    }

    /// Playing wakes it immediately; stopping starts a countdown rather than
    /// vanishing at once, so pausing to answer the door does not make the
    /// island disappear and reappear.
    private func updateDormancy(isPlaying: Bool) {
        dormancyTask?.cancel()
        dormancyTask = nil

        if isPlaying {
            isDormant = false
            return
        }

        let timeout = Preferences.shared.mediaIdleTimeout
        guard timeout > 0 else { return }

        dormancyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            self.isDormant = true
        }
    }

    private func clear() {
        dormancyTask?.cancel()
        dormancyTask = nil
        isDormant = true
        guard nowPlaying != nil || artwork != nil else { return }
        accumulator.reset()
        nowPlaying = nil
        artwork = nil
        accent = .white
        sourceIcon = nil
        sourceName = nil
        loadedArtworkFingerprint = nil
        artworkTask?.cancel()
        artworkTask = nil
        lyrics.reset()
    }

    private func updateSource(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            sourceIcon = nil
            sourceName = nil
            return
        }
        sourceIcon = NSWorkspace.shared.icon(forFile: url.path)
        sourceName = FileManager.default.displayName(atPath: url.path)
    }

    private func loadArtwork(fingerprint: String?, base64: String?) {
        artworkTask?.cancel()
        loadedArtworkFingerprint = fingerprint

        guard let base64, !base64.isEmpty else {
            artwork = nil
            accent = .white
            return
        }

        artworkTask = Task { [weak self] in
            // Decoding a few hundred kilobytes of JPEG plus the palette pass is
            // far too much to do on the main actor between animation frames.
            let decoded: (NSImage, NSColor?)? = await Task.detached(priority: .userInitiated) {
                guard let image = ArtworkDecoder.decode(base64: base64) else { return nil }
                return (image, ArtworkPalette.accent(for: image))
            }.value

            guard !Task.isCancelled, let self else { return }
            guard let decoded else {
                self.artwork = nil
                self.accent = .white
                return
            }

            self.artwork = decoded.0
            self.accent = decoded.1.map { Color(nsColor: $0) } ?? .white
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        Haptics.tap()
        bridge?.send(.togglePlayPause)
        // Optimistic flip: the adapter round-trip is ~100ms and a button that
        // waits for it feels broken.
        nowPlaying?.isPlaying.toggle()
    }

    func nextTrack() {
        Haptics.tap()
        bridge?.send(.nextTrack)
    }

    func previousTrack() {
        Haptics.tap()
        bridge?.send(.previousTrack)
    }

    func seek(toFraction fraction: Double) {
        guard let duration = nowPlaying?.duration, duration > 0 else { return }
        let target = duration * min(1, max(0, fraction))
        bridge?.seek(toSeconds: target)

        // Re-anchor locally so the scrubber does not snap back while the player
        // catches up.
        nowPlaying?.elapsedMicros = Int64(target * 1_000_000)
        nowPlaying?.timestampEpochMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    func toggleFavorite() {
        guard supportsFavorite, let track = nowPlaying else { return }
        Haptics.tap()

        let next = !(track.isLiked ?? false)
        nowPlaying?.isLiked = next

        let script = """
        tell application "Music"
            try
                set favorited of current track to \(next)
            end try
        end tell
        """
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                Log.media.error("favourite failed: \(error, privacy: .public)")
            }
        }
    }

    func toggleShuffle() {
        Haptics.tap()
        bridge?.send(.toggleShuffle)
    }

    func toggleRepeat() {
        Haptics.tap()
        bridge?.send(.toggleRepeat)
    }
}
