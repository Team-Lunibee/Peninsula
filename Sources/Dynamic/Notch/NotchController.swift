import AppKit
import SwiftUI

/// Owns the notch panel: places it on the right display, keeps it above
/// everything, and translates pointer activity into presentation changes.
@MainActor
final class NotchController: NSObject {
    private var panel: NotchPanel?
    private var hostingView: NotchHostingView?
    private let escalator = SpaceEscalator()
    private var dragMonitor: DragMonitor?

    private var clickMonitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var isPointerInTrigger = false
    private var dropSettleTask: Task<Void, Never>?
    private var observers: [Task<Void, Never>] = []
    private var lastTrackToken = 0

    let model: NotchViewModel
    private let media: MediaEngine
    private let shelf: ShelfStore
    private let bluetooth: BluetoothBattery
    private let focus: FocusMonitor

    private var preferences: Preferences { .shared }

    init(
        media: MediaEngine,
        shelf: ShelfStore,
        bluetooth: BluetoothBattery,
        focus: FocusMonitor
    ) {
        self.media = media
        self.shelf = shelf
        self.bluetooth = bluetooth
        self.focus = focus
        let screen = Self.preferredScreen(Preferences.shared.displayTarget)
        let geometry = NotchGeometry.measure(screen: screen, preferences: .shared)
        self.model = NotchViewModel(
            geometry: geometry,
            media: media,
            shelf: shelf,
            bluetooth: bluetooth,
            focus: focus
        )
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        model.onDrop = { [weak self] urls in self?.didDrop(urls: urls) }
        model.onAirDropAll = { [weak self] in self?.airDropShelf() }
        model.onAirDropFiles = { [weak self] urls in self?.airDrop(files: urls) }
        model.onAirDropItem = { [weak self] item in self?.airDrop(item) }
        model.onOpenSettings = { SettingsWindow.show() }

        buildPanel()
        installClickMonitors()
        installDragMonitor()
        observeScreenChanges()
        observePreferences()
        observePresentation()
        observeRestingState()
        observeTrackChanges()
        applyFullScreenBehaviour()
        Log.notch.info("notch controller started")
    }

