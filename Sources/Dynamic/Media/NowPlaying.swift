import Foundation

/// A typed view over the adapter's now-playing payload.
struct NowPlaying: Equatable {
    var bundleIdentifier: String
    var title: String
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var playbackRate: Double

    var durationMicros: Int64?
    var elapsedMicros: Int64?
    var timestampEpochMicros: Int64?

    var isLiked: Bool?
    var supportsIsLiked: Bool
    var shuffleMode: Int?
    var repeatMode: Int?

    /// Identity of the currently loaded artwork, used to avoid re-decoding the
    /// same several-hundred-kilobyte JPEG on every update.
    var artworkFingerprint: String?

    var duration: TimeInterval? {
        durationMicros.map { TimeInterval($0) / 1_000_000 }
    }

    /// Playback position extrapolated from the last reported sample.
    ///
    /// The adapter reports `elapsedTime` as of `timestamp`, so a smooth
    /// progress bar comes from advancing that sample locally instead of
    /// polling the media player many times a second.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let elapsedMicros else { return 0 }
        let base = TimeInterval(elapsedMicros) / 1_000_000
        guard isPlaying, let timestampEpochMicros else { return base }

        let sampledAt = TimeInterval(timestampEpochMicros) / 1_000_000
        let drift = max(0, date.timeIntervalSince1970 - sampledAt)
        let rate = playbackRate > 0 ? playbackRate : 1
        let projected = base + drift * rate

        if let duration, duration > 0 {
            return min(projected, duration)
        }
        return projected
    }

    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, elapsed() / duration))
    }
}

/// Accumulates the adapter's diff stream into a complete payload.
///
/// `stream` sends a full snapshot first and then partial updates where a
/// vanished key arrives as `null`, so the merge has to distinguish "unchanged"
/// from "explicitly cleared".
struct NowPlayingAccumulator {
    private(set) var raw: [String: Any] = [:]

    /// Survives `dropArtworkPayload`.
    ///
    /// The fingerprint is the only thing that says "this is the artwork you
    /// already decoded". Releasing the bytes without keeping it makes every
    /// subsequent payload look like it carries *new* artwork of `nil`, and the
    /// cover vanishes a fraction of a second after it appears.
    private var retainedArtworkFingerprint: String?

    mutating func apply(payload: [String: Any], isDiff: Bool) {
        guard isDiff else {
            raw = payload.filter { !($0.value is NSNull) }
            retainedArtworkFingerprint = nil
            return
        }
        for (key, value) in payload {
            if value is NSNull {
                raw.removeValue(forKey: key)
                if key == "artworkData" { retainedArtworkFingerprint = nil }
            } else {
                raw[key] = value
                if key == "artworkData" { retainedArtworkFingerprint = nil }
            }
        }
    }

    mutating func reset() {
        raw.removeAll()
        retainedArtworkFingerprint = nil
    }

    /// `nil` when the payload lacks the keys the adapter guarantees for valid
    /// media (bundle identifier, title, playing), i.e. nothing is playing.
    func snapshot() -> NowPlaying? {
        guard
            let bundleIdentifier = raw["bundleIdentifier"] as? String,
            let title = raw["title"] as? String,
            !title.isEmpty
        else { return nil }

        let artworkData = raw["artworkData"] as? String

        return NowPlaying(
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: (raw["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (raw["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isPlaying: raw["playing"] as? Bool ?? false,
            playbackRate: raw["playbackRate"] as? Double ?? 1,
            durationMicros: Self.int64(raw["durationMicros"]),
            elapsedMicros: Self.int64(raw["elapsedTimeMicros"]),
            timestampEpochMicros: Self.int64(raw["timestampEpochMicros"]),
            isLiked: raw["isLiked"] as? Bool,
            supportsIsLiked: raw["supportsIsLiked"] as? Bool ?? false,
            shuffleMode: Self.int64(raw["shuffleMode"]).map(Int.init),
            repeatMode: Self.int64(raw["repeatMode"]).map(Int.init),
            artworkFingerprint: Self.fingerprint(of: artworkData) ?? retainedArtworkFingerprint
        )
    }

    var artworkBase64: String? {
        raw["artworkData"] as? String
    }

    /// Releases the encoded artwork after it has been decoded.
    ///
    /// The fingerprint is derived from the string's length and its ends, so a
    /// later diff that re-sends the same artwork is still recognised as
    /// unchanged — but a diff that *replaces* it arrives with a new string
    /// anyway. Nothing needs the old bytes.
    mutating func dropArtworkPayload() {
        guard let data = raw["artworkData"] as? String else { return }
        retainedArtworkFingerprint = Self.fingerprint(of: data)
        raw.removeValue(forKey: "artworkData")
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    /// Cheap content identity: base64 length plus a sample of its head and
    /// tail. Hashing hundreds of kilobytes on every update would cost more than
    /// the decode it is meant to avoid.
    private static func fingerprint(of base64: String?) -> String? {
        guard let base64, !base64.isEmpty else { return nil }
        let head = base64.prefix(48)
        let tail = base64.suffix(16)
        return "\(base64.count)-\(head)-\(tail)"
    }
}
