import AppKit
import Observation
import SwiftUI

/// The playback indicator, modelled on the Dynamic Island's: a bar meter while
/// audio is playing, and a row of dots when it is not.
///
/// Built on Core Animation rather than SwiftUI, for two measured reasons.
///
/// The first is a SwiftUI bug. On macOS a `TimelineView` inside an
/// `NSHostingView` drives `sizeThatFits` in a loop, oscillating between the
/// real size and zero several times a second, and each of those is a layout
/// pass over the whole hosting view. (Apple FB13810482, still open.) The notch
/// is exactly that arrangement, and the meter was costing ~4% CPU continuously
/// because of it.
///
/// The second is more fundamental: a redraw-per-frame design makes the app do
/// work sixty times a second to move five small rectangles. `CABasicAnimation`
/// hands the interpolation to the render server, so the timer here fires three
/// times a second purely to choose the *next* targets — every frame in between
/// costs this process nothing.
///
/// The bars are synthesised from smooth periodic functions rather than a real
/// audio tap, because macOS offers no public way to read another app's output.
struct SpectrumView: View {
    /// Playback is running.
    var isActive: Bool
    /// Whether motion is wanted at all — separate from `isActive`, because one
    /// is about the music and the other about whether it is worth the power.
    var animates: Bool = true
    var tint: Color
    var barCount = 7
    var maxHeight: CGFloat = 24
    var barWidth: CGFloat = 3

    @State private var display = DisplayState.shared

    private var spacing: CGFloat { barWidth * 0.75 }
    private var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(max(0, barCount - 1)) * spacing
    }

    var body: some View {
        SpectrumLayer(
            isMoving: isActive && animates && display.isAwake,
            tint: NSColor(tint),
            barCount: barCount,
            barWidth: barWidth,
            spacing: spacing,
            maxHeight: maxHeight
        )
        // A fixed frame, so the hosting view's layout never has to negotiate
        // with something that is changing.
        .frame(width: width, height: maxHeight)
    }
}

private struct SpectrumLayer: NSViewRepresentable {
    var isMoving: Bool
    var tint: NSColor
    var barCount: Int
    var barWidth: CGFloat
    var spacing: CGFloat
    var maxHeight: CGFloat

    func makeNSView(context: Context) -> SpectrumHostView {
        SpectrumHostView(
            barCount: barCount,
            barWidth: barWidth,
            spacing: spacing,
            maxHeight: maxHeight
        )
    }

    func updateNSView(_ view: SpectrumHostView, context: Context) {
        view.tint = tint
        view.setMoving(isMoving)
    }

    static func dismantleNSView(_ view: SpectrumHostView, coordinator: ()) {
        view.setMoving(false)
    }
}

/// Bars as layers, animated by the render server.
final class SpectrumHostView: NSView {
    var tint: NSColor = .white {
        didSet {
            guard tint != oldValue else { return }
            applyTint()
        }
    }

    private let barCount: Int
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private let maxHeight: CGFloat

    private var bars: [CAShapeLayer] = []
    private var scales: [CGFloat] = []
    private var timer: Timer?
    private var phase: Double = 0

    /// Targets are chosen five times a second and Core Animation fills in the
    /// rest.
    ///
    /// The rate is safe to raise because the cost here is per *target*, not per
    /// frame: five ticks a second setting five animations is nothing, and the
    /// interpolation between them runs at display refresh in the render server
    /// either way. Three ticks read as a slow sway; five is where it starts to
    /// look like it is reacting to something.
    private static let step: TimeInterval = 1.0 / 4.0

    /// Scale at which a bar is as tall as it is wide: a dot.
    private var restingScale: CGFloat { barWidth / maxHeight }

    init(barCount: Int, barWidth: CGFloat, spacing: CGFloat, maxHeight: CGFloat) {
        self.barCount = barCount
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildBars() {
        let path = NSBezierPath(
            roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: maxHeight),
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        ).cgPath

        for index in 0..<barCount {
            let bar = CAShapeLayer()
            bar.path = path
            bar.fillColor = tint.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: maxHeight)
            // Anchored in the middle so a scale grows both ways, the way a
            // level meter does.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(
                x: CGFloat(index) * (barWidth + spacing) + barWidth / 2,
                y: maxHeight / 2
            )
            bar.transform = CATransform3DMakeScale(1, restingScale, 1)
            layer?.addSublayer(bar)

