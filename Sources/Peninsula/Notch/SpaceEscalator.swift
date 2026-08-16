import AppKit

/// Lifts the notch panel out of the Spaces system entirely.
///
/// AppKit tops out at `.screenSaver`, which still sits below a full-screen
/// Space, and `.stationary` does not survive a Space switch — the panel slides
/// away with the outgoing desktop and briefly uncovers the physical cutout. A
/// window parked in its own window-server Space does neither: it does not take
/// part in the transition, and it sits above full-screen apps.
///
/// These are private SkyLight entry points, resolved by `dlsym` at runtime
/// rather than declared with `@_silgen_name`.
///
/// That choice is deliberate and it is a security property, not a style one.
/// A `@_silgen_name` declaration for a symbol Apple later removes is a *launch*
/// failure: dyld cannot bind it and the app never starts. Resolved by name, a
/// missing symbol is a `nil` function pointer, the escalator quietly reports
/// itself unavailable, and the notch carries on as an ordinary panel. Every
/// call site here already treats failure as normal.
final class SpaceEscalator {
    private typealias CGSConnectionID = UInt
    private typealias CGSSpaceID = UInt64

    private typealias DefaultConnection = @convention(c) () -> CGSConnectionID
    private typealias SpaceCreate = @convention(c) (CGSConnectionID, Int, CFDictionary?) -> CGSSpaceID
    private typealias SpaceDestroy = @convention(c) (CGSConnectionID, CGSSpaceID) -> Void
    private typealias SpaceSetLevel = @convention(c) (CGSConnectionID, CGSSpaceID, Int) -> Void
    private typealias SpacesVisibility = @convention(c) (CGSConnectionID, CFArray) -> Void
    private typealias WindowsToSpaces = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void

    private struct Symbols {
        var connection: DefaultConnection
        var create: SpaceCreate
        var destroy: SpaceDestroy
        var setLevel: SpaceSetLevel
        var show: SpacesVisibility
        var hide: SpacesVisibility
        var addWindows: WindowsToSpaces
        var removeWindows: WindowsToSpaces
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        ) else { return nil }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let connection = load("_CGSDefaultConnection", as: DefaultConnection.self),
            let create = load("CGSSpaceCreate", as: SpaceCreate.self),
            let destroy = load("CGSSpaceDestroy", as: SpaceDestroy.self),
            let setLevel = load("CGSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self),
            let show = load("CGSShowSpaces", as: SpacesVisibility.self),
            let hide = load("CGSHideSpaces", as: SpacesVisibility.self),
            let addWindows = load("CGSAddWindowsToSpaces", as: WindowsToSpaces.self),
            let removeWindows = load("CGSRemoveWindowsFromSpaces", as: WindowsToSpaces.self)
        else {
            Log.notch.error("SkyLight space symbols unavailable; the notch will not float")
            return nil
        }

        return Symbols(
            connection: connection,
            create: create,
            destroy: destroy,
            setLevel: setLevel,
            show: show,
            hide: hide,
            addWindows: addWindows,
            removeWindows: removeWindows
        )
    }()

    private var space: CGSSpaceID?
    private var attached: Set<Int> = []

    /// Must be 1. With 0 the window server treats the Space as a desktop and
    /// Finder starts drawing desktop icons into it.
    private static let desktopFlag = 1
    private static let maximumLevel = Int(Int32.max)

    var isAvailable: Bool { Self.symbols != nil }
    var isActive: Bool { space != nil }

    func activate() {
        guard space == nil, let symbols = Self.symbols else { return }

        let identifier = symbols.create(symbols.connection(), Self.desktopFlag, nil)
        guard identifier != 0 else {
            Log.notch.error("CGSSpaceCreate failed; staying below full-screen apps")
            return
        }

        symbols.setLevel(symbols.connection(), identifier, Self.maximumLevel)
        symbols.show(symbols.connection(), [identifier] as CFArray)
        space = identifier
    }

    func deactivate() {
        guard let identifier = space, let symbols = Self.symbols else { return }
        detachAll()
        symbols.hide(symbols.connection(), [identifier] as CFArray)
        symbols.destroy(symbols.connection(), identifier)
        space = nil
    }

    func attach(_ window: NSWindow) {
        guard let identifier = space, let symbols = Self.symbols else { return }
        let number = window.windowNumber
        guard number > 0, !attached.contains(number) else { return }

        symbols.addWindows(
            symbols.connection(),
            [number] as CFArray,
            [identifier] as CFArray
        )
        attached.insert(number)
    }

    func detach(_ window: NSWindow) {
        guard let identifier = space, let symbols = Self.symbols else { return }
        let number = window.windowNumber
        guard attached.remove(number) != nil else { return }

        symbols.removeWindows(
            symbols.connection(),
            [number] as CFArray,
            [identifier] as CFArray
        )
    }

    private func detachAll() {
        guard let identifier = space, let symbols = Self.symbols, !attached.isEmpty else { return }
        symbols.removeWindows(
            symbols.connection(),
            Array(attached) as CFArray,
            [identifier] as CFArray
        )
        attached.removeAll()
    }

    deinit {
        // A leaked Space survives app termination and leaves an unusable
        // window-server object behind, so tear it down unconditionally.
        if let identifier = space, let symbols = Self.symbols {
            symbols.hide(symbols.connection(), [identifier] as CFArray)
            symbols.destroy(symbols.connection(), identifier)
        }
    }
}
