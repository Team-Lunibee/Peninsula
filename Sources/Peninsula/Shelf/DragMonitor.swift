import AppKit
import UniformTypeIdentifiers

/// Detects a file drag anywhere on screen and reports when it crosses the notch.
///
/// A closed notch is click-through, so AppKit never sends it drag events — the
/// panel has to be told to start accepting the mouse *before* the pointer
/// arrives. Watching the drag pasteboard globally is the only way to know a
/// drag is in flight while staying out of the way of every other drop target.
@MainActor
final class DragMonitor {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Fires on mouse-up regardless of where the drag ended.
    var onFinish: (() -> Void)?
    var hitTest: ((CGPoint) -> Bool)?

    private var monitors: [Any] = []
    private let pasteboard = NSPasteboard(name: .drag)

    private var baselineChangeCount = -1
    private var isTracking = false
    private var isCarryingContent = false
    private var isOverNotch = false

    private static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType(UTType.url.identifier),
    ]

    func start() {
        stop()

        add(mask: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            // Snapshot the pasteboard before the drag begins; a bump in the
            // change count during the drag is what identifies real content.
            self.baselineChangeCount = self.pasteboard.changeCount
            self.isTracking = true
            self.isCarryingContent = false
            self.isOverNotch = false
        }

        add(mask: .leftMouseDragged) { [weak self] _ in
            guard let self, self.isTracking else { return }

            if !self.isCarryingContent {
                guard self.pasteboard.changeCount != self.baselineChangeCount,
                      self.carriesDroppableContent
                else { return }
                self.isCarryingContent = true
            }

            let inside = self.hitTest?(NSEvent.mouseLocation) ?? false
            guard inside != self.isOverNotch else { return }
            self.isOverNotch = inside
            inside ? self.onEnter?() : self.onExit?()
        }

        add(mask: .leftMouseUp) { [weak self] _ in
            guard let self, self.isTracking else { return }
            let wasCarrying = self.isCarryingContent
            self.isTracking = false
            self.isCarryingContent = false
            self.isOverNotch = false
            self.baselineChangeCount = -1
            if wasCarrying { self.onFinish?() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isTracking = false
        isCarryingContent = false
        isOverNotch = false
    }

    private var carriesDroppableContent: Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(where: Self.acceptedTypes.contains)
    }

    private func add(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    deinit {
        // `monitors` holds opaque tokens; removal is safe from any thread.
        monitors.forEach(NSEvent.removeMonitor)
    }
}
