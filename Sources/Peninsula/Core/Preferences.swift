import Foundation
import Observation

enum NotchHeightMode: String, CaseIterable, Identifiable {
    case matchRealNotch
    case matchMenuBar
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .matchRealNotch: String(localized: "Match the notch")
        case .matchMenuBar: String(localized: "Match the menu bar")
        case .custom: String(localized: "Custom")
        }
    }
}

/// What to do on a display that has no camera housing to hide behind.
enum ExternalDisplayStyle: String, CaseIterable, Identifiable {
    /// Hug the top edge and draw the cutout shape anyway. Overlaps the menu
    /// bar, but keeps every display looking like the built-in one.
    case notch
    /// Sit inside the menu bar as a rounded pill, the way the Dynamic Island
    /// sits inside the iPhone status bar.
    case floating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notch: String(localized: "Flush with the top, like a notch")
        case .floating: String(localized: "A pill inside the menu bar")
        }
    }
}

/// Which display the notch lives on when there is more than one.
enum DisplayTarget: String, CaseIterable, Identifiable {
    /// The built-in display if it has a cutout, otherwise the primary one.
    case automatic
    /// Move to whichever display the pointer is on.
    case followMouse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Screen with the notch")
        case .followMouse: String(localized: "The screen with the pointer")
        }
    }
}

enum MotionPreset: String, CaseIterable, Identifiable {
    case snappy
    case bouncy
    case gentle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snappy: String(localized: "Like the Island")
        case .bouncy: String(localized: "Bouncy")
        case .gentle: String(localized: "Gentle")
        }
    }
}

enum IdleStyle: String, CaseIterable, Identifiable {
    case plain
    case miniMedia
    case clock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: String(localized: "Nothing")
        case .miniMedia: String(localized: "The current track")
        case .clock: String(localized: "A clock")
        }
    }
}

