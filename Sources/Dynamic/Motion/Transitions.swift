import SwiftUI

/// Blur, opacity and scale moving together — the transition the whole notch
/// hangs on.
///
/// The three have to be one gesture, not three effects that happen to overlap.
/// Content emerging from the island starts small, out of focus and invisible,
/// and resolves into place; content leaving retreats the same way it came. The
/// scale anchor is the top edge, so everything grows *out of* the cutout rather
/// than out of its own centre.
struct IslandContentModifier: ViewModifier {
    var blurRadius: CGFloat
    var opacity: Double
    var scale: CGFloat
    var anchor: UnitPoint
    /// Horizontal displacement in the absent state. Negative pulls content
    /// toward the cutout, so it appears to be carried outward by the widening
    /// panel rather than materialising where it will end up.
    var spread: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .offset(x: spread)
            .blur(radius: blurRadius)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// The house transition.
    ///
    /// Insertion is delayed and removal is not, which is the entire trick: the
    /// outgoing content clears out of the way, *then* the container resizes
    /// into the gap, *then* the new content resolves. Running all three at once
    /// is what makes a morph read as a glitch.
    ///
    /// - Parameters:
    ///   - blur: defocus at the extremes. Scale it with how large the size
    ///     change is — a peek needs far less than a full expansion.
    ///   - scale: how small the content starts and ends. Below ~0.9 it reads as
    ///     a zoom rather than a reveal.
    /// - Parameter spread: where the content starts, relative to where it
    ///   lands. Elements far from the cutout otherwise read as appearing rather
    ///   than arriving: the panel travels hundreds of points while its contents
    ///   simply fade in at their final positions. Starting them inboard and
    ///   letting them settle outward ties the two together.
    @MainActor
    static func island(
        blur: CGFloat = 10,
        scale: CGFloat = 0.94,
        anchor: UnitPoint = .top,
        spread: CGFloat = 0
    ) -> AnyTransition {
        let preset = Preferences.shared.motion
        let reduced = Motion.prefersReducedMotion

        let absent = IslandContentModifier(
            // Reduce Motion keeps the fade but drops the effects that actually
            // move: defocusing, scaling and displacement.
            blurRadius: reduced ? 0 : blur,
            opacity: 0,
            scale: reduced ? 1 : scale,
            anchor: anchor,
            spread: reduced ? 0 : spread
        )
        let present = IslandContentModifier(
            blurRadius: 0,
            opacity: 1,
            scale: 1,
            anchor: anchor,
            spread: 0
        )

        return .asymmetric(
            insertion: .modifier(active: absent, identity: present)
                .animation(Motion.contentEntrance(preset)),
            removal: .modifier(active: absent, identity: present)
                .animation(Motion.contentExit(preset))
        )
    }

    /// Plain blur-and-fade for elements that swap in place inside an already
    /// settled panel, where there is no container motion to coordinate with.
    @MainActor
    static func blurFade(radius: CGFloat = 6, spread: CGFloat = 0) -> AnyTransition {
        let reduced = Motion.prefersReducedMotion
        return .modifier(
            active: IslandContentModifier(
                blurRadius: reduced ? 0 : radius,
                opacity: 0,
                scale: 1,
                anchor: .center,
                spread: reduced ? 0 : spread
            ),
            identity: IslandContentModifier(
                blurRadius: 0, opacity: 1, scale: 1, anchor: .center, spread: 0
            )
        )
    }
}


/// A card turning over, used when the track changes.
///
/// The outgoing artwork rotates away from the viewer and the incoming one
/// arrives from the opposite side, so a track change reads as one object being
/// replaced rather than two images cross-fading. Perspective is kept shallow —
/// a strong vanishing point on a 72pt square looks like a party trick.
struct FlipModifier: ViewModifier {
    var angle: Double
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
            .opacity(opacity)
    }
}

extension AnyTransition {
    @MainActor
    static var artworkFlip: AnyTransition {
        guard !Motion.prefersReducedMotion else { return .blurFade(radius: 8) }

        return .asymmetric(
            insertion: .modifier(
                active: FlipModifier(angle: -82, opacity: 0),
                identity: FlipModifier(angle: 0, opacity: 1)
            ),
            removal: .modifier(
                active: FlipModifier(angle: 82, opacity: 0),
                identity: FlipModifier(angle: 0, opacity: 1)
            )
        )
    }
}
