import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService`.
///
/// The system owns this state, not our preferences file — someone can turn the
/// login item off in System Settings › General › Login Items and we have to
/// reflect that rather than fight it. Every read goes to launchd.
@MainActor
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    static var isEnabled: Bool {
        service.status == .enabled
    }

    /// `true` when macOS has the registration but the user has disabled it in
    /// System Settings, which we cannot override from here.
    static var isBlockedByUser: Bool {
        service.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Registering while already enabled throws, and toggling quickly is
            // an easy way to hit that.
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    /// Human-readable state for the settings window.
    static var explanation: String? {
        switch service.status {
        case .requiresApproval:
            "시스템 설정 › 일반 › 로그인 항목에서 Dynamic을 허용해야 합니다."
        case .notFound:
            "로그인 항목을 등록할 수 없습니다. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도해 보세요."
        default:
            nil
        }
    }

    /// Login items are registered by path, so an app run from a build folder
    /// will stop launching the moment that folder moves.
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
