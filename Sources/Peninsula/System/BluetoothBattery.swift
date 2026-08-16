import AppKit
import Observation

/// Battery levels for connected Bluetooth devices.
///
/// Read through `system_profiler` rather than IOBluetooth. The battery keys for
/// AirPods live in a private IORegistry layout that has changed shape between
/// macOS releases, whereas `SPBluetoothDataType` is a documented, stable JSON
/// surface that already does that decoding — and needs no entitlement.
///
/// The cost is a subprocess, so it runs on a slow timer and on demand rather
/// than continuously.
@MainActor
@Observable
final class BluetoothBattery {
    struct Device: Identifiable, Equatable, Sendable {
        var id: String { address }
        var address: String
        var name: String
        /// Single-battery devices (mice, keyboards, headphones) report here.
        var main: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?

        /// What to show when there is only room for one number.
        var headline: Int? {
            main ?? [left, right].compactMap(\.self).min() ?? caseLevel
        }

        var isLow: Bool {
            guard let headline else { return false }
            return headline <= 20
        }

        var symbol: String {
            let lowered = name.lowercased()
            if lowered.contains("airpods") || lowered.contains("buds") || lowered.contains("beats") {
                return left != nil || right != nil ? "airpods.gen3" : "headphones"
            }
            if lowered.contains("keyboard") { return "keyboard" }
            if lowered.contains("mouse") || lowered.contains("magic trackpad") { return "magicmouse" }
            if lowered.contains("trackpad") { return "trackpad" }
            return "wave.3.right.circle"
        }
    }

    private(set) var devices: [Device] = []

    /// Test seam for `Bench`: puts a known set of devices on screen without a
    /// radio, a paired accessory, or the two-second `system_profiler` call —
    /// so the panel can be photographed and inspected on any machine.
    func setForBench(_ devices: [Device]) {
        self.devices = devices
    }

    /// Fires when a device with battery information newly connects.
    var onConnect: ((Device) -> Void)?

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var knownAddresses: Set<String> = []

    /// `system_profiler` takes a second or two, so this is deliberately lazy.
    private static let interval: TimeInterval = 600

    func start() {
        guard timer == nil else { return }
        refresh()

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            let found = await Self.query()
            guard !Task.isCancelled, let self else { return }

            self.refreshTask = nil
            let previous = self.knownAddresses
            self.devices = found
            self.knownAddresses = Set(found.map(\.address))

            for device in found where !previous.contains(device.address) {
                // Skip the first sweep: everything is "new" at launch and
                // announcing all of it would be noise.
                guard !previous.isEmpty else { break }
                self.onConnect?(device)
            }
        }
    }

    // MARK: - Parsing

    nonisolated private static func query() async -> [Device] {
        await Task.detached(priority: .utility) { () -> [Device] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
            } catch {
                Log.app.error("system_profiler failed: \(error.localizedDescription)")
                return []
            }

            // Read before waiting: the JSON is comfortably larger than a pipe
            // buffer, and waiting first would deadlock on a full pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            return parse(data)
        }.value
    }

    nonisolated private static func parse(_ data: Data) -> [Device] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var devices: [Device] = []

        for section in sections {
            // Connected devices arrive as an array of single-key dictionaries,
            // where the key is the device's display name.
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }

            for entry in connected {
                for (name, value) in entry {
                    guard let details = value as? [String: Any] else { continue }

                    let device = Device(
                        address: details["device_address"] as? String ?? name,
                        name: name,
                        main: percentage(details["device_batteryLevelMain"]),
                        left: percentage(details["device_batteryLevelLeft"]),
                        right: percentage(details["device_batteryLevelRight"]),
                        caseLevel: percentage(details["device_batteryLevelCase"])
                    )

                    // A device with no battery reading has nothing to show.
                    guard device.headline != nil || device.caseLevel != nil else { continue }
                    devices.append(device)
                }
            }
        }

        return devices.sorted { ($0.headline ?? 100) < ($1.headline ?? 100) }
    }

    /// Levels come through as `"85%"`, occasionally as a bare number.
    nonisolated private static func percentage(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}