    func stop() {
        hoverTask?.cancel()
        dropSettleTask?.cancel()
        observers.forEach { $0.cancel() }
        observers.removeAll()
        dragMonitor?.stop()
        dragMonitor = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        escalator.deactivate()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Panel

    /// Picks the display that actually has a cutout; falls back to the main
    /// display so external-only setups still get the floating pill.
    private static func preferredScreen(_ target: DisplayTarget) -> NSScreen {
        let fallback = NSScreen.screens.first(where: \.hasHardwareNotch)
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        switch target {
        case .automatic: return fallback
        case .followMouse: return NSScreen.withMouse ?? fallback
        }
    }

    private func buildPanel() {
        let panel = NotchPanel(contentRect: model.geometry.windowFrame)
        let hosting = NotchHostingView(rootView: NotchRootView(model: model))
        hosting.frame = CGRect(origin: .zero, size: model.geometry.windowFrame.size)
        hosting.autoresizingMask = [.width, .height]

        hosting.pillSize = { [weak self] in self?.model.contentSize ?? .zero }
        hosting.hoverInsetX = { [weak self] in
            self?.model.presentation.isResting == true ? NotchGeometry.restingHoverInsetX : 0
        }
        hosting.hoverExtraBottom = { [weak self] in
            // None once open, or the panel would refuse to close until the
            // pointer travelled well past its bottom edge. A banner still wants
            // it: it is small, and it can be opened by moving onto it.
            self?.model.presentation == .expanded ? 0 : NotchGeometry.restingHoverExtraBottom
        }
        hosting.onMouseEntered = { [weak self] in self?.pointerEntered() }
        hosting.onMouseExited = { [weak self] in self?.pointerExited() }

        panel.contentView = hosting
        panel.setFrame(model.geometry.windowFrame, display: true)
        panel.sharingType = preferences.hideFromScreenRecording ? .none : .readWrite
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostingView = hosting
        hosting.refreshTracking()
    }

    private func relayout(on screen: NSScreen? = nil) {
        let screen = screen ?? Self.preferredScreen(preferences.displayTarget)
        let geometry = NotchGeometry.measure(screen: screen, preferences: preferences)
        guard geometry != model.geometry || panel == nil else { return }

        model.geometry = geometry
        panel?.setFrame(geometry.windowFrame, display: true)
        hostingView?.frame = CGRect(origin: .zero, size: geometry.windowFrame.size)
        hostingView?.refreshTracking()
        Log.notch.debug("relaid out on \(geometry.screenID ?? "unknown", privacy: .private)")
    }

    /// Pins the panel to a private Space of its own.
    ///
    /// This is not an optional flourish — it is what makes the notch behave
    /// like hardware. `.stationary` alone does not survive a Space switch: the
    /// panel slides away with the outgoing desktop, and on a real MacBook that
    /// means the physical cutout is briefly uncovered while a black pill drifts
    /// off to one side. A window parked in its own Space does not participate
    /// in the transition at all, so it stays welded to the glass.
    ///
    /// Being above full-screen apps falls out of the same mechanism, since the
    /// Space sits at the maximum absolute level.
    private func applyFullScreenBehaviour() {
        guard let panel else { return }
        escalator.activate()
        escalator.attach(panel)
    }

    // MARK: - Observation

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayout()
                self?.applyFullScreenBehaviour()
            }
        }

        // Re-assert window ordering after a Space switch; the window server
        // occasionally drops a stationary panel behind the menu bar layer.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.orderFrontRegardless()
            }
        }
    }

    /// Re-derives geometry and window flags whenever a relevant setting moves.
    private func observePreferences() {
        observers.append(
            observeChanges {
                _ = Preferences.shared.heightMode
                _ = Preferences.shared.customHeight
                _ = Preferences.shared.idleStyle
                _ = Preferences.shared.externalDisplayStyle
                _ = Preferences.shared.displayTarget
                _ = Preferences.shared.hideFromScreenRecording
            } onChange: { [weak self] in
                guard let self else { return }
                self.relayout()
                self.applyFullScreenBehaviour()
                self.panel?.sharingType = self.preferences.hideFromScreenRecording ? .none : .readWrite
                self.hostingView?.refreshTracking()
            }
        )
    }

    /// The hit-test and tracking rects follow the pill, so they have to be
    /// rebuilt every time it changes size.
    private func observePresentation() {
        observers.append(
            observeChanges { [weak self] in
                _ = self?.model.presentation
                _ = self?.model.contentSize
            } onChange: { [weak self] in
                guard let self else { return }
                self.hostingView?.refreshTracking()
                // Levels are read on a slow timer; opening the panel is the one
                // moment someone is actually looking at them.
                if self.model.presentation == .expanded {
                    self.bluetooth.refresh()
                }
            }
        )
    }

    /// Grows the resting pill in and out as playback starts and stops, so the
    /// notch behaves like a Live Activity beginning rather than a bar that is
    /// always there.
    private func observeRestingState() {
        observers.append(
            observeChanges { [weak self] in
                _ = self?.model.showsIdleContent
            } onChange: { [weak self] in
                self?.model.settleAtRest()
            }
        )
    }

    /// Surfaces a track change as a banner, the way the Dynamic Island does.
    private func observeTrackChanges() {
        observers.append(
            observeChanges { [weak self] in
                _ = self?.media.trackToken
            } onChange: { [weak self] in
                guard let self else { return }
                let token = self.media.trackToken
                defer { self.lastTrackToken = token }

                guard token != self.lastTrackToken,
                      self.preferences.mediaEnabled,
                      self.media.hasTrack
                else { return }

                self.model.present(.trackChanged)
            }
        )
    }

    // MARK: - Pointer

    /// Screen-space rect that may trigger an expansion, derived fresh from the
    /// resting state every time it is asked for.
    ///
    /// A tracking area is created once per presentation, so while the panel is
    /// open its rect covers the whole expanded sheet. If a collapse and the
    /// tracking refresh ever land out of order, that wide rect would still be
    /// live and the notch would appear to open from halfway across the screen.
    /// Re-deriving the rect at the moment of decision makes that impossible.
    private var restingTriggerRect: CGRect {
        let size = model.size(for: model.restingPresentation)
        let insetX = NotchGeometry.restingHoverInsetX
        let extraBottom = NotchGeometry.restingHoverExtraBottom
        let closed = model.geometry.closedRect

        return CGRect(
            x: closed.midX - size.width / 2 + insetX,
            y: closed.maxY - size.height - extraBottom,
            width: max(24, size.width - insetX * 2),
            height: max(12, size.height + extraBottom)
        )
    }

    private func pointerEntered() {
        hoverTask?.cancel()
        guard preferences.openOnHover else { return }
        guard model.presentation != .expanded else { return }
        guard hoverTriggerRect.contains(NSEvent.mouseLocation) else { return }

        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Preferences.shared.hoverDelay))
            guard !Task.isCancelled, let self else { return }
            // Re-check after the delay: the pointer may have moved on, and a
            // tracking-area exit is not guaranteed to have arrived first.
            guard self.hoverTriggerRect.contains(NSEvent.mouseLocation) else { return }
            self.model.expand()
        }
    }

    /// Whichever rect the notch currently occupies and can be opened from.
    private var hoverTriggerRect: CGRect {
        model.presentation == .peek ? peekTriggerRect : restingTriggerRect
    }

    private func pointerExited() {
        // Re-evaluate rather than closing outright: a crossing event can arrive
        // while the pointer is still inside the rect the pill occupies now, for
        // instance when the tracking area is rebuilt mid-hover.
        updateHover(at: NSEvent.mouseLocation)
    }

    /// Pointer tracking.
    ///
    /// A tracking area alone is not enough. Its rect is captured when the area
    /// is installed, it only reports crossings rather than positions, and a
    /// borderless non-activating panel does not always get the crossing at all.
    /// Watching the pointer directly makes hover a pure function of where the
    /// cursor actually is, and the tracking area stays as a redundant trigger.
    ///
    /// Global monitors see events routed to *other* apps; local monitors see
    /// the ones AppKit routes to us. Neither alone covers the pointer crossing
    /// into and back out of the panel, so both are installed.
    private func installClickMonitors() {
        // Drags are deliberately excluded: `DragMonitor` owns that gesture, and
        // letting hover react to it too would fight the drop-target banner.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            clickMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            handleClickOutside(at: location)
        default:
            followMouseAcrossDisplays(to: location)
            updateHover(at: location)
        }
    }

    /// Moves the panel to whichever display the pointer is on.
    ///
    /// Only while resting: yanking an open panel onto another screen mid-read
    /// would be worse than leaving it where it is, and the pointer has to leave
    /// the panel to reach another display anyway, which closes it first.
    private func followMouseAcrossDisplays(to location: CGPoint) {
        guard preferences.displayTarget == .followMouse,
              model.presentation.isResting,
              NSScreen.screens.count > 1,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
              screen.persistentID != model.geometry.screenID
        else { return }

        relayout(on: screen)
        applyFullScreenBehaviour()
    }

    /// Single source of truth for hover, evaluated against live geometry.
    private func updateHover(at location: CGPoint) {
        switch model.presentation {
        case .idle, .compact:
            let inside = restingTriggerRect.contains(location)
            guard inside != isPointerInTrigger else { return }
            isPointerInTrigger = inside
            inside ? pointerEntered() : hoverTask?.cancel()

        // A banner is a notification on a timer. The pointer did not put it
        // there and must not take it away — this used to fall into the branch
        // below, so nudging the mouse after pressing a volume key retracted the
        // HUD instantly, which is the one moment the reading is being looked at.
        //
        // Moving *onto* it still opens the panel, because at that point the
        // pointer is asking for something.
        case .peek:
            let inside = peekTriggerRect.contains(location)
            guard inside != isPointerInTrigger else { return }
            isPointerInTrigger = inside
            inside ? pointerEntered() : hoverTask?.cancel()

        case .expanded:
            isPointerInTrigger = false
            guard !openHoverRect.contains(location) else { return }
            hoverTask?.cancel()
            model.collapse()
        }
    }

    /// The banner's own rect, padded below like the resting one so the pointer
    /// can arrive from the content area rather than only along the bezel.
    private var peekTriggerRect: CGRect {
        let size = model.size(for: .peek)
        let closed = model.geometry.closedRect
        return CGRect(
            x: closed.midX - size.width / 2,
            y: closed.maxY - size.height - NotchGeometry.restingHoverExtraBottom,
            width: size.width,
            height: size.height + NotchGeometry.restingHoverExtraBottom
        )
    }

    /// While open, the pointer may roam the whole panel. The shadow margin is
    /// trimmed so leaving by a pixel does not keep it alive.
    private var openHoverRect: CGRect {
        model.geometry.windowFrame.insetBy(dx: NotchGeometry.shadowPadding / 2, dy: 0)
    }

    private func handleClickOutside(at location: CGPoint) {
        guard !model.presentation.isResting else {
            // Hover is off, so a click on the pill is the only way in.
            guard !preferences.openOnHover,
                  model.geometry.closedRect.insetBy(dx: -6, dy: -4).contains(location)
            else { return }
            model.expand()
            return
        }

        guard !model.geometry.windowFrame.contains(location) else { return }
        model.collapse()
    }

    // MARK: - Drag and drop

    private func installDragMonitor() {
        let monitor = DragMonitor()

        monitor.onEnter = { [weak self] in
            guard let self, Preferences.shared.shelfEnabled else { return }
            self.model.isDropTargeted = true
            self.model.beginDropTargeting()
            Haptics.tap()
        }

        monitor.onExit = { [weak self] in
            guard let self else { return }
            self.model.isDropTargeted = false
            self.model.endDropTargeting()
        }

        // Mouse-up and the drop itself are not the same event: SwiftUI delivers
        // the payload asynchronously afterwards. Collapsing straight away means
        // the panel closes and then reopens as the files land. Waiting a beat
        // lets a real drop cancel the collapse entirely.
        monitor.onFinish = { [weak self] in
            guard let self else { return }
            self.model.isDropTargeted = false
            self.dropSettleTask?.cancel()
            self.dropSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, let self else { return }
                guard self.model.activity == .dropTarget else { return }
                self.model.endDropTargeting()
            }
        }

        monitor.hitTest = { [weak self] point in
            guard let self else { return false }
            return self.model.geometry
                .dragCatchRect(active: self.model.activity == .dropTarget)
                .contains(point)
        }

        monitor.start()
        dragMonitor = monitor
    }

    /// Called by the SwiftUI drop handler once files actually land.
    ///
    /// Stays open rather than flashing a banner: the pointer is over the panel
    /// by definition, and what someone wants immediately after dropping is to
    /// see what they dropped — and often to drop another one.
    func didDrop(urls: [URL]) {
        dropSettleTask?.cancel()

        var added = 0
        withAnimation(Motion.open(preferences.motion)) {
            added = shelf.add(contentsOf: urls)
        }
        guard added > 0 else { return }

        model.cancelActivity()
        model.tab = .shelf
        model.expand()
    }

    /// Files that arrived over AirDrop, on their way to the shelf.
    ///
    /// Deliberately quieter than a drag-and-drop: the banner has already said
    /// what happened, and throwing the panel open over whatever someone is
    /// doing is not a reasonable response to another machine sending them a
    /// file. It goes on the shelf and waits there.
    func receiveAirDrop(_ urls: [URL]) {
        var added = 0
        withAnimation(Motion.open(preferences.motion)) {
            added = shelf.add(contentsOf: urls)
        }
        guard added > 0 else { return }
        model.tab = .shelf
    }

    func airDropShelf() {
        AirDrop.send(shelf.urls, from: hostingView)
    }

    func airDrop(_ item: ShelfItem) {
        AirDrop.send([shelf.url(for: item)], from: hostingView)
    }

    /// Sends dropped files straight on without copying them to the shelf.
    ///
    /// The panel closes first: the share sheet is modal-ish and having the
    /// notch hanging open behind it just gets in the way.
    func airDrop(files urls: [URL]) {
        guard !urls.isEmpty else { return }
        dropSettleTask?.cancel()

        // Present first: AirDrop anchors its window to this view, and tearing
        // the panel down underneath it is what makes the sheet fail to appear.
        AirDrop.send(urls, from: hostingView, anchor: airDropAnchor)

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.model.cancelActivity()
            self.model.collapse()
        }
    }

    /// Bottom-centre of the visible panel, in hosting-view coordinates, so the
    /// share picker points at the notch rather than at a window corner.
    private var airDropAnchor: CGRect {
        guard let hostingView else { return .zero }
        let size = model.contentSize
        let x = (hostingView.bounds.width - size.width) / 2
        let y = hostingView.isFlipped ? size.height : hostingView.bounds.height - size.height
        return CGRect(x: x, y: y, width: size.width, height: 1)
    }
}