            bars.append(bar)
            scales.append(restingScale)
        }
    }

    private func applyTint() {
        // Colour changes are not animated: the accent arrives with a new track,
        // and a bar sliding between two colours reads as a glitch next to the
        // artwork flipping over.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.fillColor = tint.cgColor }
        CATransaction.commit()
    }

    func setMoving(_ moving: Bool) {
        if moving {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Self.step, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            advance()
        } else {
            guard timer != nil else { return }
            timer?.invalidate()
            timer = nil
            settle()
        }
    }

    /// Chooses the next target for each bar and hands the motion off.
    private func advance() {
        phase += Self.step

        for (index, bar) in bars.enumerated() {
            // Exactly one step long, so each segment ends as the next begins.
            // Finishing early and holding — which is what "punchier" looked
            // like on paper — puts a dead frame between every move, and the
            // row visibly stutters.
            animate(bar, at: index, to: targetScale(index: index), duration: Self.step)
        }
    }

    private func settle() {
        for (index, bar) in bars.enumerated() {
            animate(bar, at: index, to: restingScale, duration: 0.28, settling: true)
        }
    }

    private func animate(
        _ bar: CAShapeLayer,
        at index: Int,
        to target: CGFloat,
        duration: TimeInterval,
        settling: Bool = false
    ) {
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = scales[index]
        animation.toValue = target
        animation.duration = duration
        // Eased at both ends so consecutive segments meet without a corner.
        // The liveliness comes from how far apart the targets are, not from
        // rushing between them.
        animation.timingFunction = CAMediaTimingFunction(name: settling ? .easeOut : .easeInEaseOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false

        bar.add(animation, forKey: "level")
        scales[index] = target
    }

    /// Two detuned sines per bar: a single sine reads as a mechanical sweep,
    /// while an incommensurable pair never visibly repeats. The centre bars run
    /// taller than the edges, the way a real spectrum peaks in the mids.
    ///
    /// Deterministic rather than random — random targets jitter, and the eye
    /// reads jitter as noise rather than as music.
    private func targetScale(index: Int) -> CGFloat {
        let offset = Double(index) * 1.7
        let slow = sin(phase * 3.6 + offset)
        let fast = sin(phase * 8.7 + offset * 2.3)
        let flutter = sin(phase * 13.1 + offset * 0.7)
        var normalised = (slow * 0.5 + fast * 0.34 + flutter * 0.16 + 1) / 2

        // Skewed low, so the row spends most of its time modest and spikes
        // occasionally — a uniform distribution leaves every bar hovering near
        // the middle, which is the flattest-looking thing a meter can do.
        //
        // But only slightly. At 1.7 the skew pushed the average down to about a
        // third of the track, and on the compact pill's short track that left
        // the whole row crawling along the bottom. The point of the skew is
        // that peaks stand out, not that nothing ever reaches one.
        normalised = pow(normalised, 1.25)

        let centre = Double(barCount - 1) / 2
        let distance = centre > 0 ? abs(Double(index) - centre) / centre : 0
        // Gentle enough that the outer bars still take part. At 0.3 they were
        // capped near half height and the row read as a hill rather than a
        // meter.
        let envelope = 1 - distance * 0.18

        let minimum = restingScale
        return minimum + CGFloat(normalised * envelope) * (1 - minimum)
    }

    deinit {
        timer?.invalidate()
    }
}

/// Whether the display is on.
///
/// Animating into a sleeping or locked display is pure waste, and on a laptop
/// waste is measured in battery. Nothing visible changes, which makes this the
/// rare optimisation with no design cost at all.
@MainActor
@Observable
final class DisplayState {
    static let shared = DisplayState()

    private(set) var isAwake = true

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let states: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false),
            (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ]

        for (name, awake) in states {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAwake = awake }
            }
        }
    }
}
