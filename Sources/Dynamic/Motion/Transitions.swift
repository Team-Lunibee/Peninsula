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

/// Defocus alone, so it can run on a different clock from the fade.
struct IslandBlurModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// One axis of scale, so each can be handed the spring that drives the
/// container on that axis.
struct IslandAxisScaleModifier: ViewModifier {
    var x: CGFloat
    var y: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content.scaleEffect(x: x, y: y, anchor: anchor)
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
    /// - Parameter origin: the scale the contents come *from*, as a fraction of
    ///   their own size on each axis — normally the resting pill's size over
    ///   this state's size.
    ///
    ///   This is the part that makes a morph read as one object growing. The
    ///   contents are laid out once at their final size and this scales them
    ///   onto the container, on the container's own two springs, so a title
    ///   sits at the same fraction across the panel at every frame instead of
    ///   being re-flowed into whatever box exists right now.
    ///
    ///   It has to live in the transition rather than in an `.animation(_:
    ///   value:)` on the view. The container's size changes in the *same*
    ///   transaction that inserts the contents, and a view that did not exist a
    ///   frame ago has no previous value to animate from — so an animation
    ///   attached that way silently does nothing and the contents appear at
    ///   full size inside a pill.
    @MainActor
    static func island(
        blur: CGFloat = 10,
        origin: CGSize = CGSize(width: 0.94, height: 0.94),
        anchor: UnitPoint = .top,
        spread: CGFloat = 0
    ) -> AnyTransition {
        let preset = Preferences.shared.motion
        let reduced = Motion.prefersReducedMotion

        // Reduce Motion keeps the fade but drops the effects that actually
        // move: defocusing, scaling and displacement.
        let absent = IslandContentModifier(
            blurRadius: 0,
            opacity: 0,
            scale: 1,
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

        let fade = AnyTransition.asymmetric(
            insertion: .modifier(active: absent, identity: present)
                .animation(Motion.contentEntrance(preset)),
            removal: .modifier(active: absent, identity: present)
                .animation(Motion.contentExit(preset))
        )
        guard !reduced else { return fade }

        // Blur is a separate transition purely so it can carry its own
        // animation. Composed into the modifier above it would be interpolated
        // along the fade's curve, and the whole point is that it is not: it is
        // held nearly to the end of the entrance and released, and on the way
        // out it arrives before anything else has moved.
        let defocused = IslandBlurModifier(radius: blur)
        let focused = IslandBlurModifier(radius: 0)
        let focus = AnyTransition.asymmetric(
            insertion: .modifier(active: defocused, identity: focused)
                .animation(Motion.contentFocus(preset)),
            removal: .modifier(active: defocused, identity: focused)
                .animation(Motion.contentDefocus(preset))
        )

        // One transition per axis, so each can carry the spring that moves the
        // container on that axis. Combined into one they would share a single
        // animation, and closing — where the width comes home in under half the
        // time the height takes — would visibly drift apart from the shape.
        let identityScale = IslandAxisScaleModifier(x: 1, y: 1, anchor: anchor)
        let horizontal = AnyTransition.asymmetric(
            insertion: .modifier(
                active: IslandAxisScaleModifier(x: origin.width, y: 1, anchor: anchor),
                identity: identityScale
            ).animation(Motion.width(preset, opening: true)),
            removal: .modifier(
                active: IslandAxisScaleModifier(x: origin.width, y: 1, anchor: anchor),
                identity: identityScale
            ).animation(Motion.width(preset, opening: false))
        )
        let vertical = AnyTransition.asymmetric(
            insertion: .modifier(
                active: IslandAxisScaleModifier(x: 1, y: origin.height, anchor: anchor),
                identity: identityScale
            ).animation(Motion.height(preset, opening: true)),
            removal: .modifier(
                active: IslandAxisScaleModifier(x: 1, y: origin.height, anchor: anchor),
                identity: identityScale
            ).animation(Motion.height(preset, opening: false))
        )

        return fade.combined(with: focus).combined(with: horizontal).combined(with: vertical)
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
