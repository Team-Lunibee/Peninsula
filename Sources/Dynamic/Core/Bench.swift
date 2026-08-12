import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Drives the notch through real transitions so cost can be measured from
/// outside with `top`/`footprint`.
///
/// Off unless `DYNAMIC_BENCH` is set, and never referenced from the UI — the
/// point is to exercise exactly the code path a hover does, not a special one.
@MainActor
enum Bench {
    /// stderr, unbuffered — stdout is block-buffered when redirected to a file,
    /// so `print` output only appears when the process exits.
    private static func note(_ message: String) {
        fputs(message + "\n", stderr)
    }

    static func startIfRequested(model: NotchViewModel) {
        guard let mode = ProcessInfo.processInfo.environment["DYNAMIC_BENCH"] else { return }

        let cycles = ProcessInfo.processInfo.environment["DYNAMIC_BENCH_CYCLES"]
            .flatMap(Int.init) ?? 40

        if ProcessInfo.processInfo.environment["DYNAMIC_BENCH_TRACK"] != nil {
            injectTrack(into: model.media)
        }

        switch mode {
        case "transitions": run(model: model, cycles: cycles, dwell: 0.9)
        case "tracks": runTrackStorm(model: model)
        case "settings": runSettingsCycle()
        case "hud": runHUDProbe(model: model)
        case "watch":
            Task { @MainActor in
                for tick in 0..<40 {
                    note("watch[\(tick)] \(String(describing: model.presentation))")
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        case "modes":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                @MainActor func state() -> String {
                    let shuffle = String(describing: model.media.isShuffling)
                    let repeating = String(describing: model.media.repeatState)
                    return "shuffle=\(shuffle) repeat=\(repeating)"
                }
                note("modes before: \(state())")
                model.media.toggleShuffle()
                model.media.toggleRepeat()
                try? await Task.sleep(for: .seconds(6))
                note("modes after toggle: \(state())")
                model.media.toggleShuffle()
                model.media.toggleRepeat()
                model.media.toggleRepeat()
                try? await Task.sleep(for: .seconds(6))
                note("modes restored: \(state())")
            }
        case "charge":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for (title, tint, pct) in [
                    ("충전 중", Color.green, 100),
                    ("충전 중", Color.green, 62),
                    ("배터리 부족", Color.orange, 18),
                ] {
                    model.present(.info(ActivityInfo(
                        symbol: nil, tint: tint, title: title,
                        subtitle: nil, trailingValue: "\(pct)%",
                        level: Double(pct) / 100
                    )), for: 60)
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        case "hover":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let screen = NSScreen.main else { return }
                let origin = NSEvent.mouseLocation
                let flip = { (p: CGPoint) in CGPoint(x: p.x, y: screen.frame.maxY - p.y) }

                // Onto the notch.
                CGWarpMouseCursorPosition(flip(CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)))
                for tick in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(120))
                    note("hover-in[\(tick)] \(String(describing: model.presentation)) at \(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
                }

                // Away again.
                CGWarpMouseCursorPosition(flip(CGPoint(x: screen.frame.midX, y: screen.frame.midY)))
                for tick in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(120))
                    note("hover-out[\(tick)] \(String(describing: model.presentation))")
                }
                CGWarpMouseCursorPosition(flip(origin))
                note("hover: pointer restored")
            }
        // Held open against the pointer monitors, which would otherwise close
        // it the moment the cursor is anywhere else.
        case "hold":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                while !Task.isCancelled {
                    model.expand()
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        case "peek":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                model.present(.trackChanged, for: 600)
            }
        default: break
        }
    }

    /// A synthetic now-playing snapshot, so the full media panel is on screen
    /// while the transitions are profiled. Measuring the empty-state placeholder
    /// would flatter every number.
    private static func injectTrack(into media: MediaEngine) {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        media.ingestForBench([
            "bundleIdentifier": ProcessInfo.processInfo.environment["DYNAMIC_BENCH_BUNDLE"] ?? "com.apple.Music",
            "title": ProcessInfo.processInfo.environment["DYNAMIC_SHORT_TITLE"] == nil ? "Bench Track With A Deliberately Long Title" : "Short",
            "artist": "Benchmark Artist",
            "album": "Benchmark Album",
            "playing": true,
            "playbackRate": 1.0,
            "durationMicros": 213_000_000,
            "elapsedTimeMicros": 41_000_000,
            "timestampEpochMicros": now,
            "shuffleMode": ProcessInfo.processInfo.environment["DYNAMIC_BENCH_NOMODES"] == nil ? 3 : NSNull(),
            "repeatMode": ProcessInfo.processInfo.environment["DYNAMIC_BENCH_NOMODES"] == nil ? 3 : NSNull(),
            "artworkData": artworkBase64(),
        ])
    }

    /// Built with CoreGraphics rather than `NSImage.lockFocus`, which would
    /// materialise a Retina-backed rep plus a TIFF plus a bitmap rep — around
    /// 100MB of transient allocation that then shows up in
    /// `phys_footprint_peak` and gets mistaken for the app's own cost.
    private static func artworkBase64() -> String {
        let edge = 512
        guard let context = CGContext(
            data: nil,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: edge * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "" }

        let colours = [
            CGColor(red: 0.95, green: 0.25, blue: 0.45, alpha: 1),
            CGColor(red: 0.35, green: 0.25, blue: 0.85, alpha: 1),
            CGColor(red: 0.20, green: 0.80, blue: 0.80, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.5, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: edge, y: edge),
                options: []
            )
        }

        guard let image = context.makeImage() else { return "" }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return "" }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return "" }

        return (data as Data).base64EncodedString()
    }

    private static func run(model: NotchViewModel, cycles: Int, dwell: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            note("bench: transitions begin (\(cycles) cycles)")
            for index in 0..<cycles {
                model.expand()
                try? await Task.sleep(for: .seconds(dwell))
                model.collapse()
                try? await Task.sleep(for: .seconds(dwell))
                if index % 10 == 9 { note("bench: cycle \(index + 1)") }
            }
            note("bench: transitions end")
        }
    }

    /// Puts a HUD banner up and then jogs the pointer, which used to retract it
    /// instantly. The cursor is put back where it was found.
    private static func runHUDProbe(model: NotchViewModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let origin = NSEvent.mouseLocation
            note("hud: banner up, pointer at \(Int(origin.x)),\(Int(origin.y))")

            model.presentLevel(HUDInfo(symbol: "speaker.wave.2.fill", value: 0.6, tint: .white))

            guard let screen = NSScreen.main else { return }
            let flipped = { (point: CGPoint) in
                CGPoint(x: point.x, y: screen.frame.maxY - point.y)
            }

            for step in 0..<8 {
                try? await Task.sleep(for: .milliseconds(150))
                // Deliberately far from the notch: that is the movement that
                // used to count as "the pointer left, close it".
                let target = CGPoint(
                    x: screen.frame.midX + CGFloat(step) * 12,
                    y: screen.frame.midY
                )
                CGWarpMouseCursorPosition(flipped(target))
                note("hud[\(step)] presentation=\(String(describing: model.presentation))")
            }

            CGWarpMouseCursorPosition(flipped(origin))
            note("hud: pointer restored")
        }
    }

    /// Opens the settings window, walks every tab, closes it. Footprint is read
    /// from outside at the marked seconds.
    private static func runSettingsCycle() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            SettingsWindow.show()
            try? await Task.sleep(for: .seconds(1))
            NSApp.windows.first { $0.title == "Dynamic" }?.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(7))
            let settings = NSApp.windows.first { $0.title == "Dynamic" }
            note("bench: closing settings window (found: \(settings != nil))")
            settings?.close()
            try? await Task.sleep(for: .seconds(2))
            note("bench: settings retained after close: \(SettingsWindow.isOpen)")
        }
    }

    /// Logs the animated state every 1/60s as CSV.
    ///
    /// The point is to catch discontinuities: a value that moves further in one
    /// frame than any spring could is a snap, and a snap is what a stack of
    /// interrupted animations looks like from the outside.
    private static func sampleTrace(model: NotchViewModel, seconds: Double) {
        Task { @MainActor in
            note("TRACE,frame,presentation,width,squash")
            let frames = Int(seconds * 60)
            for frame in 0..<frames {
                note(String(
                    format: "TRACE,%d,%@,%.2f,%.4f",
                    frame,
                    String(describing: model.presentation),
                    model.contentSize.width,
                    model.squash
                ))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Track changes arriving faster than the banner can settle.
    ///
    /// Driven through the real ingest path rather than by calling `present`
    /// directly, so the lyric lookup, the artwork decode and the controller's
    /// change observer all run the way they do when someone holds the skip key.
    private static func runTrackStorm(model: NotchViewModel) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            note("bench: track storm begin")
            sampleTrace(model: model, seconds: 12)

            let artwork = artworkBase64()
            // A held skip key, then thinning out, then a normal change.
            let gaps: [Double] = [0.10, 0.10, 0.12, 0.12, 0.15, 0.30, 0.30, 0.7, 1.4, 3.0]

            for (index, gap) in gaps.enumerated() {
                let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
                model.media.ingestForBench([
                    "bundleIdentifier": ProcessInfo.processInfo.environment["DYNAMIC_BENCH_BUNDLE"] ?? "com.apple.Music",
                    "title": "Storm Track \(index + 1)",
                    "artist": "Artist \(index + 1)",
                    "album": "Storm",
                    "playing": true,
                    "playbackRate": 1.0,
                    "durationMicros": 200_000_000,
                    "elapsedTimeMicros": 0,
                    "timestampEpochMicros": now,
                    "artworkData": artwork,
                ])
                note(String(
                    format: "bench: t+%.2f  track %d  presentation=%@  squash=%+.3f",
                    Double(index), index + 1,
                    String(describing: model.presentation), model.squash
                ))
                try? await Task.sleep(for: .seconds(gap))
            }
            note("bench: track storm end")
        }
    }
}
