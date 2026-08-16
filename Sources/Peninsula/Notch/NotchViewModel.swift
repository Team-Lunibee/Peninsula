import AppKit
import Observation
import SwiftUI

/// The notch's presentation states, mirroring how the Dynamic Island layers its
/// own: nothing, a sliver, a banner, the full sheet.
///
/// The distinction between `idle` and `compact` is the one that matters. On a
/// MacBook the cutout is a physical hole, not pixels, so it can never actually
/// grow — but a black shape that starts *exactly* at the cutout's boundary and
/// expands from there is indistinguishable from one that does. That only works
/// if the resting state is exactly the cutout and nothing more. Padding the
/// resting pill out to hold indicators is what turns it back into a visible
/// black bar sitting on the bezel.
enum NotchPresentation: Equatable {
    /// Exactly the hardware cutout. Invisible on a notched Mac.
    case idle
    /// Grown just enough for slivers either side of the cutout.
    case compact
    /// A transient banner — a track change, files landing on the shelf.
    case peek
    /// The full panel.
    case expanded

    var isResting: Bool { self == .idle || self == .compact }
}

/// A banner with nothing bespoke about it — a charger plugged in, a download
/// finished, a pair of earbuds connected. Everything that is just "icon, some
/// words, maybe a number" shares one shape instead of growing another case.
struct ActivityInfo: Equatable {
    /// Leading glyph. `nil` draws none — the real island's charging banner is
    /// text on the left and the reading on the right, with no badge at all,
    /// and a circle in front of the words only makes it noisier.
    var symbol: String?
    var tint: Color
    var title: String
    var subtitle: String?
    /// Shown as a large trailing figure — a battery percentage, a count.
    var trailingValue: String?
    /// 0 to 1. Draws a battery filled to that level after the figure.
    var level: Double?
}

/// A volume or brightness reading. Separate from `ActivityInfo` because it
/// updates many times a second while a key is held, and needs a path that does
/// not restart the container animation on every step.
struct HUDInfo: Equatable {
    var symbol: String
    /// 0 to 1.
    var value: Double
    var tint: Color
}

enum NotchActivity: Equatable {
    case trackChanged
    case filesAdded(count: Int)
    case dropTarget
    case info(ActivityInfo)
    case level(HUDInfo)

    /// Two activities of the same kind can replace each other inside a banner
    /// that is already on screen. Different kinds cannot: a download finishing
    /// while a track banner is up is a separate thing to say, not a correction
    /// of the first.
    enum Kind {
        case track, files, drop, info, level
    }

    var kind: Kind {
        switch self {
        case .trackChanged: .track
        case .filesAdded: .files
        case .dropTarget: .drop
        case .info: .info
        case .level: .level
        }
    }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case media
    case shelf
    case devices

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: String(localized: "Now Playing")
        case .shelf: String(localized: "Shelf")
        case .devices: String(localized: "Devices")
        }
    }

    var symbol: String {
        switch self {
        case .media: "music.note"
        case .shelf: "tray.full"
        case .devices: "airpods.gen3"
        }
    }
}

/// Presentation state for the notch. Owned by `NotchController`, read by the
/// SwiftUI tree.
@MainActor
@Observable
final class NotchViewModel {
    private(set) var presentation: NotchPresentation = .idle
    var geometry: NotchGeometry
    var activity: NotchActivity?
    var tab: NotchTab = .media
    var isDropTargeted = false

    /// Signed squash impulse driving the jelly deformation. Positive stretches
    /// wide and flat; it springs back to zero on its own.
    var squash: CGFloat = 0

    /// False while the container is travelling between presentations.
    ///
    /// Views that host AppKit content — the meter, the AirPlay picker — are far
    /// more expensive to keep on screen while the panel resizes than SwiftUI
    /// views are, because SwiftUI has to hand each of them new geometry through
    /// AppKit on every frame. Anything that can wait for the panel to land
    /// should read this and wait.
    private(set) var isSettled = true

    private var settleTask: Task<Void, Never>?

