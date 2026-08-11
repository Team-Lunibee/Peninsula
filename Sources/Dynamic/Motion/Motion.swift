import AppKit
import SwiftUI

/// Motion for the notch, expressed the way Apple parameterises springs since
/// WWDC23: a perceptual `duration` and a `bounce` from 0 to 1, rather than
/// mass/stiffness/damping.
///
/// Two consequences matter here. Springs are the only SwiftUI animation that
/// preserves velocity across an interruption, so a notch caught mid-open
/// continues from its current speed instead of restarting — no hand-fed
/// `initialVelocity` needed. And `duration` is a *perceptual* setting, not a
/// hard stop: the settle tail runs past it, which is exactly the "keeps
/// breathing after it lands" quality the Dynamic Island has.
///
/// Every transition is described once, by `Timeline`, and both the live
/// animations and the Motion Lab read from it. Two sources of truth would mean
/// the lab shows something the app does not actually do.
@MainActor
enum Motion {
    /// The complete choreography of one state change.
    ///
    /// The three phases deliberately do not overlap much: outgoing content
    /// clears, the container resizes into the gap, then incoming content
    /// resolves. Running them simultaneously is what makes a morph read as a
    /// glitch rather than a shape changing.
    struct Timeline: Equatable {
        /// Perceptual duration of the container's width spring.
        var containerDuration: Double
        /// 0 settles flat, 1 is maximally springy.
        var containerBounce: Double
        /// Height runs on its own, shorter spring. Collapsing both axes at one
        /// rate reads as a box shrinking; letting the height arrive first
        /// leaves a wide, short pill that then draws itself in, which is the
        /// shape the Dynamic Island passes through on its way home.
        var heightDuration: Double
        var heightBounce: Double
        /// How long the container leads before incoming content follows.
        var contentLead: Double
        var entranceDuration: Double
        /// Outgoing content starts immediately, at t = 0.
        var exitDuration: Double

        /// When everything has visually finished, ignoring the spring's tail.
        var settled: Double {
            max(containerDuration, contentLead + entranceDuration)
        }

        var spring: Spring {
            Spring(duration: containerDuration, bounce: containerBounce)
        }

        var heightSpring: Spring {
            Spring(duration: heightDuration, bounce: heightBounce)
        }
    }

    /// Honours System Settings › Accessibility › Display › Reduce Motion.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Apple's own preset bounces are 0 (smooth), 0.15 (snappy) and 0.3
    /// (bouncy); these sit in the same range so the notch feels like system UI.
    /// Durations carry a Mac uplift — a panel this size crossing this much
    /// distance at iPhone speed reads as a jump cut.
    private static func base(_ preset: MotionPreset) -> (duration: Double, bounce: Double) {
        switch preset {
        case .snappy: (duration: 0.34, bounce: 0.18)
        case .bouncy: (duration: 0.46, bounce: 0.28)
        case .gentle: (duration: 0.58, bounce: 0.04)
        }
    }

