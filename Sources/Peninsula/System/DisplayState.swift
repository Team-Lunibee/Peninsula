import AppKit
import Observation

/// Whether the display is on.
///
/// Working for a sleeping or locked display is pure waste, and on a laptop waste
/// is measured in battery. Nothing visible changes either way, which makes this
/// the rare optimisation with no design cost at all.
///
/// Two things watch this: the meter, which stops choosing new bar heights, and
/// the notch's pointer polling, which stops asking where a cursor nobody can see
/// has got to.
@MainActor
@Observable
final class DisplayState {
    static let shared = DisplayState()

    private(set) var isAwake = true

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let states: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false),
            (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ]

        for (name, awake) in states {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAwake = awake }
            }
        }
    }
}
