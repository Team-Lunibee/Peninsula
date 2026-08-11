import AppKit
import SwiftUI

/// Hosting view that is only "solid" where the notch is actually drawn.
///
/// The panel is always the size of the fully expanded sheet, but at rest only a
/// small pill is visible. Rather than toggling `ignoresMouseEvents` on the whole
/// window — which makes hover detection impossible precisely when it is needed —
/// this view refuses hit tests outside the pill, so clicks pass straight through
/// to whatever is behind while the pill itself stays live.
///
/// Hover comes from a tracking area rather than a global event monitor. Tracking
/// areas are evaluated by the window server against the view's own geometry, so
/// they fire while another app is frontmost, which is almost always the case for
/// a notch.
final class NotchHostingView: NSHostingView<NotchRootView> {
    /// Current size of the visible pill, in points.
    var pillSize: () -> CGSize = { .zero }
    /// Horizontal inset applied to the pill's own width.
    var hoverInsetX: () -> CGFloat = { 0 }
    /// Extra height below the pill, so the pointer can approach from the
    /// content area rather than only along the bezel.
    var hoverExtraBottom: () -> CGFloat = { 0 }

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var hoverArea: NSTrackingArea?

    /// The pill hugs the top edge, centred horizontally.
    var interactiveRect: CGRect {
        let size = pillSize()
        guard size.width > 0, size.height > 0 else { return .zero }

        let width = max(24, size.width - hoverInsetX() * 2)
        let height = max(12, size.height + hoverExtraBottom())
        let x = (bounds.width - width) / 2
        // SwiftUI hosting views are flipped, but do not assume it.
        let y = isFlipped ? 0 : bounds.height - height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space.
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverArea {
            removeTrackingArea(hoverArea)
            self.hoverArea = nil
        }

        let rect = interactiveRect
        guard !rect.isEmpty else { return }

        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// Call after the pill changes size so the tracking rect follows it.
    func refreshTracking() {
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        // No position check here. `locationInWindow` on a crossing event is not
        // always meaningful, and rejecting on it drops legitimate hovers. The
        // controller re-validates against live screen geometry instead, which
        // is where a stale tracking rect actually needs catching.
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}