    /// - Parameter opening: closing is shorter and flatter.
    ///
    ///   The container spring drives width and height together, so any bounce
    ///   here bobbles both axes. The island's recoil is horizontal — it pinches
    ///   narrow and springs back wide, while its height simply settles — so the
    ///   container stays close to critically damped and the recoil comes from
    ///   the squash impulse instead, which can act on one axis alone.
    static func timeline(_ preset: MotionPreset, opening: Bool) -> Timeline {
        let spring = base(preset)

        if prefersReducedMotion {
            // A cross-fade with no overshoot, no lead and no stagger.
            return Timeline(
                containerDuration: 0.2,
                containerBounce: 0,
                heightDuration: 0.2,
                heightBounce: 0,
                contentLead: 0,
                entranceDuration: 0.2,
                exitDuration: 0.2
            )
        }

        let duration = opening ? spring.duration : spring.duration * 0.86
        let bounce = opening ? spring.bounce : min(0.08, spring.bounce * 0.3)

        return Timeline(
            containerDuration: duration,
            containerBounce: bounce,
            // The axis that belongs to the *destination* resolves last.
            //
            // Opening, the width leads: the shape spreads along the bezel and
            // then descends, which is how something emerging from a slot has to
            // move. Letting the height lead instead makes it pass through a
            // tall narrow box, which reads as a window growing.
            //
            // Closing, the height leads hard: the pill regains its own height
            // almost at once, leaving a wide short bar that then reels its
            // width back in.
            heightDuration: opening ? duration * 1.18 : duration * 0.55,
            heightBounce: opening ? bounce * 0.5 : 0,
            // Just enough lead to read as sequenced. Any longer and the panel
            // looks like it opened empty and is waiting for something.
            contentLead: duration * 0.16,
            // Content resolves considerably slower than the container moves.
            // The container is a physical object and wants to arrive; the
            // content is coming into focus, and rushing that is what makes a
            // blur transition look like a cheap fade.
            entranceDuration: duration * 0.68,
            exitDuration: duration * 0.32
        )
    }

    // MARK: - Animations

    static func open(_ preset: MotionPreset) -> Animation {
        width(preset, opening: true)
    }

    static func close(_ preset: MotionPreset) -> Animation {
        width(preset, opening: false)
    }

    /// The container's width spring — the dominant one, and the axis the
    /// recoil acts on.
    static func width(_ preset: MotionPreset, opening: Bool) -> Animation {
        let line = timeline(preset, opening: opening)
        return .spring(duration: line.containerDuration, bounce: line.containerBounce)
    }

    /// The container's height spring, which settles ahead of the width.
    static func height(_ preset: MotionPreset, opening: Bool) -> Animation {
        let line = timeline(preset, opening: opening)
        return .spring(duration: line.heightDuration, bounce: line.heightBounce)
    }

    /// Content arriving inside a container that is still opening.
    ///
    /// `easeInOut` rather than `easeOut`: easing in at both ends keeps the blur
    /// from snapping into focus at the end, which is the difference between
    /// something resolving and something simply appearing.
    static func contentEntrance(_ preset: MotionPreset) -> Animation {
        let line = timeline(preset, opening: true)
        return .easeInOut(duration: line.entranceDuration).delay(line.contentLead)
    }

    /// Content leaving, ahead of the container closing over the space it
    /// occupied.
    static func contentExit(_ preset: MotionPreset) -> Animation {
        .easeInOut(duration: timeline(preset, opening: false).exitDuration)
    }

    /// Blur-and-fade between siblings inside an already settled panel, where
    /// there is no container motion to coordinate with.
    static func transition(_ preset: MotionPreset) -> Animation {
        .easeInOut(duration: base(preset).duration * 0.55)
    }

    /// Contents settling in place — position, colour, selection. No bounce:
    /// bouncing text looks like a rendering bug, not a flourish.
    static func content(_ preset: MotionPreset) -> Animation {
        .spring(duration: base(preset).duration * 0.78, bounce: 0)
    }

    /// A live activity swapping in under the closed pill.
    static func activity() -> Animation {
        prefersReducedMotion
            ? .easeInOut(duration: 0.2)
            : .spring(duration: 0.38, bounce: 0.22)
    }

    // The recoil is a single lobe, not a decay: flat while the panel travels,
    // a quick deformation as it *arrives*, then a springy return to rest.
    //
    // Applying the impulse at t = 0 instead — which is the obvious thing to do
    // — puts the pinch on the panel while it is still 600pt wide, where a few
    // percent is invisible, and lets it spring back out only after everything
    // has already stopped. The deformation has to coincide with the moment the
    // shape lands or it is not read as impact at all.
    // Short and bouncy. A long release un-pinches so gradually that it reads
    // as a slow stretch; the recoil has to be back through its resting width
    // and out the other side while the eye is still on it.
    static let squashSpring = Spring(duration: 0.28, bounce: 0.55)
    static let squashRampDuration = 0.04
    /// Barely a hold. Any longer and the deformation looks like a pose.
    static let squashHold = 0.02

