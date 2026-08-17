import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Drives the notch through real transitions so cost can be measured from
/// outside with `top`/`footprint`.
///
/// Off unless `PENINSULA_BENCH` is set, and never referenced from the UI — the
/// point is to exercise exactly the code path a hover does, not a special one.
@MainActor
enum Bench {
    /// stderr, unbuffered — stdout is block-buffered when redirected to a file,
    /// so `print` output only appears when the process exits.
    private static func note(_ message: String) {
        fputs(message + "\n", stderr)
    }

    static func startIfRequested(model: NotchViewModel, controller: NotchController? = nil) {
        guard let mode = ProcessInfo.processInfo.environment["PENINSULA_BENCH"] else { return }

        let cycles = ProcessInfo.processInfo.environment["PENINSULA_BENCH_CYCLES"]
            .flatMap(Int.init) ?? 40

        if ProcessInfo.processInfo.environment["PENINSULA_BENCH_TRACK"] != nil {
            injectTrack(into: model.media)
        }

        if let tab = ProcessInfo.processInfo.environment["PENINSULA_BENCH_TAB"],
           let selected = NotchTab(rawValue: tab) {
            model.tab = selected
        }

        switch mode {
        case "transitions": run(model: model, cycles: cycles, dwell: 0.9)
        case "idle": runIdle()
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
        // Opens once and leaves it open, so a settled panel can be measured for
        // what it costs to just sit there.
        case "open":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                controller?.holdOpenForBench()
                model.expand()
                for tick in 0..<8 {
                    try? await Task.sleep(for: .seconds(5))
                    note("open[\(tick)] \(String(describing: model.presentation)) settled=\(model.isSettled)")
                }
            }
        // Drives the real screen-sleep notification through the real observer,
        // rather than putting the display out and asking someone to watch.
        case "sleep":
            Task { @MainActor in
                let center = NSWorkspace.shared.notificationCenter
                @MainActor func report(_ label: String) {
                    note("sleep: \(label) awake=\(DisplayState.shared.isAwake) polling=\(controller?.isPollingPointer ?? false)")
                }
                try? await Task.sleep(for: .seconds(3))
                report("at rest       ")

                center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                report("screens asleep")

                center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                report("screens awake ")

                center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                report("session away  ")

                center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                report("session back  ")
            }
        // Feeds the classifier the exact payload shapes the adapter was
        // observed producing, so "video is not announced" is checked rather
        // than assumed.
        case "classify":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
                let cases: [(String, Bool, [String: Any])] = [
                    ("Music.app             ", true, [
                        "bundleIdentifier": "com.apple.Music", "title": "색안경",
                        "artist": "STAYC", "album": "STEREOTYPE - EP", "playing": true,
                        "mediaType": "MRMediaRemoteMediaTypeMusic", "isMusicApp": true,
                        "artworkData": artworkBase64(width: 600, height: 600),
                    ]),
                    ("Spotify (no mediaType)", true, [
                        "bundleIdentifier": "com.spotify.client", "title": "Track",
                        "artist": "Artist", "album": "An Album", "playing": true,
                        "artworkData": artworkBase64(width: 640, height: 640),
                    ]),
                    ("YouTube video         ", false, [
                        "bundleIdentifier": "com.google.Chrome",
                        "title": "캐리비안베이보다 강력한 워터파크?",
                        "artist": "", "album": "", "playing": true,
                        "artworkData": artworkBase64(width: 480, height: 270),
                    ]),
                    ("YouTube Short         ", false, [
                        "bundleIdentifier": "com.google.Chrome",
                        "title": "피아노가 들리는 승헌쓰의 도레미 챌린지",
                        "artist": "Sofa4844", "album": "", "playing": true,
                        "durationMicros": 49_561_000,
                        "artworkData": artworkBase64(width: 150, height: 83),
                    ]),
                    ("browser, no artwork   ", false, [
                        "bundleIdentifier": "com.google.Chrome", "title": "야스오 1대1",
                        "artist": "", "album": "", "playing": true,
                    ]),
                ]

                var failures = 0
                for (label, expected, payload) in cases {
                    var full = payload
                    full["timestampEpochMicros"] = now
                    model.media.ingestForBench(full)
                    // The artwork is decoded off the main actor; give it a beat.
                    try? await Task.sleep(for: .milliseconds(900))
                    let got = model.media.looksLikeMusic
                    if got != expected { failures += 1 }
                    note("classify: \(label) music=\(got) want=\(expected) \(got == expected ? "ok" : "FAIL")")
                }
                note("classify: \(failures == 0 ? "all passed" : "\(failures) FAILED")")
            }
        // End to end: does a track change actually reach the island, and does a
        // video actually fail to.
        case "banner":
            Task { @MainActor in
                let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
                @MainActor func play(_ title: String, video: Bool, playing: Bool = true) {
                    var payload: [String: Any] = [
                        "bundleIdentifier": video ? "com.google.Chrome" : "com.apple.Music",
                        "title": title, "playing": playing, "timestampEpochMicros": now,
                        "artworkData": video
                            ? artworkBase64(width: 480, height: 270)
                            : artworkBase64(width: 600, height: 600),
                    ]
                    if !video {
                        payload["artist"] = "Artist"
                        payload["album"] = "An Album"
                        payload["isMusicApp"] = true
                    } else {
                        payload["artist"] = "Channel"
                        payload["album"] = ""
                    }
                    model.media.ingestForBench(payload)
                }
                /// Highest presentation reached over the next couple of seconds.
                @MainActor func watch() async -> String {
                    var seen = "idle"
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if model.presentation == .peek { seen = "peek" }
                        else if model.presentation == .expanded { seen = "expanded" }
                    }
                    return seen
                }
                /// Waits out any banner still on screen, so the next reading is
                /// this change's and not the previous one's tail.
                @MainActor func quiet() async {
                    for _ in 0..<80 {
                        if model.presentation != .peek, model.presentation != .expanded { return }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }

                // Past the launch grace, or nothing is treated as news.
                try? await Task.sleep(for: .seconds(5))

                play("Music One", video: false)
                _ = await watch(); await quiet()
                play("Music Two", video: false)
                note("banner: music -> music        \(await watch())   (want peek)")
                await quiet()

                // The interesting one: leaving music for a video, when the
                // artwork on hand is still the album's.
                play("Short One", video: true)
                note("banner: music -> video        \(await watch())   (want idle)")
                await quiet()

                play("Short Two", video: true)
                note("banner: video -> video        \(await watch())   (want idle)")
                await quiet()

                play("Music Three", video: false)
                note("banner: video -> music        \(await watch())   (want peek)")
                await quiet()

                // The reported annoyance: a video ends and MediaRemote hands
                // now-playing back to a Music app that has been paused all
                // along. Nothing started; something stopped.
                play("Short Four", video: true)
                await quiet()
                play("Paused Song", video: false, playing: false)
                note("banner: video ends, paused    \(await watch())   (want idle)")
                await quiet()

                // A track that arrives stopped and starts a moment later is a
                // real start, and must survive the guard above.
                play("Fresh Song", video: false, playing: false)
                try? await Task.sleep(for: .milliseconds(400))
                play("Fresh Song", video: false, playing: true)
                note("banner: stopped then starts   \(await watch())   (want peek)")
            }
        // Drops real files onto the shelf, checks which way the row runs, then
        // deletes one behind the app's back and checks it goes.
        case "shelf":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let shelf = model.shelf
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dynamic-bench-shelf", isDirectory: true)
                try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