/// UserDefaults-backed settings. Every property is observable, so SwiftUI views
/// re-render the moment a value changes in the settings window.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: Appearance

    var heightMode: NotchHeightMode { didSet { write(heightMode.rawValue, .heightMode) } }
    var customHeight: Double { didSet { write(customHeight, .customHeight) } }
    var idleStyle: IdleStyle { didSet { write(idleStyle.rawValue, .idleStyle) } }
    var externalDisplayStyle: ExternalDisplayStyle { didSet { write(externalDisplayStyle.rawValue, .externalDisplayStyle) } }
    var displayTarget: DisplayTarget { didSet { write(displayTarget.rawValue, .displayTarget) } }
    var tintFromArtwork: Bool { didSet { write(tintFromArtwork, .tintFromArtwork) } }

    // MARK: Behaviour

    var openOnHover: Bool { didSet { write(openOnHover, .openOnHover) } }
    var hoverDelay: Double { didSet { write(hoverDelay, .hoverDelay) } }
    var motion: MotionPreset { didSet { write(motion.rawValue, .motion) } }
    var hideFromScreenRecording: Bool { didSet { write(hideFromScreenRecording, .hideFromScreenRecording) } }
    var hapticFeedback: Bool { didSet { write(hapticFeedback, .hapticFeedback) } }

    // MARK: Features

    var mediaEnabled: Bool { didSet { write(mediaEnabled, .mediaEnabled) } }
    var visualizerEnabled: Bool { didSet { write(visualizerEnabled, .visualizerEnabled) } }
    var animateRestingMeter: Bool { didSet { write(animateRestingMeter, .animateRestingMeter) } }
    var shelfEnabled: Bool { didSet { write(shelfEnabled, .shelfEnabled) } }
    var shelfExpiryDays: Int { didSet { write(shelfExpiryDays, .shelfExpiryDays) } }
    var powerActivitiesEnabled: Bool { didSet { write(powerActivitiesEnabled, .powerActivitiesEnabled) } }
    var fileActivitiesEnabled: Bool { didSet { write(fileActivitiesEnabled, .fileActivitiesEnabled) } }
    var deviceActivitiesEnabled: Bool { didSet { write(deviceActivitiesEnabled, .deviceActivitiesEnabled) } }
    var hudEnabled: Bool { didSet { write(hudEnabled, .hudEnabled) } }
    var mediaIdleTimeout: Double { didSet { write(mediaIdleTimeout, .mediaIdleTimeout) } }
    var lyricsEnabled: Bool { didSet { write(lyricsEnabled, .lyricsEnabled) } }
    var showLyrics: Bool { didSet { write(showLyrics, .showLyrics) } }
    var airDropToShelf: Bool { didSet { write(airDropToShelf, .airDropToShelf) } }

    private init() {
        defaults.register(defaults: [
            Key.heightMode.rawValue: NotchHeightMode.matchRealNotch.rawValue,
            Key.customHeight.rawValue: 32.0,
            Key.idleStyle.rawValue: IdleStyle.miniMedia.rawValue,
            Key.externalDisplayStyle.rawValue: ExternalDisplayStyle.notch.rawValue,
            Key.displayTarget.rawValue: DisplayTarget.automatic.rawValue,
            Key.tintFromArtwork.rawValue: true,
            Key.openOnHover.rawValue: true,
            Key.hoverDelay.rawValue: 0.2,
            Key.motion.rawValue: MotionPreset.snappy.rawValue,
            Key.hideFromScreenRecording.rawValue: false,
            Key.hapticFeedback.rawValue: false,
            Key.mediaEnabled.rawValue: true,
            Key.visualizerEnabled.rawValue: true,
            Key.animateRestingMeter.rawValue: true,
            Key.shelfEnabled.rawValue: true,
            Key.shelfExpiryDays.rawValue: 7,
            Key.powerActivitiesEnabled.rawValue: true,
            Key.fileActivitiesEnabled.rawValue: true,
            Key.deviceActivitiesEnabled.rawValue: true,
            Key.hudEnabled.rawValue: false,
            Key.mediaIdleTimeout.rawValue: 30.0,
            Key.lyricsEnabled.rawValue: true,
            Key.showLyrics.rawValue: true,
            Key.airDropToShelf.rawValue: true,
        ])

        heightMode = NotchHeightMode(rawValue: defaults.string(forKey: Key.heightMode.rawValue) ?? "")
            ?? .matchRealNotch
        customHeight = defaults.double(forKey: Key.customHeight.rawValue)
        idleStyle = IdleStyle(rawValue: defaults.string(forKey: Key.idleStyle.rawValue) ?? "") ?? .miniMedia
        externalDisplayStyle = ExternalDisplayStyle(
            rawValue: defaults.string(forKey: Key.externalDisplayStyle.rawValue) ?? ""
        ) ?? .notch
        displayTarget = DisplayTarget(
            rawValue: defaults.string(forKey: Key.displayTarget.rawValue) ?? ""
        ) ?? .automatic
        tintFromArtwork = defaults.bool(forKey: Key.tintFromArtwork.rawValue)
        openOnHover = defaults.bool(forKey: Key.openOnHover.rawValue)
        hoverDelay = defaults.double(forKey: Key.hoverDelay.rawValue)
        motion = MotionPreset(rawValue: defaults.string(forKey: Key.motion.rawValue) ?? "") ?? .bouncy
        hideFromScreenRecording = defaults.bool(forKey: Key.hideFromScreenRecording.rawValue)
        hapticFeedback = defaults.bool(forKey: Key.hapticFeedback.rawValue)
        mediaEnabled = defaults.bool(forKey: Key.mediaEnabled.rawValue)
        visualizerEnabled = defaults.bool(forKey: Key.visualizerEnabled.rawValue)
        animateRestingMeter = defaults.bool(forKey: Key.animateRestingMeter.rawValue)
        shelfEnabled = defaults.bool(forKey: Key.shelfEnabled.rawValue)
        shelfExpiryDays = defaults.integer(forKey: Key.shelfExpiryDays.rawValue)
        powerActivitiesEnabled = defaults.bool(forKey: Key.powerActivitiesEnabled.rawValue)
        fileActivitiesEnabled = defaults.bool(forKey: Key.fileActivitiesEnabled.rawValue)
        deviceActivitiesEnabled = defaults.bool(forKey: Key.deviceActivitiesEnabled.rawValue)
        hudEnabled = defaults.bool(forKey: Key.hudEnabled.rawValue)
        mediaIdleTimeout = defaults.double(forKey: Key.mediaIdleTimeout.rawValue)
        lyricsEnabled = defaults.bool(forKey: Key.lyricsEnabled.rawValue)
        showLyrics = defaults.bool(forKey: Key.showLyrics.rawValue)
        airDropToShelf = defaults.bool(forKey: Key.airDropToShelf.rawValue)
    }

    private enum Key: String {
        case heightMode, customHeight, idleStyle, tintFromArtwork
        case externalDisplayStyle, displayTarget
        case openOnHover, hoverDelay, motion, hideFromScreenRecording, hapticFeedback
        case mediaEnabled, visualizerEnabled, animateRestingMeter, shelfEnabled, shelfExpiryDays
        case powerActivitiesEnabled, fileActivitiesEnabled, deviceActivitiesEnabled
        case hudEnabled, lyricsEnabled, showLyrics, mediaIdleTimeout
        case airDropToShelf
    }

    private func write(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
