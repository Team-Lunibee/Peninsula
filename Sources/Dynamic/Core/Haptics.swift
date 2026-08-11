import AppKit

/// Force Touch trackpad feedback. No-ops on hardware without a haptic trackpad,
/// so callers never need to check.
enum Haptics {
    @MainActor
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard Preferences.shared.hapticFeedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
