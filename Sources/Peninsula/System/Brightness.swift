import CoreGraphics
import Foundation

/// Display brightness for the built-in panel.
///
/// There is no public API for this. `DisplayServices` is the framework the
/// system's own brightness keys drive, so it is loaded by name at runtime
/// rather than linked — a missing symbol on some future macOS then degrades to
/// "brightness control unavailable" instead of failing to launch.
enum Brightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW
    )

    private nonisolated static let getter: GetBrightness? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }

    private nonisolated static let setter: SetBrightness? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    static var isAvailable: Bool {
        getter != nil && setter != nil && display != nil
    }

    /// The built-in panel. External displays mostly have no software brightness
    /// at all, and DDC control is a different problem entirely.
    private static var display: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &displays, &count) == .success else { return nil }

        for id in displays.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            return id
        }
        return nil
    }

    static var level: Float? {
        guard let getter, let display else { return nil }
        var value: Float = 0
        guard getter(display, &value) == 0 else { return nil }
        return min(1, max(0, value))
    }

    @discardableResult
    static func set(_ level: Float) -> Bool {
        guard let setter, let display else { return false }
        return setter(display, min(1, max(0, level))) == 0
    }

    /// Steps the way the hardware keys do: sixteen notches across the range,
    /// so holding a key ramps at the same rate people are used to.
    @discardableResult
    static func step(up: Bool) -> Float? {
        guard let current = level else { return nil }
        let next = current + (up ? 1 : -1) / 16
        guard set(next) else { return nil }
        return min(1, max(0, next))
    }
}
