import AppKit

// AppKit lifecycle rather than SwiftUI's `App`: the notch lives in a panel this
// process owns outright, and an accessory app has no scenes worth handing to
// SwiftUI's scene machinery.

/// `NSApplication.delegate` is weak, so the delegate needs an owner that
/// outlives `run()`.
nonisolated(unsafe) private var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    // `--dump-frames <dir>` renders the transitions to contact sheets and
    // exits. It shares the app's Motion curves and NotchShape, so the sheets
    // show the real animation rather than a re-implementation of it.
    if let index = CommandLine.arguments.firstIndex(of: "--dump-frames"),
       CommandLine.arguments.indices.contains(index + 1) {
        FrameDump.run(outputDirectory: CommandLine.arguments[index + 1])
        exit(0)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
