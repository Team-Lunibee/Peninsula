import AppKit
import Intents
import Observation

/// Whether a Focus is currently on.
///
/// Reading uses `INFocusStatusCenter`, the only public surface for this — the
/// Focus database under `~/Library/DoNotDisturb` is TCC-protected and would
/// cost the user Full Disk Access. The trade is that the system tells us *that*
/// a Focus is on, never which one, which is all an indicator needs.
///
/// Deliberately read-only. There is no public API to turn Focus on or off, and
/// the alternatives — driving Control Centre through Accessibility, or writing
/// into the Focus database directly — are the kind of thing that breaks on a
/// point release and takes the user's notification settings with it. Showing
/// the state is genuinely useful; pretending to control it is not worth that.
@MainActor
@Observable
final class FocusMonitor {
    private(set) var isFocused = false
    private(set) var authorization: INFocusStatusAuthorizationStatus = .notDetermined

    var isAuthorized: Bool { authorization == .authorized }

    /// What the system currently says, in words, so the settings window can be
    /// specific instead of just failing to light up.
    var statusDescription: String {
        switch authorization {
        case .notDetermined: "아직 권한을 요청하지 않았습니다."
        case .restricted: "이 기기의 정책이 집중 모드 상태 접근을 막고 있습니다."
        case .denied: "거부됨 — 시스템 설정 › 개인정보 보호 및 보안 › 집중 모드에서 Dynamic을 켜 주세요."
        case .authorized:
            isFocused ? "집중 모드가 켜져 있습니다." : "허용됨 — 지금은 집중 모드가 꺼져 있습니다."
        @unknown default: "알 수 없는 상태입니다."
        }
    }

    /// Called when Focus turns on or off — never for the initial read.
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var hasReadOnce = false
    private var authorizationReadAt: Date?

    /// Focus changes are not observable, so this polls. Reading the *status* is
    /// an in-process property, so the interval is about responsiveness rather
    /// than cost. Returning to any app also forces a read, which covers the
    /// common case: toggle Focus in Control Centre, go back to work.
    private static let interval: TimeInterval = 8

    /// How long a cached authorization answer is trusted.
    ///
    /// `INFocusStatusCenter.authorizationStatus` is not a property read: it
    /// makes two *synchronous* XPC round trips to `tccd`, and it was doing so
    /// on every poll and every app switch — measured at 0.4% of the main
    /// thread, permanently, blocking it each time. The value only changes when
    /// the user visits System Settings, so re-reading it on this cadence
    /// notices a grant within a minute while costing effectively nothing.
    private static let authorizationLifetime: TimeInterval = 60

    func start() {
        refresh()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Forces the next read to go back to TCC. Called when the user has just
    /// been sent to System Settings, where the answer is about to change.
    func invalidateAuthorizationCache() {
        authorizationReadAt = nil
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func requestAuthorization() {
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = status
                self.authorizationReadAt = Date()
                self.refresh()
            }
        }
    }

    private func refreshAuthorizationIfStale() {
        if let authorizationReadAt,
           Date().timeIntervalSince(authorizationReadAt) < Self.authorizationLifetime {
            return
        }
        authorization = INFocusStatusCenter.default.authorizationStatus
        authorizationReadAt = Date()
    }

    private func refresh() {
        refreshAuthorizationIfStale()

        guard isAuthorized else {
            isFocused = false
            hasReadOnce = false
            return
        }

        let focused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        let isFirstRead = !hasReadOnce
        hasReadOnce = true

        guard focused != isFocused else { return }
        isFocused = focused

        // The first successful read is the current state, not a change — it
        // would otherwise announce "Focus on" every time the app launches.
        guard !isFirstRead else { return }
        onChange?(focused)
    }
}
