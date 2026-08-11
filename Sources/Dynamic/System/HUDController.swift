import AppKit
import Observation

/// Replaces the system volume and brightness HUDs with the notch.
///
/// The only way to stop macOS drawing its own overlay is to take the key event
/// before the window server hands it on, act on it ourselves, and swallow it.
/// That means a `CGEventTap`, which means Accessibility permission — there is
/// no version of this feature without it, so the state is surfaced rather than
/// failing quietly.
///
/// Permission can be granted, revoked, or invalidated by a re-signed build at
/// any moment, and macOS posts no notification when it changes. The controller
/// therefore *supervises* rather than installs once: it reconciles what the
/// preferences want against what the system currently allows, and acts the
/// moment those two agree. Granting permission in System Settings arms the tap
/// without relaunching.
///
/// Keys we do not fully own are deliberately passed through: keyboard backlight
/// has no readable level, and the media keys are better left to whatever the
/// system thinks is playing.
@MainActor
@Observable
final class HUDController {
    static let shared = HUDController()

    private enum Key: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    private(set) var isRunning = false
    /// Observable so the settings window's warning disappears by itself the
    /// instant permission lands.
    private(set) var isTrusted = AXIsProcessTrusted()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var model: NotchViewModel?

    private var supervisor: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    var hasPermission: Bool { isTrusted }

    // MARK: - Lifecycle

    func start(model: NotchViewModel) {
        self.model = model
        observeActivation()
        reconcile()
        superviseIfNeeded()
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        teardownTap()
    }

    /// Called when the preference changes.
    func preferencesChanged() {
        reconcile()
        superviseIfNeeded()
    }

    /// Prompts for Accessibility, showing the system's own explanation sheet.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Supervision

    /// Coming back to any app is a strong hint that the user just finished in
    /// System Settings, so it is worth an immediate check rather than waiting
    /// out the poll interval.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Polls, because there is no notification for a TCC change. Fast while the
    /// user is plausibly in System Settings, then slow, because someone may
    /// grant permission an hour later and the feature should still come alive.
    private func superviseIfNeeded() {
        guard supervisor == nil, Preferences.shared.hudEnabled, !isRunning else { return }

        supervisor = Task { [weak self] in
            var elapsed: Duration = .zero

            while !Task.isCancelled {
                guard let self else { return }
                guard Preferences.shared.hudEnabled, !self.isRunning else {
                    self.supervisor = nil
                    return
                }

                let interval: Duration = elapsed < .seconds(60) ? .seconds(1) : .seconds(5)
                try? await Task.sleep(for: interval)
                elapsed += interval

                guard !Task.isCancelled else { return }
                self.reconcile()
            }
        }
    }

    /// Brings the tap into line with what is wanted and what is permitted.
    private func reconcile() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }

        let wanted = Preferences.shared.hudEnabled && trusted

        if wanted, !isRunning {
            installTap()
        } else if !wanted, isRunning {
            teardownTap()
        }

        if isRunning {
            supervisor?.cancel()
            supervisor = nil
        }
    }

    // MARK: - Tap

    private func installTap() {
        guard tap == nil else { return }

        // `.cgSessionEventTap` at `.headInsertEventTap` puts us ahead of the
        // system's own handler, which is the only position from which the
        // overlay can be suppressed.
        let mask = CGEventMask(1 << NX_SYSDEFINED)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<HUDController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    controller.handle(proxy: proxy, type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("could not create the media-key event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
        Log.app.info("HUD replacement active")
    }

    private func teardownTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // A tap that takes too long gets disabled by the system; re-arming is
        // the documented recovery and cheaper than losing the feature.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard
            type.rawValue == UInt32(NX_SYSDEFINED),
            let systemEvent = NSEvent(cgEvent: event),
            systemEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let data = systemEvent.data1
        let code = Int32((data & 0xFFFF_0000) >> 16)
        let flags = data & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (flags & 0x1) == 1

        guard let key = Key(rawValue: code) else {
            return Unmanaged.passUnretained(event)
        }
        // Act on press and on auto-repeat, ignore the matching release.
        guard isDown || isRepeat else { return nil }

        switch key {
        case .soundUp: adjustVolume(up: true)
        case .soundDown: adjustVolume(up: false)
        case .mute: toggleMute()
        case .brightnessUp, .brightnessDown:
            guard adjustBrightness(up: key == .brightnessUp) else {
                // Nothing we can do here, so let the system have its HUD.
                return Unmanaged.passUnretained(event)
            }
        }

        // Swallowed: the system draws no overlay for an event it never sees.
        return nil
    }

    // MARK: - Actions

    private func adjustVolume(up: Bool) {
        let volume = SystemVolume.shared
        guard volume.isAvailable else { return }

        // Sixteen notches, matching the hardware keys.
        let next = volume.level + (up ? 1 : -1) / 16
        volume.set(level: next)
        showVolume()
    }

    private func toggleMute() {
        SystemVolume.shared.toggleMute()
        showVolume()
    }

    private func showVolume() {
        let volume = SystemVolume.shared
        let level = volume.isMuted ? 0 : Double(volume.level)
        model?.presentLevel(HUDInfo(
            symbol: volume.isMuted ? "speaker.slash.fill" : Self.speakerSymbol(for: level),
            value: level,
            tint: .white
        ))
    }

    private func adjustBrightness(up: Bool) -> Bool {
        guard let level = Brightness.step(up: up) else { return false }
        model?.presentLevel(HUDInfo(
            symbol: "sun.max.fill",
            value: Double(level),
            tint: .white
        ))
        return true
    }

    private static func speakerSymbol(for level: Double) -> String {
        switch level {
        case ..<0.001: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
