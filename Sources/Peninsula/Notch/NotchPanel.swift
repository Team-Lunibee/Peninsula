import AppKit

/// Borderless panel that hosts the notch UI.
///
/// It sits above the menu bar, joins every Space, and never steals focus — the
/// user should be able to click a button in the notch without the frontmost app
/// losing key status.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Only take key status when something inside actually wants input, so
        // clicking a notch button never pulls focus off the frontmost app.
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        // The notch is a black cutout, so its content is authored for dark
        // chrome regardless of the system appearance.
        appearance = NSAppearance(named: .darkAqua)

        // `.mainMenu + 3` clears the menu bar and its shadow layer while
        // staying below system alerts.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
