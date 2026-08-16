import Foundation

/// The language the app draws itself in, independent of the rest of the system.
///
/// macOS reads `AppleLanguages` from an app's own defaults *before* the bundle's
/// string tables are loaded, so a change here can only take effect on the next
/// launch — there is no supported way to swap a loaded `.lproj` underneath a
/// running process. The picker says so rather than pretending otherwise.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ko
    case ja
    case zhHans = "zh-Hans"
    case es
    case fr
    case de

    var id: String { rawValue }

    /// Every name is written in its own language. Someone who has ended up with
    /// the app in a language they cannot read still has to find their way back,
    /// and "Korean" is no help to them — "한국어" is.
    var label: String {
        switch self {
        case .system: String(localized: "Match the system")
        case .en: "English"
        case .ko: "한국어"
        case .ja: "日本語"
        case .zhHans: "简体中文"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        }
    }

    private static let key = "AppleLanguages"

    /// Read from this app's own persistent domain, not through
    /// `UserDefaults.standard`.
    ///
    /// A plain lookup falls through to NSGlobalDomain, where `AppleLanguages` is
    /// always present — the system's own list. Every install would then report
    /// whatever the Mac is set to instead of "Match the system", and the picker
    /// would show a choice the user never made.
    static var current: AppLanguage {
        guard
            let identifier = Bundle.main.bundleIdentifier,
            let domain = UserDefaults.standard.persistentDomain(forName: identifier),
            let codes = domain[key] as? [String],
            let first = codes.first
        else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    static func select(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }
}
