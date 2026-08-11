import Foundation

/// How this process was started.
enum LaunchContext {
    /// True when LaunchServices started this process *as* the app, rather than
    /// something running the executable inside the bundle directly.
    ///
    /// This matters for privacy requests, and it matters harshly. TCC attributes
    /// a request to the *responsible* process, which for a binary run from a
    /// shell is the shell — or whatever launched it. That process's Info.plist
    /// has no `NSFocusStatusUsageDescription`, and TCC's response to a missing
    /// usage description is not an error or a denial: it is
    /// `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, a SIGABRT delivered from
    /// inside the daemon's reply block, which nothing here can catch.
    ///
    /// `XPC_SERVICE_NAME` is stamped per launch by launchd and inherited
    /// verbatim by child processes, so it names *this* bundle only when this
    /// bundle is what was launched.
    static var isApplicationLaunch: Bool {
        guard
            let identifier = Bundle.main.bundleIdentifier,
            let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        else { return false }
        return service.hasPrefix("application.\(identifier).")
    }
}
