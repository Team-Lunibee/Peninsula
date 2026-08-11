import Foundation
import IOKit.ps
import Observation

/// Battery and power-adapter state, delivered by IOKit rather than polled.
@MainActor
@Observable
final class PowerMonitor {
    struct Snapshot: Equatable {
        var percentage: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var isCharged: Bool
        /// `nil` on desktops and when the estimate is still being calculated.
        var minutesRemaining: Int?
    }

    private(set) var snapshot: Snapshot?

    /// Fires for meaningful changes only — plugging in, unplugging, reaching
    /// full, crossing a low threshold — not for every percent tick.
    var onEvent: ((Event) -> Void)?

    enum Event: Equatable {
        case pluggedIn(percentage: Int)
        case unplugged(percentage: Int)
        case charged
        case low(percentage: Int)
    }

    private var runLoopSource: CFRunLoopSource?
    private var hasWarnedLow = false

    /// Matches macOS's own low-battery warning so the two agree.
    private static let lowThreshold = 20

    func start() {
        guard runLoopSource == nil else { return }
        refresh(announce: false)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in monitor.refresh(announce: true) }
        }, context)?.takeRetainedValue() else {
            Log.app.error("could not observe power sources")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        self.runLoopSource = nil
    }

    private func refresh(announce: Bool) {
        guard let next = Self.read() else { return }
        let previous = snapshot
        snapshot = next

        guard announce, let previous else { return }

        if next.isPluggedIn, !previous.isPluggedIn {
            onEvent?(.pluggedIn(percentage: next.percentage))
            hasWarnedLow = false
        } else if !next.isPluggedIn, previous.isPluggedIn {
            onEvent?(.unplugged(percentage: next.percentage))
        }

        if next.isCharged, !previous.isCharged {
            onEvent?(.charged)
        }

        // Announce once per discharge cycle, not on every update below the line.
        if !next.isPluggedIn, next.percentage <= Self.lowThreshold, !hasWarnedLow {
            hasWarnedLow = true
            onEvent?(.low(percentage: next.percentage))
        }
        if next.percentage > Self.lowThreshold {
            hasWarnedLow = false
        }
    }

    private static func read() -> Snapshot? {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            let minutes = description[kIOPSTimeToEmptyKey] as? Int

            return Snapshot(
                percentage: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: state == kIOPSACPowerValue,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                // IOKit reports -1 while it is still working the estimate out.
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }

    // No deinit teardown: the source is main-actor state and a deinit is
    // nonisolated. `stop()` is called from the app delegate on termination,
    // which is the only time this object goes away.

}
