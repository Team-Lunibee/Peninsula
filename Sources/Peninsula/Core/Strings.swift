import Foundation

/// Localised strings that a view body reads on every frame.
///
/// `String(localized:)` is a table lookup in `Bundle.main`, and for a key backed
/// by a `.stringsdict` it is a plural-rule evaluation as well. That is a fine
/// price to pay once; it is not a fine price to pay sixty times a second, which
/// is what happens when the call sits in a computed property that a transition
/// re-evaluates on every frame.
///
/// Caching them for the lifetime of the process is safe, not merely convenient.
/// A language change cannot land underneath a running app: `AppLanguage` writes
/// `AppleLanguages` into this app's own defaults, and macOS reads that *before*
/// the bundle's string tables are loaded, so the choice only takes effect on the
/// next launch — which the picker says outright.
///
/// Only the strings on a hot path belong here. Anything shown once, in settings
/// or a menu, stays inline where it is easier to read.
enum Strings {
    // Banners. Re-evaluated on every frame a peek is on screen.
    static let nowPlaying = String(localized: "Now Playing")
    static let dropToKeep = String(localized: "Drop to keep")
    static let letGo = String(localized: "Let go over the notch")
    static let getThemBack = String(localized: "Open the notch to get them back")

    // The header's lyrics button. Its tooltip is a computed property, so the
    // lookup ran on every frame of every expansion.
    static let lookingForLyrics = String(localized: "Looking for lyrics…")
    static let showLyrics = String(localized: "Show lyrics")
    static let hideLyrics = String(localized: "Hide lyrics")
    static let noSyncedLyrics = String(localized: "No synced lyrics found for this track")

    // Drop zones. Rebuilt on every drag update while a file is in flight.
    static let keepOnShelf = String(localized: "Keep on shelf")
    static let sendStraightAway = String(localized: "Send straight away")

    static let unknownArtist = String(localized: "Unknown artist")
}
