import Foundation

/// Where a file came from, as macOS itself recorded it.
///
/// There is no API for *receiving* an AirDrop — no notification, no delegate,
/// nothing to register for. `sharingd` writes the file into Downloads and that
/// is the end of it as far as any other process is concerned.
///
/// What it leaves behind is a `com.apple.quarantine` extended attribute, which
/// every downloading agent stamps on what it writes:
///
///     0081;6a79ecf1;sharingd;6E9EC095-E574-417D-8678-7DF1F0B611B4
///     flags;timestamp;agent;event UUID
///
/// The agent field is the signal. `sharingd` means AirDrop; a browser puts its
/// own name there. So an arrival in Downloads can be told apart from a download
/// without guessing from the filename.
enum FileOrigin: Equatable {
    case airDrop
    case agent(String)
    case unknown

    /// The daemon behind AirDrop, Handoff and Continuity. AirDrop is the only
    /// one of those that writes files.
    private static let airDropAgent = "sharingd"

    static func of(_ url: URL) -> FileOrigin {
        guard let agent = quarantineAgent(of: url) else { return .unknown }
        return agent == Self.airDropAgent ? .airDrop : .agent(agent)
    }

    private static func quarantineAgent(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }

        var buffer = Data(count: length)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(url.path, name, raw.baseAddress, length, 0, 0)
        }
        // Not null-terminated, so this is read as bytes rather than a C string.
        guard read == length, let value = String(data: buffer, encoding: .utf8) else { return nil }

        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        return String(fields[2])
    }
}

extension FileManager {
    /// Waits for a file to stop growing, up to `timeout`.
    ///
    /// The directory event fires when the entry appears, not when the write
    /// finishes, so a large AirDrop is still arriving at that point. Copying it
    /// then puts a truncated file on the shelf — and the shelf is a copy, so
    /// there is nothing to correct it afterwards.
    func waitUntilStable(_ url: URL, timeout: TimeInterval = 30) async -> Bool {
        var lastSize: Int64 = -1
        var settledChecks = 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard let size = (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            else { return false }

            if size == lastSize {
                settledChecks += 1
                // Two consecutive equal reads: one could just be a slow moment
                // in the middle of a transfer.
                if settledChecks >= 2 { return true }
            } else {
                settledChecks = 0
                lastSize = size
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
