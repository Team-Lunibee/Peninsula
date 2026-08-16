import Foundation
import Observation

/// One timed line of an LRC file.
struct LyricLine: Equatable, Identifiable {
    let id = UUID()
    var time: TimeInterval
    var text: String
}

struct Lyrics: Equatable {
    var lines: [LyricLine]
    /// `false` when only unsynced lyrics were available, so the view can show
    /// them as a block rather than pretending to follow along.
    var isSynced: Bool

    /// Index of the line that should be highlighted at `time`.
    ///
    /// Binary search rather than a scan: this runs on every progress tick, and
    /// a long track can carry several hundred lines.
    func index(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty, isSynced else { return nil }
        guard time >= lines[0].time else { return nil }

        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].time <= time {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Parses the LRC timestamp format, `[mm:ss.xx] text`.
    ///
    /// A line can carry several timestamps when a refrain repeats, and blank
    /// text is kept: those gaps are what make a chorus land on time instead of
    /// leaving the previous line highlighted through an instrumental.
    static func parse(lrc: String) -> Lyrics? {
        var lines: [LyricLine] = []

        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = Substring(raw)
            var stamps: [TimeInterval] = []

            while remainder.hasPrefix("["),
                  let close = remainder.firstIndex(of: "]") {
                let body = remainder[remainder.index(after: remainder.startIndex)..<close]
                if let time = timestamp(from: body) {
                    stamps.append(time)
                }
                remainder = remainder[remainder.index(after: close)...]
                // A non-timestamp tag such as [ar:…] means the metadata header,
                // and everything after it on that line is not lyric text.
                if stamps.isEmpty { break }
            }

            guard !stamps.isEmpty else { continue }
            let text = remainder.trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(LyricLine(time: stamp, text: text))
            }
        }

        guard !lines.isEmpty else { return nil }
        lines.sort { $0.time < $1.time }
        return Lyrics(lines: lines, isSynced: true)
    }

    static func plain(_ text: String) -> Lyrics? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LyricLine(time: 0, text: String($0).trimmingCharacters(in: .whitespaces)) }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(lines: lines, isSynced: false)
    }

    private static func timestamp(from body: Substring) -> TimeInterval? {
        let parts = body.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return minutes * 60 + seconds
    }
}

/// Fetches synced lyrics for the current track.
///
/// Uses LRCLIB, which is public, needs no key, and is explicitly built for
/// exactly this — matching on title, artist, album and duration rather than on
/// a service-specific track id, so it works whatever the audio is playing in.
///
/// Results are cached in memory for the session; a track skipped back to should
/// not cost another request.
@MainActor
@Observable
final class LyricsService {
    private(set) var lyrics: Lyrics?
    private(set) var isLoading = false
    /// Set when a lookup completed and genuinely found nothing, so the UI can
    /// say so instead of spinning forever.
    private(set) var isUnavailable = false

    /// Bounded, because this grows by one entry per track played and a long
    /// listening session is thousands of tracks. Sheets are small individually
    /// and invisible in aggregate right up until they are not.
    private var cache: [String: Lyrics?] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 60

    private var task: Task<Void, Never>?
    private var currentKey: String?

    nonisolated private static let endpoint = URL(string: "https://lrclib.net/api/get")!

    /// Ephemeral, and explicitly stripped of ambient state.
    ///
    /// The shared session carries the process-wide cookie jar and credential
    /// store. Nothing here needs either, and a lyrics lookup has no business
    /// presenting whatever happens to be in them — this is a third-party server
    /// receiving what the user is listening to, and that should be all it
    /// receives.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func update(for track: NowPlaying?) {
        guard let track else {
            reset()
            return
        }

        let key = Self.key(for: track)
        guard key != currentKey else { return }
        currentKey = key

        task?.cancel()
        lyrics = nil
        isUnavailable = false

        if let cached = cache[key] {
            lyrics = cached
            isUnavailable = cached == nil
            return
        }

        isLoading = true
        task = Task { [weak self] in
            // Skipping through a playlist should not fire a lookup per track.
            // Waiting out a short quiet period means only the track actually
            // landed on is requested, instead of a burst of requests that are
            // cancelled a moment later.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            let found = await Self.fetch(track)
            guard !Task.isCancelled, let self, self.currentKey == key else { return }

            self.remember(found, for: key)
            self.lyrics = found
            self.isUnavailable = found == nil
            self.isLoading = false
        }
    }

    private func remember(_ lyrics: Lyrics?, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = lyrics

        while cacheOrder.count > Self.cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        currentKey = nil
        lyrics = nil
        isLoading = false
        isUnavailable = false
    }

    private static func key(for track: NowPlaying) -> String {
        [track.title, track.artist ?? "", track.album ?? ""].joined(separator: "\u{1}")
    }

    nonisolated private static func fetch(_ track: NowPlaying) async -> Lyrics? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var query = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist ?? ""),
        ]
        if let album = track.album {
            query.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = track.duration, duration > 0 {
            // LRCLIB matches on duration to disambiguate re-recordings and
            // radio edits; without it a live version can come back instead.
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = query

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // LRCLIB asks clients to identify themselves.
        request.setValue("Peninsula (macOS notch app)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            if let synced = object["syncedLyrics"] as? String,
               let parsed = Lyrics.parse(lrc: synced) {
                return parsed
            }
            if let plain = object["plainLyrics"] as? String {
                return Lyrics.plain(plain)
            }
            return nil
        } catch {
            Log.media.info("lyrics lookup failed: \(error.localizedDescription)")
            return nil
        }
    }
}