    let media: MediaEngine
    let shelf: ShelfStore
    let bluetooth: BluetoothBattery

    /// Wired up by `NotchController`, which owns the panel and therefore the
    /// view AirDrop needs to anchor its sheet to.
    var onDrop: (([URL]) -> Void)?
    var onAirDropAll: (() -> Void)?
    /// AirDrop arbitrary files without storing them, for the drag-time zone.
    var onAirDropFiles: (([URL]) -> Void)?
    var onAirDropItem: ((ShelfItem) -> Void)?
    var onOpenSettings: (() -> Void)?

    private var activityDismissal: Task<Void, Never>?
    private var squashRelease: Task<Void, Never>?

    private var preferences: Preferences { .shared }

    init(
        geometry: NotchGeometry,
        media: MediaEngine,
        shelf: ShelfStore,
        bluetooth: BluetoothBattery
    ) {
        self.geometry = geometry
        self.media = media
        self.shelf = shelf
        self.bluetooth = bluetooth
    }

    // MARK: - Resting state

    /// Where the notch settles when nothing is happening: the bare cutout, or
    /// a slightly grown pill when there is something worth showing.
    var restingPresentation: NotchPresentation {
        showsIdleContent ? .compact : .idle
    }

    var showsIdleContent: Bool {
        switch preferences.idleStyle {
        case .plain: false
        // Dormant means playback stopped a while ago. The island retreats to
        // the bare cutout rather than sitting there forever advertising a
        // track nobody is listening to.
        case .miniMedia: preferences.mediaEnabled && media.hasTrack && !media.isDormant
        case .clock: true
        }
    }

    /// Compact indicators are sized from the pill rather than fixed, so a
    /// shorter menu bar squeezes the margins instead of the content.
    var compactArtworkEdge: CGFloat {
        max(13, geometry.closedSize.height - 13)
    }

    /// Taller than it looks like it should be.
    ///
    /// At 13pt — which is what a 19pt inset leaves in a 32pt pill — the bars
    /// have nowhere to go: a swing of three or four points reads as a row of
    /// dots twitching rather than as a meter. The pill is 32pt and the artwork
    /// beside it is 19, so there is room for a track half again as tall while
    /// still leaving a clear margin top and bottom.
    var compactMeterHeight: CGFloat {
        max(10, geometry.closedSize.height - 14)
    }

    /// Whether the resting island is carrying the current lyric line.
    ///
    /// Lyrics are the one thing worth keeping on screen permanently rather than
    /// only inside the open panel: they change on their own, they are read at a
    /// glance, and having to open something to see the line being sung defeats
    /// the point. Everything else still waits behind a hover.
    var showsCompactLyrics: Bool {
        preferences.lyricsEnabled
            && preferences.showLyrics
            && preferences.idleStyle == .miniMedia
            && media.hasTrack
            && !media.isDormant
            && media.lyrics.lyrics?.isSynced == true
    }

    /// Width added either side of the cutout in the compact state.
    ///
    /// Indicators live out here because anything drawn *inside* the cutout is
    /// behind the camera housing and therefore invisible. A lyric line needs
    /// considerably more room than a thumbnail, so the island grows for it.
    var idleSideWidth: CGFloat {
        showsCompactLyrics ? 200 : 32
    }

    /// Settles into whichever resting state currently applies. Called when
    /// playback starts or stops, so the pill grows and shrinks on its own the
    /// way the island does when a Live Activity begins.
    func settleAtRest() {
        guard presentation.isResting else { return }
        let target = restingPresentation
        guard target != presentation else { return }

        withAnimation(Motion.open(preferences.motion)) {
            presentation = target
        }
        beginSettling(opening: true)
        kickSquash(target == .compact ? 0.35 : -0.25, after: Motion.squashDelay(preferences.motion, opening: true))
    }

    // MARK: - Derived layout

    var contentSize: CGSize { size(for: presentation) }

