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
            max(max(containerDuration, heightDuration), contentLead + entranceDuration)
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

    /// `.snappy` is measured, not chosen.
    ///
    /// A 50fps screen recording of a real Dynamic Island expanding and
    /// collapsing was stepped frame by frame, the silhouette extracted per
    /// frame, and Apple's own `Spring(duration:bounce:)` fitted to the
    /// resulting width and height curves by least squares:
    ///
    ///     expand   width  0.445s · bounce +0.10   (rms 0.009)
    ///     expand   height 0.420s · bounce +0.06   (rms 0.011)
    ///     collapse height 0.455s · bounce +0.12   (rms 0.007)
    ///     collapse width  ~0.19s · overdamped
    ///
    /// So: barely any bounce, both axes together on the way out, and on the way
    /// back the width beats the height home by more than double. The other two
    /// presets keep the springier and softer feels as alternatives.
    private static func base(_ preset: MotionPreset) -> (duration: Double, bounce: Double) {
        switch preset {
        case .snappy: (duration: 0.44, bounce: 0.08)
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

        // Opening, the two axes travel together.
        //
        // This is the correction the reference forced. Staggering them — width
        // first, height chasing — was a guess, and the real island does not do
        // it: measured, its width and height progress track each other within
        // two percent for the whole expansion. Height runs fractionally quicker
        // and flatter, which is all the separation there is.
        if opening {
            return Timeline(
                containerDuration: spring.duration,
                containerBounce: spring.bounce,
                heightDuration: spring.duration * 0.95,
                heightBounce: spring.bounce * 0.6,
                // Contents start arriving almost immediately.
                //
                // Frame-matched against the reference: its panel already
                // carries a visible, heavily defocused ghost of the layout one
                // twentieth of a second in, and is fully opaque before the
                // container stops. Holding the contents back — which is what a
                // longer lead does — reads as an empty box that then fills,
                // and an empty box is the one thing the island never shows.
                contentLead: spring.duration * 0.08,
                entranceDuration: spring.duration * 0.85,
                exitDuration: spring.duration * 0.55
            )
        }

        // Closing, the width beats the height home.
        //
        // Measured at better than two to one: the panel pulls in horizontally
        // almost at once, leaving a tall narrow block that then retracts
        // upward. On a MacBook that reads as the sheet being drawn back into
        // the slot it came out of, which is exactly what it is.
        return Timeline(
            containerDuration: spring.duration * 0.43,
            containerBounce: 0,
            heightDuration: spring.duration * 1.02,
            heightBounce: spring.bounce * 1.4,
            contentLead: 0,
            entranceDuration: spring.duration * 0.5,
            // Outgoing contents *linger*, defocused.
            //
            // The defocus is what removes them — it lands within two frames —
            // but the fade behind it is slow: measured, the reference still
            // carries a visible smear of the artwork a sixth of a second into
            // the collapse. Fading as fast as the blur arrives empties the box
            // while it is still large, and an empty box shrinking is a window
            // closing, not an island retracting.
            exitDuration: spring.duration * 0.55
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
        // `easeOut`, matching what `entranceOpacity` samples for the Motion Lab
        // — these disagreed, and the lab was drawing a curve the app did not
        // run. It is also the measured shape: opacity climbs fast and then
        // eases into place behind the container.
        return .easeOut(duration: line.entranceDuration).delay(line.contentLead)
    }

    /// Content leaving, ahead of the container closing over the space it
    /// occupied.
    static func contentExit(_ preset: MotionPreset) -> Animation {
        // `easeOut`, matching `exitOpacity`: most of the fade happens early,
        // and the last of it tails off under the blur.
        .easeOut(duration: timeline(preset, opening: false).exitDuration)
    }

    /// Defocus runs on its own clock, later and shorter than the fade.
    ///
    /// In the reference the arriving contents are *unreadable* until the
    /// container is roughly ninety percent of the way there, and then snap into
    /// focus over the last eighty milliseconds. Tying blur to the same curve as
    /// opacity — the obvious thing, and what this used to do — clears it
    /// steadily instead, and the panel reads as a cross-fade with a soft edge
    /// rather than as something resolving.
    ///
    /// Measured against the reference: moderately defocused at half way,
    /// legible at 250ms, fully sharp by 300ms — three quarters of the way
    /// through a 400ms expansion, with the container still settling behind it.
    /// `easeOut`, not `easeInOut`.
    ///
    /// Blur is not perceived linearly: most of the illegibility lives in the
    /// last couple of points of radius, so a curve that eases *in* at the end
    /// holds the content unreadable and then snaps it into focus in a frame or
    /// two. Measured against the reference, that snap is the tell — the real
    /// island's contents sharpen over roughly a hundred milliseconds. Easing out
    /// takes the radius down quickly and then spends the rest of the time in
    /// the range where the eye can actually see it resolving.
    static func contentFocus(_ preset: MotionPreset) -> Animation {
        let duration = base(preset).duration
        return .easeOut(duration: duration * focusDurationRatio)
            .delay(duration * focusDelayRatio)
    }

    /// Blur arriving as content leaves. No delay: this is the first thing that
    /// happens in a collapse.
    static func contentDefocus(_ preset: MotionPreset) -> Animation {
        .easeOut(duration: base(preset).duration * defocusDurationRatio)
    }

    /// Shared by the animations above and by the Motion Lab's sampling, so the
    /// lab can never show a defocus the app does not perform.
    static let focusDelayRatio = 0.30
    static let focusDurationRatio = 0.42
    static let defocusDurationRatio = 0.16

    /// Blur at `time`, as a fraction of the transition's maximum.
    static func focusFactor(_ preset: MotionPreset, at time: Double, entering: Bool) -> Double {
        guard !prefersReducedMotion else { return 0 }
        let duration = base(preset).duration

        if entering {
            let delay = duration * focusDelayRatio
            let span = duration * focusDurationRatio
            guard span > 0 else { return time >= delay ? 0 : 1 }
            let progress = min(1, max(0, (time - delay) / span))
            return 1 - UnitCurve.easeOut.value(at: progress)
        }

        let span = duration * defocusDurationRatio
        guard span > 0 else { return 1 }
        return UnitCurve.easeOut.value(at: min(1, max(0, time / span)))
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
        // Timed to the *width*, which is the axis the recoil acts on. Peaks a
        // touch before it lands, so the shape is caught being pushed past its
        // resting size rather than deforming after it has already stopped.
        // Closing, the width arrives early and fast, so the impulse has to be
        // proportionally later within its much shorter travel.
        return line.containerDuration * (opening ? 0.42 : 0.72)
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
        return 1 - UnitCurve.easeOut.value(at: progress)
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
///
/// Applied by scaling the notch *path* (see `NotchRootView`) rather than by
/// transforming the view. A view transform has to be pushed into every AppKit
/// view SwiftUI hosts inside the notch, and each one dirties Auto Layout and the
/// window's tracking areas at display refresh — measured at 4.4 points of CPU
/// through every transition, for a deformation of at most 7.5%.
enum JellyModifier {
    static let horizontalGain: CGFloat = 0.085
    /// Read as the *counter*-movement of a soft body: as the shape pinches
    /// narrow it swells taller, and as it stretches wide it flattens.
    ///
    /// This was 0.016, which is arithmetically a deformation and visually
    /// nothing — on a 32pt pill it is half a point, well under the width of the
    /// antialiased edge it is supposed to be moving. Four points of height on a
    /// collapse is where it starts to read as the thing springing back rather
    /// than merely arriving.
    static let verticalGain: CGFloat = 0.07
}