    /// When the impulse hits, as a fraction of the container's travel.
    static func squashDelay(_ preset: MotionPreset, opening: Bool) -> Double {
        guard !prefersReducedMotion else { return 0 }
        let line = timeline(preset, opening: opening)
        // Slightly later on the way in: the width is the last thing to arrive.
        // Peaks a touch *before* the container lands, so the shape is caught
        // being pushed past its resting size rather than deforming after it
        // has already stopped.
        return line.containerDuration * (opening ? 0.42 : 0.48)
    }

    static func squashRamp() -> Animation {
        .easeOut(duration: squashRampDuration)
    }

    static func squashRelease() -> Animation {
        prefersReducedMotion
            ? .easeOut(duration: 0.2)
            : .spring(duration: 0.28, bounce: 0.55)
    }

    /// Squash at `time`, for the frame dump. Mirrors exactly what
    /// `NotchViewModel.kickSquash` schedules.
    static func squash(amount: CGFloat, delay: Double, at time: Double) -> CGFloat {
        guard time > delay else { return 0 }

        let sinceImpulse = time - delay
        if sinceImpulse < squashRampDuration {
            // easeOut over the ramp.
            let progress = sinceImpulse / squashRampDuration
            return amount * CGFloat(UnitCurve.easeOut.value(at: progress))
        }

        let sinceRelease = sinceImpulse - (squashRampDuration + squashHold)
        guard sinceRelease > 0 else { return amount }
        return amount * (1 - CGFloat(squashSpring.value(target: 1.0, time: sinceRelease)))
    }

    // MARK: - Sampling
    //
    // Used by the Motion Lab to draw any single frame of a transition. These
    // evaluate the very same curves the animations above are built from.

    /// Container progress from 0 to 1, including overshoot past 1.
    static func containerProgress(_ line: Timeline, at time: Double) -> Double {
        guard time > 0 else { return 0 }
        return line.spring.value(target: 1.0, time: time)
    }

    /// Opacity of the content being replaced.
    static func exitOpacity(_ line: Timeline, at time: Double) -> Double {
        guard line.exitDuration > 0 else { return time > 0 ? 0 : 1 }
        let progress = min(1, max(0, time / line.exitDuration))
        return 1 - UnitCurve.easeIn.value(at: progress)
    }

    /// Opacity of the content arriving.
    static func entranceOpacity(_ line: Timeline, at time: Double) -> Double {
        guard line.entranceDuration > 0 else { return time >= line.contentLead ? 1 : 0 }
        let progress = min(1, max(0, (time - line.contentLead) / line.entranceDuration))
        return UnitCurve.easeOut.value(at: progress)
    }
}

/// The elastic recoil, applied almost entirely across the width.
///
/// This is where the island's spring lives. The container animates its size
/// with a near-flat spring so the height just settles, and this impulse pinches
/// the pill narrow and lets it spring back wide — the horizontal "boing" the
/// Dynamic Island has. A little counter-movement in height is kept so the
/// deformation reads as a soft body rather than a horizontal stretch, but it is
/// small enough that nothing visibly squashes vertically.
struct JellyModifier: ViewModifier, Animatable {
    var amount: CGFloat
    var anchor: UnitPoint = .top

    private static let horizontalGain: CGFloat = 0.075
    private static let verticalGain: CGFloat = 0.016

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content.scaleEffect(
            x: 1 + amount * Self.horizontalGain,
            y: 1 - amount * Self.verticalGain,
            anchor: anchor
        )
    }
}

extension View {
    func jelly(_ amount: CGFloat, anchor: UnitPoint = .top) -> some View {
        modifier(JellyModifier(amount: amount, anchor: anchor))
    }
}
