import Foundation
import os

/// Talks to MediaRemote through the vendored perl adapter.
///
/// Since macOS 15.4 `mediaremoted` only answers clients carrying an Apple
/// entitlement, so a normal third-party process gets nothing back. The adapter
/// works around that by running the system perl binary — which reports the
/// bundle identifier `com.apple.perl5` and is therefore entitled — and having
/// it `dlopen` a small helper framework that prints now-playing JSON to stdout.
///
/// Everything here is therefore process management: keep a `stream` running,
/// parse its line-delimited JSON, and fire one-shot invocations for commands.
/// All mutable state is confined to `queue`, a serial dispatch queue, so the
/// type is safe to hand across isolation boundaries even though the compiler
/// cannot prove it.
final class MediaRemoteBridge: @unchecked Sendable {
    struct Paths {
        var perl = URL(fileURLWithPath: "/usr/bin/perl")
        var script: URL
        var framework: URL

        /// Looks in the app bundle first, then the SwiftPM build directory so
        /// `swift run` works without assembling a bundle.
        static func locate() -> Paths? {
            var candidates: [URL] = []
            if let resources = Bundle.main.resourceURL {
                candidates.append(resources)
            }
            candidates.append(
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()   // Media
                    .deletingLastPathComponent()   // Dynamic
                    .deletingLastPathComponent()   // Sources
                    .deletingLastPathComponent()   // package root
                    .appendingPathComponent(".build/mediaremote-adapter")
            )

            for directory in candidates {
                let script = directory.appendingPathComponent("mediaremote-adapter.pl")
                let framework = directory.appendingPathComponent("MediaRemoteAdapter.framework")
                if FileManager.default.fileExists(atPath: script.path),
                   FileManager.default.fileExists(atPath: framework.path) {
                    return Paths(script: script, framework: framework)
                }
            }
            return nil
        }
    }

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
        case toggleShuffle = 6
        case toggleRepeat = 7
    }

    /// Called on the main actor for every payload the stream emits.
    var onPayload: (@MainActor ([String: Any], Bool) -> Void)?
    /// Called on the main actor when the stream dies and cannot be restarted.
    var onUnavailable: (@MainActor (String) -> Void)?

    private let paths: Paths
    private var process: Process?
    private var buffer = Data()
    private var restartAttempts = 0
    private var isStopping = false
    private let queue = DispatchQueue(label: "dev.anbam.Dynamic.media-remote")

    private static let maxRestartAttempts = 5
    /// The adapter can emit bursts while a player loads a track; coalescing
    /// them keeps SwiftUI from re-rendering several times per track change.
    private static let debounceMilliseconds = 120

    init?() {
        guard let paths = Paths.locate() else {
            Log.media.error("mediaremote-adapter is missing from the bundle")
            return nil
        }
        self.paths = paths
    }

    // MARK: - Streaming

    func start() {
        queue.async { [self] in
            isStopping = false
            restartAttempts = 0
            launchStream()
        }
    }

    /// Synchronous on purpose: this runs during termination, and an async hop
    /// would let the process exit before the child ever receives its SIGTERM.
    func stop() {
        queue.sync { [self] in
            isStopping = true
            process?.terminate()
            process = nil
            buffer.removeAll()
        }
    }

    private func launchStream() {
        guard process == nil else { return }

        // A hard kill of the app (crash, `pkill`, Force Quit) leaves the perl
        // child orphaned and still streaming, and those accumulate across
        // launches. Sweep any stragglers before starting a fresh one — safe
        // here because our own stream does not exist yet.
        reapOrphanedStreams()

        let task = Process()
        task.executableURL = paths.perl
        task.arguments = [
            paths.script.path,
            paths.framework.path,
            "stream",
            "--micros",
            "--debounce=\(Self.debounceMilliseconds)",
        ]

        let output = Pipe()
        task.standardOutput = output
        // An undrained pipe fills after ~64KB and blocks the child forever, so
        // stderr goes to /dev/null rather than a Pipe nobody reads.
        task.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.consume(chunk) }
        }

        task.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.handleTermination(of: finished) }
        }

        do {
            try task.run()
            process = task
            Log.media.info("media stream started (pid \(task.processIdentifier))")
        } catch {
            Log.media.error("failed to start media stream: \(error.localizedDescription)")
            reportUnavailable(String(localized: "Could not start the media adapter."))
        }
    }

    private func handleTermination(of finished: Process) {
        guard process === finished else { return }
        process = nil
        (finished.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        buffer.removeAll()

        guard !isStopping else { return }

        restartAttempts += 1
        guard restartAttempts <= Self.maxRestartAttempts else {
            Log.media.error("media stream keeps dying; giving up")
            reportUnavailable(String(localized: "The media adapter is not responding."))
            return
        }

        let delay = pow(2.0, Double(restartAttempts - 1)) * 0.5
        Log.media.warning("media stream exited; retry \(self.restartAttempts) in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.launchStream()
        }
    }

    /// The adapter writes one JSON object per line, but a read can land
    /// mid-line — artwork payloads are far larger than a pipe buffer — so
    /// partial data is held until the newline arrives.
    private func consume(_ chunk: Data) {
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            decode(Data(line))
        }
    }

    private func decode(_ line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "data",
            let payload = object["payload"] as? [String: Any]
        else { return }

        // A successful line means the adapter is healthy again.
        restartAttempts = 0

        let isDiff = object["diff"] as? Bool ?? false
        let handler = onPayload
        Task { @MainActor in handler?(payload, isDiff) }
    }

    /// Kills any perl process still running our adapter script.
    ///
    /// The pattern is escaped before it goes anywhere near `pkill`, which
    /// matches it as an *extended regular expression* against the full command
    /// line of every process on the system. An unescaped path is usually
    /// harmless — `.` matching any character changes nothing in practice — but
    /// the app's location is not ours to choose. A bundle sitting under a
    /// directory containing `+`, `*`, `(` or `[` turns this into a pattern that
    /// can match, and therefore kill, processes that have nothing to do with
    /// us. Escaping costs one line; the failure mode is killing the user's
    /// work.
    private func reapOrphanedStreams() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", Self.escapedForRegex(paths.script.path)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            Log.media.info("reaped an orphaned adapter stream from a previous run")
        }
    }

    private static func escapedForRegex(_ value: String) -> String {
        let metacharacters = Set(#"\^$.|?*+()[]{}"#)
        return String(value.flatMap { character -> [Character] in
            metacharacters.contains(character) ? ["\\", character] : [character]
        })
    }

    private func reportUnavailable(_ message: String) {
        let handler = onUnavailable
        Task { @MainActor in handler?(message) }
    }

    // MARK: - One-shot invocations

    func send(_ command: Command) {
        run(["send", String(command.rawValue)])
    }

    func seek(toSeconds seconds: TimeInterval) {
        let micros = Int64(max(0, seconds) * 1_000_000)
        run(["seek", String(micros)])
    }

    func setShuffle(_ mode: Int) {
        run(["shuffle", String(mode)])
    }

    func setRepeat(_ mode: Int) {
        run(["repeat", String(mode)])
    }

    /// Verifies the perl entitlement trick still works on this macOS build.
    /// A non-zero exit means a system update closed the hole.
    ///
    /// Deliberately does not touch `queue` and never blocks a thread waiting:
    /// `get` emits the full artwork payload, so waiting on it while holding the
    /// serial queue would stall the stream parser behind a child that is itself
    /// blocked writing into a pipe nobody is draining.
    func probe() async -> Bool {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = paths.perl
            task.arguments = [paths.script.path, paths.framework.path, "get"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            let resumed = OSAllocatedUnfairLock(initialState: false)
            task.terminationHandler = { finished in
                let alreadyResumed = resumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                guard !alreadyResumed else { return }
                continuation.resume(returning: finished.terminationStatus == 0)
            }

            do {
                try task.run()
            } catch {
                let alreadyResumed = resumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                if !alreadyResumed {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func run(_ arguments: [String]) {
        queue.async { [self] in
            let task = Process()
            task.executableURL = paths.perl
            task.arguments = [paths.script.path, paths.framework.path] + arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                Log.media.error("adapter command \(arguments.first ?? "?") failed: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        process?.terminate()
    }
}
