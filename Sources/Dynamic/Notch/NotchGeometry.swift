import AppKit

extension NSScreen {
    /// True when the display has a hardware camera housing.
    var hasHardwareNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// The physical cutout measured from AppKit rather than hardcoded per model.
    /// 16" reports ~220x38pt, 14" ~185x32pt at default scaling.
    var hardwareNotchSize: CGSize? {
        guard
            let left = auxiliaryTopLeftArea?.width,
            let right = auxiliaryTopRightArea?.width,
            safeAreaInsets.top > 0
        else { return nil }
        return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }

    var menuBarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// Stable identifier that survives sleep/wake and re-plugging, unlike
    /// `displayID`, which macOS is free to recycle.
    var persistentID: String? {
        guard
            let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static var withMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

/// How the notch presents itself on a given display.
enum NotchStyle: Equatable {
    /// The display has a camera housing: hug the top edge and impersonate it.
    case cutout
    /// No housing to hide behind, so float below the menu bar as a pill
    /// instead of drawing a fake cutout over menu bar content.
    case floating
}

/// Every measurement the notch UI needs, derived once per screen change.
struct NotchGeometry: Equatable {
    /// Size of the resting pill. On notched Macs this is the real cutout.
    var closedSize: CGSize
    /// Size of the fully open panel.
    var expandedSize: CGSize
    /// Screen-space rect of the resting pill, used for hover/drag hit testing.
    var closedRect: CGRect
    /// Screen-space rect of the whole borderless panel.
    var windowFrame: CGRect
    /// The display this geometry was measured on.
    var screenFrame: CGRect
    var style: NotchStyle
    var screenID: String?

    var hasHardwareNotch: Bool { style == .cutout }

    /// Breathing room around the panel so shadows and the squash-and-stretch
    /// overshoot are never clipped by the window edge.
    static let shadowPadding: CGFloat = 26

    // Proportions start from Apple's Dynamic Island — the expanded
    // presentation is ~2.9x the island's width (126pt -> 371pt) and the system
    // truncates past 160pt tall — then get corrected for the Mac.
    //
    // Two things do not transfer directly. Screen share: 371pt is 94% of an
    // iPhone's width, and 94% of a 14" MacBook would be 1421pt. And apparent
    // size: a macOS point is physically ~1.22x an iOS point (0.20 vs
    // 0.164 mm/pt), but a laptop sits ~55cm away against a phone's ~30cm, so
    // matching angular size still wants roughly 1.5x more points.
    //
    // What does transfer is the ratio to the cutout, which is why width is
    // derived from the measured notch rather than fixed: a 16" gets a
    // proportionally wider panel than a 14", the way the island scales across
    // iPhone models. The ratio carries a Mac uplift over Apple's 2.9, and the
    // height sits between Apple's 160pt ceiling and the 190pt that shipping
    // Mac notch apps have settled on.
    static let expansionWidthRatio: CGFloat = 3.15
    static let expandedWidthRange: ClosedRange<CGFloat> = 560...690
    static let expandedHeight: CGFloat = 218
    /// Apple's standard margin for the expanded presentation is 20pt on
    /// iPhone. A macOS point is physically larger and the panel is wider, so
    /// 20pt reads as cramped here; this is the Mac equivalent.
    static let contentMargin: CGFloat = 28

    // Hover target while resting. Pulled in slightly at the sides so the notch
    // does not grab the pointer from across the menu bar, and extended below so
    // it still opens when the pointer arrives from the content area rather than
    // sliding along the bezel. Shared so the tracking rect and the controller's
    // validation rect can never disagree.
    static let restingHoverInsetX: CGFloat = 4
    static let restingHoverExtraBottom: CGFloat = 12

    /// Fallback pill for displays without a cutout.
    static let syntheticClosedSize = CGSize(width: 190, height: 32)
    /// Inset from the top edge when floating. Small on purpose: the pill sits
    /// *within* the menu bar the way the Dynamic Island sits within the iPhone
    /// status bar. Dropping it below the menu bar reads as a separate floating
    /// window rather than as part of the system chrome.
    static let floatingTopInset: CGFloat = 1
    /// How much shorter than the menu bar the floating pill is. Barely: the
    /// island fills its status bar, and taking real height out of the pill
    /// leaves its contents with nowhere to breathe.
    static let floatingHeightInset: CGFloat = 2

    @MainActor
    static func measure(screen: NSScreen, preferences: Preferences) -> NotchGeometry {
        let hardware = screen.hardwareNotchSize
        // A display with a real cutout has no choice. Everywhere else it is the
        // user's call: impersonate a notch against the top edge, or float below
        // the menu bar and leave it alone.
        let style: NotchStyle = if hardware != nil {
            .cutout
        } else {
            preferences.externalDisplayStyle == .notch ? .cutout : .floating
        }

        var height: CGFloat = switch preferences.heightMode {
        case .matchRealNotch: hardware?.height ?? screen.menuBarHeight
        case .matchMenuBar: screen.menuBarHeight
        case .custom: preferences.customHeight
        }

        if style == .floating, preferences.heightMode != .custom {
            // Fit inside the bar rather than filling it edge to edge.
            height = max(24, screen.menuBarHeight - Self.floatingHeightInset)
        }

        // +4pt hides the seam where the shape's antialiased edge meets the
        // physical cutout; without it a hairline of wallpaper shows through.
        // A floating pill has no seam to hide, so it takes its width as-is.
        let baseWidth = hardware.map { $0.width + 4 } ?? Self.syntheticClosedSize.width
        let closedSize = CGSize(width: baseWidth, height: max(height, 1))

        let expandedSize = CGSize(
            width: (closedSize.width * Self.expansionWidthRatio)
                .clamped(to: Self.expandedWidthRange)
                .rounded(),
            height: Self.expandedHeight
        )

        let windowSize = CGSize(
            width: expandedSize.width + Self.shadowPadding * 2,
            height: expandedSize.height + Self.shadowPadding
        )

        // A cutout panel hugs the top edge because it has to line up with the
        // housing. A floating one sits just inside the menu bar.
        let topInset: CGFloat = style == .cutout ? 0 : Self.floatingTopInset

        let screenFrame = screen.frame
        let windowFrame = CGRect(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.maxY - windowSize.height - topInset,
            width: windowSize.width,
            height: windowSize.height
        )

        let closedRect = CGRect(
            x: screenFrame.midX - closedSize.width / 2,
            y: screenFrame.maxY - closedSize.height - topInset,
            width: closedSize.width,
            height: closedSize.height
        )

        return NotchGeometry(
            closedSize: closedSize,
            expandedSize: expandedSize,
            closedRect: closedRect,
            windowFrame: windowFrame,
            screenFrame: screenFrame,
            style: style,
            screenID: screen.persistentID
        )
    }

    /// Where a file drag has to reach before the shelf opens for it.
    ///
    /// Far more forgiving than the hover target, and deliberately so: dragging
    /// is a committed, two-handed gesture aimed at the top of the screen, and
    /// asking someone to land a dragged file on a 32pt pill while holding the
    /// mouse button is a different task from moving a cursor there. Once the
    /// zone is armed it grows, so a wobble mid-drag does not drop out of it.
    func dragCatchRect(active: Bool) -> CGRect {
        let width = min(screenFrame.width, max(expandedSize.width * 2, 720))
        let height: CGFloat = active ? 300 : 190

        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Hover target, generously padded below the pill so the notch still opens
    /// when the pointer approaches from the content area rather than the bezel.
    func hoverRect(expanded: Bool) -> CGRect {
        if expanded {
            return windowFrame.insetBy(dx: Self.shadowPadding / 2, dy: 0)
        }
        return closedRect.insetBy(dx: -6, dy: -4)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