    /// Size of a *specific* state, not the current one.
    ///
    /// Content is laid out at the size of the state it belongs to and the
    /// container clips it, so a panel that is still growing reveals finished
    /// content instead of reflowing it mid-animation. Reflowing text during a
    /// resize is the single most obvious tell that a morph is fake.
    func size(for presentation: NotchPresentation) -> CGSize {
        switch presentation {
        case .idle:
            geometry.closedSize
        case .compact:
            CGSize(
                width: geometry.closedSize.width + idleSideWidth * 2,
                height: geometry.closedSize.height
            )
        case .peek:
            // Wide enough that the regions either side of the cutout can each
            // hold something. A banner narrower than this ends up with two
            // slivers and everything important hidden behind the housing.
            CGSize(
                width: min(geometry.expandedSize.width, geometry.closedSize.width + 340),
                height: max(geometry.closedSize.height + 14, 46)
            )
        case .expanded:
            geometry.expandedSize
        }
    }

    var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        cornerRadii(for: presentation)
    }

    /// Radii of a *specific* state, so contents can be clipped to the silhouette
    /// they will end up inside rather than to the one currently on screen.
    func cornerRadii(for presentation: NotchPresentation) -> (top: CGFloat, bottom: CGFloat) {
        switch geometry.style {
        case .cutout:
            switch presentation {
            case .idle, .compact: return NotchShape.closedRadii
            case .peek: return (top: 8, bottom: 18)
            case .expanded: return NotchShape.expandedRadii
            }
        case .floating:
            // A pill at rest, a sheet when open. Both corners animate together
            // since the shape has no concave half to keep separate.
            let radius: CGFloat = switch presentation {
            case .idle, .compact: size(for: presentation).height / 2
            case .peek: 20
            case .expanded: 26
            }
            return (top: radius, bottom: radius)
        }
    }

    /// Vertical room the expanded panel must leave clear at the top.
    ///
    /// On a notched Mac the camera housing sits over this band, so content
    /// placed there is invisible; the header instead straddles it, in the
    /// leading and trailing regions either side — the same split Apple uses for
    /// the Dynamic Island's compact presentation.
    var islandRowHeight: CGFloat {
        geometry.style == .cutout ? max(geometry.closedSize.height, 30) : 30
    }

    /// Width of the untouchable gap in the middle of every row that crosses
    /// the cutout's latitude.
    ///
    /// This is the app's one inviolable rule: on a notched Mac the camera
    /// housing is a hole in the panel, so anything drawn behind it is simply
    /// not there. A banner that centres its text is invisible; a tab strip that
    /// runs past this gap loses its labels into the bezel. Every layout in that
    /// vertical band therefore splits into a leading and a trailing region with
    /// this gap held open between them.
    var islandGapWidth: CGFloat {
        geometry.style == .cutout ? geometry.closedSize.width : 0
    }

    /// How much room each region beside the cutout actually gets.
    func islandSideWidth(for presentation: NotchPresentation) -> CGFloat {
        let total = size(for: presentation).width
        let margin = presentation == .expanded ? NotchGeometry.contentMargin * 2 : 36
        return max(0, (total - margin - islandGapWidth) / 2)
    }

    /// Whether labelled tabs still fit beside the cutout.
    ///
    /// Depends on how many tabs are showing, not on a fixed threshold: two fit
    /// comfortably, and the third — which only appears when a Bluetooth device
    /// is connected — is what pushes them over. Dropping to icons is much
    /// better than truncating "Now Playing" to "Now…", and the margin has to
    /// hold for the longest translation, not just the English.
    func showsTabLabels(visibleTabs: Int) -> Bool {
        let needed = CGFloat(visibleTabs) * 74 + CGFloat(max(0, visibleTabs - 1)) * 6
        return islandSideWidth(for: .expanded) >= needed
    }

    var showsSourceName: Bool {
        islandSideWidth(for: .expanded) >= 150
    }

    var peekSideWidth: CGFloat {
        islandSideWidth(for: .peek)
    }

    // MARK: - Shared elements
    //
    // The artwork and the visualiser exist in more than one presentation, so
    // they are matched rather than cross-faded: they travel and resize between
    // states while everything else blurs in and out around them. A shared
    // element that vanishes and reappears is what makes a morph look like two
    // views swapping, which is the thing the Dynamic Island never does.
    //
    // Both flags must be false whenever any participating state would fail to
    // render the element, or the geometry match has no partner to fly to.

    /// Off, and deliberately.
    ///
    /// Matching the artwork and the meter between states was an attempt to make
    /// them *travel* rather than cross-fade. The contents now scale with the
    /// container, which produces the same thing for free and for the same
    /// reason the real island gets it for free: the two layouts are
    /// proportionally alike. The compact thumbnail sits 10pt into a 253pt pill
    /// and the expanded artwork 28pt into a 624pt sheet — 4.0% against 4.5% —
    /// so scaling one onto the other lands them within a couple of points of
    /// each other the whole way across.
    ///
    /// Keeping the geometry match on top of that would be two systems fighting
    /// for the same frames, and the match wins by overriding position inside a
    /// coordinate space the scale has already changed.
    var morphsArtwork: Bool { false }
    var morphsSpectrum: Bool { false }

    var isOpen: Bool { presentation == .expanded }

    var animation: Animation { widthAnimation }

    var widthAnimation: Animation {
        Motion.width(preferences.motion, opening: !presentation.isResting)
    }

    var heightAnimation: Animation {
        Motion.height(preferences.motion, opening: !presentation.isResting)
    }

    // MARK: - Transitions

    func expand() {
        guard presentation != .expanded else { return }
        cancelActivity()
        withAnimation(Motion.open(preferences.motion)) {
            presentation = .expanded
        }
        beginSettling(opening: true)
        // Positive: stretched wide and flat, the shape of something launching
        // outward. The container spring is near-flat, so this is the overshoot.
        kickSquash(0.8, after: Motion.squashDelay(preferences.motion, opening: true))
        // No haptic here. Opening happens on hover, which means it fires
        // whenever the pointer drifts near the top of the screen — a tap that
        // frequent stops being feedback and becomes a tic.
    }

    func collapse() {
        guard !presentation.isResting else { return }
        cancelActivity()
        withAnimation(Motion.close(preferences.motion)) {
            presentation = restingPresentation
        }
        beginSettling(opening: false)
        // Negative: pinched narrow, then springing back out to its resting
        // width. This is the horizontal recoil, and it carries the whole
        // closing gesture.
        kickSquash(-1.0, after: Motion.squashDelay(preferences.motion, opening: false))
    }

    func toggle() {
        isOpen ? collapse() : expand()
    }

    /// Shows a transient banner. Ignored while the panel is open, since the
    /// information is already on screen.
    ///
    /// A banner of the same kind arriving while one is already up is *absorbed*
    /// rather than staged behind it: the payload swaps in place and the dwell
    /// starts over. Skipping through tracks otherwise re-ran the open spring and
    /// the recoil impulse on every change — three or four deep, all interrupting
    /// each other — and the pill visibly fought itself. The island's own answer
    /// to a second event during a Live Activity is to update the one on screen.
    func present(_ activity: NotchActivity, for duration: TimeInterval = 2.4) {
        guard presentation != .expanded else { return }

        if presentation == .peek, self.activity?.kind == activity.kind {
            withAnimation(Motion.content(preferences.motion)) {
                self.activity = activity
            }
            scheduleDismissal(after: duration)
            return
        }

        activityDismissal?.cancel()
        withAnimation(Motion.activity()) {
            self.activity = activity
            presentation = .peek
        }
        beginSettling(opening: true)
        kickSquash(0.5, after: Motion.squashDelay(preferences.motion, opening: true))

        scheduleDismissal(after: duration)
    }

    private func scheduleDismissal(after duration: TimeInterval) {
        activityDismissal?.cancel()
        activityDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            guard self.presentation == .peek else { return }
            withAnimation(Motion.close(self.preferences.motion)) {
                self.activity = nil
                self.presentation = self.restingPresentation
            }
            self.beginSettling(opening: false)
            self.kickSquash(-1.0, after: Motion.squashDelay(self.preferences.motion, opening: false))
        }
    }

    /// Shows a HUD reading, or updates one already on screen.
    ///
    /// Holding a volume key fires ten times a second, so this leans entirely on
    /// `present`'s absorption — with one difference: the bar has to track the
    /// key, so the payload is assigned outside an animation rather than
    /// cross-fading each step.
    func presentLevel(_ info: HUDInfo) {
        if case .level = activity, presentation == .peek {
            activity = .level(info)
            scheduleDismissal(after: Self.hudDuration)
            return
        }
        present(.level(info), for: Self.hudDuration)
    }

    private static let hudDuration: TimeInterval = 1.4

    func cancelActivity() {
        activityDismissal?.cancel()
        activityDismissal = nil
        if activity != nil {
            activity = nil
        }
    }

    /// Opens the panel for the duration of a drag.
    ///
    /// Fully open rather than a banner: whatever is under the cursor when the
    /// button comes up is what receives the drop, so the target wants to be as
    /// large as the notch can make it.
    func beginDropTargeting() {
        guard activity != .dropTarget else { return }
        activityDismissal?.cancel()
        withAnimation(Motion.open(preferences.motion)) {
            tab = .shelf
            activity = .dropTarget
            presentation = .expanded
        }
        beginSettling(opening: true)
        kickSquash(0.45, after: Motion.squashDelay(preferences.motion, opening: true))
    }

    func endDropTargeting() {
        guard activity == .dropTarget else { return }
        withAnimation(Motion.close(preferences.motion)) {
            activity = nil
            presentation = restingPresentation
        }
        beginSettling(opening: false)
    }

    // MARK: - Jelly

    // MARK: - Settling

    /// Marks the container as travelling, and schedules it back to settled.
    ///
    /// Deliberately a timer rather than an animation-completion callback:
    /// SwiftUI's completion fires when the spring's *tail* finishes, long after
    /// the panel has visually arrived, and anything waiting on it appears late
    /// enough to read as a second event.
    private func beginSettling(opening: Bool) {
        settleTask?.cancel()
        isSettled = false

        let delay = Motion.timeline(preferences.motion, opening: opening).settled
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.transition(self.preferences.motion)) {
                self.isSettled = true
            }
        }
    }

    /// Injects a deformation impulse that springs back to rest. Keeping it as a
    /// separate one-shot value — rather than baking it into the size animation
    /// — is what lets the panel overshoot in *shape* without overshooting in
    /// layout, so text never visibly stretches.
    /// - Parameter delay: how long to wait before deforming. The impulse is
    ///   timed to land with the container, not to start with it.
    func kickSquash(_ amount: CGFloat, after delay: Double) {
        // Deformation is pure decoration, and decoration is the first thing
        // Reduce Motion should drop.
        guard !Motion.prefersReducedMotion else { return }

        squashRelease?.cancel()

        // Let a deformation still in flight spring home rather than assigning
        // zero outright.
        //
        // A bare `squash = 0` outside an animation teleports the shape from
        // wherever it had reached straight back to its resting width. It is
        // invisible when impulses are seconds apart and unmistakable when they
        // are not: skipping through tracks fires one of these per change, and
        // every one of them snapped the pill mid-recoil.
        if squash != 0 {
            withAnimation(Motion.squashRelease()) {
                squash = 0
            }
        }

        squashRelease = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }

            withAnimation(Motion.squashRamp()) {
                self.squash = amount
            }

            // Wait out the ramp *and* the hold. Sleeping only for the hold
            // starts the release while the deformation is still ramping in, so
            // it never reaches full amplitude.
            try? await Task.sleep(for: .seconds(Motion.squashRampDuration + Motion.squashHold))
            guard !Task.isCancelled else { return }

            withAnimation(Motion.squashRelease()) {
                self.squash = 0
            }
        }
    }
}