                var sources: [URL] = []
                for name in ["first.txt", "second.txt", "third.txt"] {
                    let url = temp.appendingPathComponent(name)
                    try? Data("\(name) contents".utf8).write(to: url)
                    sources.append(url)
                    // One at a time, so "newest" is unambiguous.
                    shelf.add(contentsOf: [url])
                    try? await Task.sleep(for: .milliseconds(400))
                }

                /// What the row reads, left to right — the view renders the
                /// store reversed.
                @MainActor func onScreen() -> String {
                    shelf.items.reversed().map(\.displayName).joined(separator: " | ")
                }
                note("shelf: dropped first, second, third")
                note("shelf: left-to-right  \(onScreen())   (want first | second | third)")

                // Delete the middle one's backing file, the way a person with a
                // Finder window would.
                guard let middle = shelf.items.first(where: { $0.storedFilename.hasPrefix("second") }) else {
                    note("shelf: could not find the middle item"); return
                }
                let backing = shelf.url(for: middle)
                try? FileManager.default.removeItem(at: backing)
                note("shelf: deleted \(backing.lastPathComponent) from disk")
                note("shelf: before opening  \(onScreen())   (still shows it)")

                // Opening the panel is what re-checks.
                controller?.holdOpenForBench()
                model.tab = .shelf
                model.expand()
                try? await Task.sleep(for: .seconds(2))
                note("shelf: after opening   \(onScreen())   (want first | third)")

