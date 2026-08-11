import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let media = MediaEngine()
    private let shelf = ShelfStore()
    private let activities = LiveActivityCenter()
    private let bluetooth = BluetoothBattery()
    private let hud = HUDController.shared
    private let focus = FocusMonitor()
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [Task<Void, Never>] = []
    private var hasShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController(
            media: media, shelf: shelf, bluetooth: bluetooth, focus: focus
        )
        controller.start()
        self.controller = controller

        bluetooth.onConnect = { [weak controller] device in
            guard Preferences.shared.deviceActivitiesEnabled, let controller else { return }
            controller.model.present(.info(ActivityInfo(
                symbol: device.symbol,
                tint: device.isLow ? .orange : .white,
                title: device.name,
                subtitle: "연결됨",
                trailingValue: device.headline.map { "\($0)%" }
            )))
        }
        bluetooth.start()

        focus.onChange = { [weak controller] isFocused in
            guard Preferences.shared.focusEnabled, let controller else { return }
            controller.model.present(
                .info(ActivityInfo(
                    symbol: isFocused ? "moon.fill" : "moon.zzz",
                    tint: isFocused ? .purple : .white,
                    title: isFocused ? "집중 모드 켜짐" : "집중 모드 꺼짐",
                    subtitle: nil,
                    trailingValue: nil
                )),
                for: 1.8
            )
        }

        if Preferences.shared.focusEnabled {
            focus.start()
        }
        // Turning the feature on in settings has to start the monitor, or it
        // stays off until the next launch — and the permission prompt with it.
        observers.append(
            observeChanges { _ = Preferences.shared.focusEnabled } onChange: { [weak self] in
                guard let self else { return }
                Preferences.shared.focusEnabled ? self.focus.start() : self.focus.stop()
            }
        )
        hud.start(model: controller.model)

        if Preferences.shared.mediaEnabled {
            media.start()
        }
        activities.onAirDropReceived = { [weak controller] urls in
            controller?.receiveAirDrop(urls)
        }
        activities.start(model: controller.model)

        installStatusItem()
        installSignalHandlers()
        schedulePruning()
        Bench.startIfRequested(model: controller.model)

        Log.app.info("Dynamic launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
    }

    /// AppKit never runs `applicationWillTerminate` for a signal, so `pkill`,
    /// Force Quit and a terminal Ctrl-C would all strand the adapter's perl
    /// child. Catching the signals ourselves keeps that from happening.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            // The default disposition kills the process outright, so the
            // handler has to replace it before the source can observe anything.
            signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.shutDown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutDown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        pruneTimer?.invalidate()
        observers.forEach { $0.cancel() }
        observers.removeAll()
        activities.stop()
        bluetooth.stop()
        focus.stop()
        hud.stop()
        media.stop()
        controller?.stop()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Dynamic"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(
            withTitle: "노치 열기",
            action: #selector(openNotch),
            keyEquivalent: ""
        ).target = self

        menu.addItem(.separator())

        let mediaItem = menu.addItem(
            withTitle: "재생 중 표시",
            action: #selector(toggleMedia),
            keyEquivalent: ""
        )
        mediaItem.target = self
        mediaItem.tag = MenuTag.media.rawValue

        let shelfItem = menu.addItem(
            withTitle: "파일 선반",
            action: #selector(toggleShelf),
            keyEquivalent: ""
        )
        shelfItem.target = self
        shelfItem.tag = MenuTag.shelf.rawValue

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "설정…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self

        menu.addItem(
            withTitle: "Dynamic 종료",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self

        return menu
    }

    private enum MenuTag: Int {
        case media = 1
        case shelf = 2
    }

    @objc private func openNotch() {
        controller?.model.expand()
    }

    @objc private func toggleMedia() {
        let enabled = !Preferences.shared.mediaEnabled
        Preferences.shared.mediaEnabled = enabled
        enabled ? media.start() : media.stop()
    }

    @objc private func toggleShelf() {
        Preferences.shared.shelfEnabled.toggle()
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    /// Called from Settings. Turning the HUD on may need permission the app
    /// does not have yet, so this prompts and then leaves the controller to
    /// arm itself once the grant actually lands.
    func refreshHUD() {
        if Preferences.shared.hudEnabled, !hud.hasPermission {
            hud.requestPermission()
        }
        hud.preferencesChanged()
    }

    var focusMonitor: FocusMonitor { focus }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Housekeeping

    /// Shelf items expire on a clock, so a long-running session needs a nudge
    /// rather than relying on the launch-time sweep alone.
    private func schedulePruning() {
        shelf.prune()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shelf.prune()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MenuTag.media.rawValue)?.state =
            Preferences.shared.mediaEnabled ? .on : .off
        menu.item(withTag: MenuTag.shelf.rawValue)?.state =
            Preferences.shared.shelfEnabled ? .on : .off
    }
}
