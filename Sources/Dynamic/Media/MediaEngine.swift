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
    /// Which track the image in `artwork` actually belongs to.
    ///
    /// Distinct from `loadedArtworkFingerprint`, which is set when a decode is
    /// *started*. Between the two the property still holds the previous track's
    /// cover, and anything judging the new track by it judges the wrong image.
    private var shownArtworkFingerprint: String?
    private var artworkTask: Task<Void, Never>?

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }
    var hasTrack: Bool { nowPlaying != nil }
    var isFavorite: Bool { nowPlaying?.isLiked ?? false }

    /// The adapter has no favourite command, so this rides on AppleScript and
    /// only Music.app answers it.
    var supportsFavorite: Bool {
        nowPlaying?.bundleIdentifier == "com.apple.Music"
    }

    /// The scriptable player first, MediaRemote second.
    ///
    /// Music publishes neither of these in its now-playing payload — asked
    /// directly it will say shuffle is on and repeat is all, while the payload
    /// for the same track carries no such key. So the app itself is the better
    /// source where it can be asked, and the payload is the fallback for
    /// everything else. `nil` means nobody will say, and a control whose state
    /// cannot be read should not be drawn at all rather than drawn guessing.
    var isShuffling: Bool? {
        AppPlayback.shared.isShuffling ?? nowPlaying?.shuffleMode.map { $0 > 1 }
    }

    var repeatState: AppPlayback.RepeatMode? {
        if let mode = AppPlayback.shared.repeatMode { return mode }
        switch nowPlaying?.repeatMode {
        case 1: return .off
        case 2: return .one
        case 3: return .all
        default: return nil
        }
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

        // A stopped player still streams.
        //
        // The adapter keeps sending while nothing is playing — the same payload,
        // over and over — and every one of them used to run this whole function:
        // rebuild the snapshot, re-fingerprint the artwork, re-publish an
        // observable property that had not changed, and wake every SwiftUI view
        // reading it. Measured at half a percent of a core with the notch empty
        // and no music on. An identical snapshot has nothing to say.
        guard snapshot != nowPlaying else { return }

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
            AppPlayback.shared.track(bundleIdentifier: snapshot.bundleIdentifier)
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
        AppPlayback.shared.stop()
        loadedArtworkFingerprint = nil
        shownArtworkFingerprint = nil
        artworkTask?.cancel()
        artworkTask = nil
        lyrics.reset()
    }

    /// Cached because the lookup is three trips to Launch Services and the disk
    /// for an answer that cannot change while the app is running, and because a
    /// player that flickers in and out of "nothing playing" asks for the same
    /// one repeatedly.
    /// Whether what is playing is music rather than a video.
    ///
    /// There is no single field that says so. MediaRemote carries a media type,
    /// and Music fills it in — but a browser sets none of it, and a browser is
    /// where the question actually matters: scrolling Shorts is a track change
    /// every couple of seconds as far as the system is concerned, and the island
    /// announcing each one is the reason this exists.
    ///
    /// So it is decided from what a music player fills in and a video does not,
    /// in descending order of how much the source is telling us about itself:
    ///
    ///     Music.app     isMusicApp=true   mediaType=…Music   album="STEREOTYPE - EP"   artwork 600x600
    ///     YouTube       isMusicApp=nil    mediaType=nil      album=""                  artwork 150x83
    ///     YouTube Short  same, 49s
    ///
    /// The artwork is the last word and the most telling: cover art is square
    /// and a video thumbnail is 16:9. It comes in last, though — the image is
    /// decoded off the main actor — so the cheaper fields are asked first and
    /// this only settles the cases they cannot.
    ///
    /// Anything unrecognised is treated as video, which is the safe direction:
    /// the cost of being wrong is a banner that does not appear, against one
    /// that interrupts.
    var looksLikeMusic: Bool {
        guard let track = nowPlaying else { return false }
        if track.isMusicApp == true { return true }
        if let type = track.mediaType,
           type.localizedCaseInsensitiveContains("music")
            || type.localizedCaseInsensitiveContains("audio") {
            return true
        }
        // A browser leaves the album empty whatever is in the tab.
        if track.album != nil { return true }
        // Only when the image on hand is this track's. Artwork is decoded off
        // the main actor and lands a moment after the metadata, so at the
        // instant a track changes `artwork` still holds the *previous* one —
        // and going from an album to a video would be judged on the album's
        // square cover and announced as music.
        if track.artworkFingerprint == shownArtworkFingerprint,
           let artwork, artwork.size.width > 0, artwork.size.height > 0 {
            return abs(artwork.size.width / artwork.size.height - 1) < 0.12
        }
        return false
    }

    private var sourceCache: [String: (icon: NSImage?, name: String?)] = [:]

    private func updateSource(bundleIdentifier: String) {
        if let cached = sourceCache[bundleIdentifier] {
            sourceIcon = cached.icon
            sourceName = cached.name
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            sourceCache[bundleIdentifier] = (nil, nil)
            sourceIcon = nil
            sourceName = nil
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let name = FileManager.default.displayName(atPath: url.path)
        sourceCache[bundleIdentifier] = (icon, name)
        sourceIcon = icon
        sourceName = name
    }

    private func loadArtwork(fingerprint: String?, base64: String?) {
        artworkTask?.cancel()
        loadedArtworkFingerprint = fingerprint

        guard let base64, !base64.isEmpty else {
            artwork = nil
            shownArtworkFingerprint = nil
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
                self.shownArtworkFingerprint = nil
                self.accent = .white
                return
            }

            self.artwork = decoded.0
            self.shownArtworkFingerprint = fingerprint
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
        // Scripting the player is both readable and precise; the remote command
        // is a blind toggle, which is all there is for anything else.
        if AppPlayback.shared.isShuffling != nil {
            AppPlayback.shared.toggleShuffle()
        } else {
            bridge?.send(.toggleShuffle)
        }
    }

    func toggleRepeat() {
        Haptics.tap()
        if AppPlayback.shared.repeatMode != nil {
            AppPlayback.shared.cycleRepeat()
        } else {
            bridge?.send(.toggleRepeat)
        }
    }
}