                // Held open long enough to be looked at. `expand()` is a no-op
                // when it is already open, so this only undoes a collapse the
                // tracking area asked for.
                for _ in 0..<30 {
                    model.expand()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                shelf.removeAll()
                try? FileManager.default.removeItem(at: temp)
                note("shelf: cleaned up, items=\(shelf.items.count)")
            }
        // Fills the shelf to its cap and reports what holding that many tiles
        // actually costs, rather than reasoning about it from the thumbnail
        // dimensions.
        case "shelffill":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let count = ProcessInfo.processInfo.environment["PENINSULA_BENCH_SHELF_N"]
                    .flatMap(Int.init) ?? 120
                let shelf = model.shelf
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dynamic-bench-fill", isDirectory: true)
                try? FileManager.default.removeItem(at: temp)
                try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

                @MainActor func footprintMB() -> Int {
                    var info = task_vm_info_data_t()
                    var size = mach_msg_type_number_t(
                        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
                    )
                    let ok = withUnsafeMutablePointer(to: &info) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                        }
                    }
                    return ok == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
                }

                note("shelffill: empty                 \(footprintMB())MB")

                // Small files: this measures what the *shelf* costs to hold and
                // draw, not what the copies weigh.
                var urls: [URL] = []
                for index in 0..<count {
                    let url = temp.appendingPathComponent(String(format: "file-%03d.txt", index))
                    try? Data("contents \(index)".utf8).write(to: url)
                    urls.append(url)
                }
                shelf.add(contentsOf: urls)
                try? await Task.sleep(for: .seconds(2))
                note("shelffill: \(shelf.items.count) items indexed     \(footprintMB())MB")

                controller?.holdOpenForBench()
                model.tab = .shelf
                for tick in 0..<14 {
                    model.expand()
                    try? await Task.sleep(for: .seconds(1))
                    if tick == 6 { note("shelffill: panel open, drawn     \(footprintMB())MB") }
                }
                note("shelffill: after scrolling none  \(footprintMB())MB   thumbnails held")

                shelf.removeAll()
                try? FileManager.default.removeItem(at: temp)
                try? await Task.sleep(for: .seconds(3))
                note("shelffill: cleared               \(footprintMB())MB   items=\(shelf.items.count)")
            }
        case "peek":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                model.present(.trackChanged, for: 600)
            }
        // Puts believable content in every tab and holds the panel open, so the
        // screenshots in the README show the app doing something rather than
        // three empty states. Nothing here touches the user's own shelf: the
        // files are generated into a temporary directory and cleared on exit.
        case "demo":
            Task { @MainActor in
                let temp = demoFiles()
                if !temp.isEmpty { _ = model.shelf.add(contentsOf: temp) }

                // After the real refresh, not before it: BluetoothBattery.start()
                // shells out to system_profiler and replaces `devices` a second
                // or two in, so an injection at t=0 is quietly overwritten by
                // whatever is actually paired to this Mac.
                try? await Task.sleep(for: .seconds(3))
                model.bluetooth.setForBench(demoDevices())

                controller?.holdOpenForBench()

                // expand() is a no-op when already open, so re-asserting it only
                // undoes a collapse the click monitor asked for — which is what
                // happens whenever the machine is in use while photographing.
                for tick in 0..<120 {
                    model.expand()
                    if tick == 4 { model.bluetooth.setForBench(demoDevices()) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                model.shelf.removeAll()
            }
        default: break
        }
    }

    /// Two accessories, not three: a third card overflows the panel and has to
    /// be scrolled to, which photographs as a clipped layout rather than as the
    /// feature working. These two cover both shapes worth showing — a
    /// left/right/case split, and a single level low enough to turn orange.
    @MainActor
    private static func demoDevices() -> [BluetoothBattery.Device] {
        [
            .init(address: "00:11:22:33:44:01", name: "AirPods Pro",
                  main: nil, left: 82, right: 79, caseLevel: 45),
            .init(address: "00:11:22:33:44:02", name: "Magic Mouse",
                  main: 14, left: nil, right: nil, caseLevel: nil),
        ]
    }

    /// Real files, not empty ones: the tiles render Quick Look thumbnails, so a
    /// zero-byte `.png` would photograph as a generic icon and prove nothing.
    private static func demoFiles() -> [URL] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-demo", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        var urls: [URL] = []

        for (name, hue) in [("표지 시안.png", 0.58), ("배너 초안.png", 0.92)] {
            let url = temp.appendingPathComponent(name)
            if writePNG(to: url, hue: hue) { urls.append(url) }
        }

        let notes = temp.appendingPathComponent("회의 메모.txt")
        if (try? Data("스크롤 곡선 다시 재기\n노치 세이프존 확인\n".utf8).write(to: notes)) != nil {
            urls.append(notes)
        }

        let pdf = temp.appendingPathComponent("사양서.pdf")
        if writePDF(to: pdf) { urls.append(pdf) }

        return urls
    }

    private static func writePNG(to url: URL, hue: Double) -> Bool {
        let side = 512
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        for row in 0..<8 {
            for column in 0..<8 {
                let shade = Double((row + column) % 2 == 0 ? 1.0 : 0.72)
                context.setFillColor(NSColor(
                    hue: hue, saturation: 0.55, brightness: shade, alpha: 1
                ).cgColor)
                let step = side / 8
                context.fill(CGRect(x: column * step, y: row * step, width: step, height: step))
            }
        }

        guard let image = context.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func writePDF(to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 420, height: 560)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        context.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        for line in 0..<14 {
            let width = line % 4 == 3 ? 150.0 : 300.0
            context.fill(CGRect(x: 60, y: 460 - Double(line) * 28, width: width, height: 9))
        }
        context.endPDFPage()
        context.closePDF()
        return true
    }

    /// A synthetic now-playing snapshot, so the full media panel is on screen
    /// while the transitions are profiled. Measuring the empty-state placeholder
    /// would flatter every number.
    private static func injectTrack(into media: MediaEngine) {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        media.ingestForBench([
            "bundleIdentifier": ProcessInfo.processInfo.environment["PENINSULA_BENCH_BUNDLE"] ?? "com.apple.Music",
            "title": ProcessInfo.processInfo.environment["PENINSULA_SHORT_TITLE"] == nil ? "Bench Track With A Deliberately Long Title" : "Short",
            "artist": "Benchmark Artist",
            "album": "Benchmark Album",
            "playing": true,
            "playbackRate": 1.0,
            "durationMicros": 213_000_000,
            "elapsedTimeMicros": 41_000_000,
            "timestampEpochMicros": now,
            "shuffleMode": ProcessInfo.processInfo.environment["PENINSULA_BENCH_NOMODES"] == nil ? 3 : NSNull(),
            "repeatMode": ProcessInfo.processInfo.environment["PENINSULA_BENCH_NOMODES"] == nil ? 3 : NSNull(),
            "artworkData": artworkBase64(),
        ])
    }

    /// Built with CoreGraphics rather than `NSImage.lockFocus`, which would
    /// materialise a Retina-backed rep plus a TIFF plus a bitmap rep — around
    /// 100MB of transient allocation that then shows up in
    /// `phys_footprint_peak` and gets mistaken for the app's own cost.
    private static func artworkBase64(width: Int = 512, height: Int = 512) -> String {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
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
                end: CGPoint(x: width, y: height),
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

    /// CPU seconds this process has used so far, user plus system.
    ///
    /// Reported from inside rather than sampled with `ps`, which quantises to
    /// whole seconds — on a run that burns forty of them, that is a percent of
    /// noise before the machine has done anything. It also fixes the window
    /// exactly: the count starts when the cycles do, so neither launch nor the
    /// settling delay is charged to the transitions.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func total(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return total(usage.ru_utime) + total(usage.ru_stime)
    }

    /// Physical footprint, the number Activity Monitor calls Memory.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Sits there doing nothing, which for a menu-bar app is the whole job.
    ///
    /// Long enough that the numbers are not dominated by whatever the app was
    /// still finishing at launch: the adapter connects a second or two in, and
    /// the first Bluetooth and display queries land around the same time.
    private static func runIdle() {
        let seconds = ProcessInfo.processInfo.environment["PENINSULA_BENCH_SECONDS"]
            .flatMap(Double.init) ?? 100

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            note("bench: idle begin")

            let startCPU = cpuSeconds()
            let startWall = ProcessInfo.processInfo.systemUptime
            let startMemory = footprintMB()

            try? await Task.sleep(for: .seconds(seconds))

            let cpu = cpuSeconds() - startCPU
            let wall = ProcessInfo.processInfo.systemUptime - startWall
            note(String(
                format: "bench: idle end — %.2fs CPU / %.1fs wall = %.2f%%, memory %.1f -> %.1f MB, threads %d",
                cpu, wall, wall > 0 ? cpu / wall * 100 : 0,
                startMemory, footprintMB(), threadCount()
            ))

            if ProcessInfo.processInfo.environment["PENINSULA_BENCH_QUIT"] != nil {
                NSApp.terminate(nil)
            }
        }
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
        )
        return Int(count)
    }

    private static func run(model: NotchViewModel, cycles: Int, dwell: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            note("bench: transitions begin (\(cycles) cycles)")

            let startCPU = cpuSeconds()
            let startWall = ProcessInfo.processInfo.systemUptime

            for index in 0..<cycles {
                model.expand()
                try? await Task.sleep(for: .seconds(dwell))
                model.collapse()
                try? await Task.sleep(for: .seconds(dwell))
                if index % 10 == 9 { note("bench: cycle \(index + 1)") }
            }

            let cpu = cpuSeconds() - startCPU
            let wall = ProcessInfo.processInfo.systemUptime - startWall
            note(String(
                format: "bench: transitions end — %.2fs CPU / %.1fs wall = %.2f%%",
                cpu, wall, wall > 0 ? cpu / wall * 100 : 0
            ))

            // So a runner can wait on the process instead of polling for a line
            // and then guessing when it is safe to kill it.
            if ProcessInfo.processInfo.environment["PENINSULA_BENCH_QUIT"] != nil {
                NSApp.terminate(nil)
            }
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
            NSApp.windows.first { $0.title == "Peninsula" }?.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(7))
            let settings = NSApp.windows.first { $0.title == "Peninsula" }
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
                    "bundleIdentifier": ProcessInfo.processInfo.environment["PENINSULA_BENCH_BUNDLE"] ?? "com.apple.Music",
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
