import SwiftUI

/// The notch silhouette: flush against the top screen edge, with concave
/// corners flowing out of the bezel and convex corners at the bottom.
///
/// Corners are cubic Béziers using the circle-approximation constant rather
/// than quadratics, so the curvature stays continuous while the radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Floating displays get an ordinary rounded rectangle — concave corners
    /// only make sense where they flow out of a real bezel.
    var style: NotchStyle = .cutout

    private static let kappa: CGFloat = 0.5522847498307936

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return Path() }

        if style == .floating {
            let radius = max(0, min(bottomRadius, min(w, h) / 2))
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        }

        // Clamp so extreme radii (or a mid-animation frame) can never produce
        // self-intersecting geometry.
        let top = max(0, min(topRadius, h, w / 3))
        let bottom = max(0, min(bottomRadius, h - top, (w - top * 2) / 2))
        let k = Self.kappa

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left: concave, curving down and inward from the screen edge.
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control1: CGPoint(x: rect.minX + k * top, y: rect.minY),
            control2: CGPoint(x: rect.minX + top, y: rect.minY + top - k * top)
        )

        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Bottom-left: convex.
        path.addCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control1: CGPoint(x: rect.minX + top, y: rect.maxY - bottom + k * bottom),
            control2: CGPoint(x: rect.minX + top + bottom - k * bottom, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Bottom-right: convex.
        path.addCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control1: CGPoint(x: rect.maxX - top - bottom + k * bottom, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom + k * bottom)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right: concave, flowing back out to the screen edge.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - top, y: rect.minY + top - k * top),
            control2: CGPoint(x: rect.maxX - k * top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

extension NotchShape {
    /// Radii tuned so the closed pill reads as the hardware cutout and the open
    /// panel reads as a floating sheet.
    static let closedRadii = (top: CGFloat(6), bottom: CGFloat(13))
    static let expandedRadii = (top: CGFloat(14), bottom: CGFloat(32))
}

#Preview("Closed") {
    NotchShape(topRadius: 6, bottomRadius: 13)
        .fill(.black)
        .frame(width: 200, height: 32)
        .padding(40)
        .background(.white)
}

#Preview("Expanded") {
    NotchShape(topRadius: 14, bottomRadius: 26)
        .fill(.black)
        .frame(width: 560, height: 170)
        .padding(40)
        .background(.white)
}
