import OSLog

/// Categories for the unified log.
///
/// Anything derived from what the user has, is doing, or is listening to is
/// interpolated as `.private`. `os_log` redacts private values in the system
/// log and in a sysdiagnose, and marking a filename `.public` writes it in the
/// clear where any process able to read logs can see it. Only fixed strings and
/// our own counters are public.
enum Log {
    private static let subsystem = "dev.anbam.Dynamic"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let notch = Logger(subsystem: subsystem, category: "notch")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
}
