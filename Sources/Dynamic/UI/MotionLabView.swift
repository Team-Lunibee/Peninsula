import SwiftUI

/// Frame-by-frame inspector for the notch's transitions.
///
/// It does not replay the real notch — it *samples* the same `Motion.Timeline`
/// the real notch is built from, so any number shown here is the number the app
/// actually uses. Scrub to a millisecond, read the container's size and radii,
/// and see exactly when outgoing content clears and incoming content starts.
struct MotionLabView: View {
    private enum Transition: String, CaseIterable, Identifiable {
        case expand
        case collapse
        case banner

        var id: String { rawValue }

        var label: String {
            switch self {
            case .expand: "확장"
            case .collapse: "축소"
            case .banner: "배너"
            }
        }

        var isOpening: Bool { self != .collapse }
    }

    /// 60fps stepping. The panel can render at 120 on a ProMotion display, but
    /// 60 is the granularity anyone can actually judge by eye.
    private static let frameDuration: Double = 1.0 / 60.0

    @State private var transition: Transition = .expand
    @State private var preset: MotionPreset = Preferences.shared.motion
    @State private var time: Double = 0
    @State private var isPlaying = false

    private var timeline: Motion.Timeline {
        Motion.timeline(preset, opening: transition.isOpening)
    }

    /// A little past the settle point so the spring's tail is visible.
    private var totalDuration: Double {
        max(timeline.settled * 1.6, 0.5)
    }

    private var frame: Int { Int((time / Self.frameDuration).rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .background(Color.black)

            Divider()

            controls
                .padding(16)

            Divider()

            readouts
                .padding(16)

            Spacer(minLength: 0)
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled, isPlaying {
                try? await Task.sleep(for: .seconds(Self.frameDuration))
                guard !Task.isCancelled else { return }
                time += Self.frameDuration
                if time >= totalDuration {
                    time = 0
                }
            }
        }
        .onChange(of: transition) { _, _ in time = 0 }
        .onChange(of: preset) { _, _ in time = 0 }
    }

    // MARK: - Preview

    private var sizes: (from: CGSize, to: CGSize) {
        // Representative 14" MacBook geometry, so the lab shows the same
        // proportions the app derives on real hardware.
        let closed = CGSize(width: 189, height: 32)
        let compact = CGSize(width: closed.width + 64, height: closed.height)
        let peek = CGSize(width: closed.width + 250, height: 46)
        let expanded = CGSize(width: 624, height: NotchGeometry.expandedHeight)

        switch transition {
        case .expand: return (compact, expanded)
        case .collapse: return (expanded, compact)
        case .banner: return (compact, peek)
        }
    }

    private var radii: (from: (top: CGFloat, bottom: CGFloat), to: (top: CGFloat, bottom: CGFloat)) {
        let closed = NotchShape.closedRadii
        let expanded = NotchShape.expandedRadii
        let peek: (top: CGFloat, bottom: CGFloat) = (top: 8, bottom: 18)

        switch transition {
        case .expand: return (closed, expanded)
        case .collapse: return (expanded, closed)
        case .banner: return (closed, peek)
        }
    }

    private var progress: Double {
        Motion.containerProgress(timeline, at: time)
    }

    private var heightProgress: Double {
        guard time > 0 else { return 0 }
        return timeline.heightSpring.value(target: 1.0, time: time)
    }

    private var currentSize: CGSize {
        let (from, to) = sizes
        return CGSize(
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * heightProgress
        )
    }

    private var currentRadii: (top: CGFloat, bottom: CGFloat) {
        let (from, to) = radii
        return (
            top: from.top + (to.top - from.top) * progress,
            bottom: from.bottom + (to.bottom - from.bottom) * progress
        )
    }

    private var exitOpacity: Double { Motion.exitOpacity(timeline, at: time) }
    private var entranceOpacity: Double { Motion.entranceOpacity(timeline, at: time) }

    private var preview: some View {
        GeometryReader { proxy in
            // Everything is drawn at true point size and then scaled to fit, so
            // the shape's proportions stay honest.
            let scale = min(1, (proxy.size.width - 40) / 660)
            let size = currentSize
            let radii = currentRadii

            ZStack(alignment: .top) {
                NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
                    .fill(Color(white: 0.07))
                    .overlay {
                        NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
                            .stroke(.white.opacity(0.22), lineWidth: 0.75 / scale)
                    }
                    .frame(width: max(size.width, 1), height: max(size.height, 1))
                    .overlay(alignment: .top) {
                        contentStandIn(containerSize: size)
                    }
            }
            .frame(width: proxy.size.width, alignment: .center)
            .scaleEffect(scale, anchor: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
        }
    }

    /// Stand-ins for the outgoing and incoming content, carrying the real
    /// opacity, blur and scale for this instant.
    private func contentStandIn(containerSize: CGSize) -> some View {
        ZStack {
            block(label: "나가는 콘텐츠", tint: .orange, opacity: exitOpacity, scale: 0.95)
            block(label: "들어오는 콘텐츠", tint: .cyan, opacity: entranceOpacity, scale: 0.95)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
    }

    private func block(label: String, tint: Color, opacity: Double, scale: CGFloat) -> some View {
        let eased = 1 - opacity
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
            .scaleEffect(scale + (1 - scale) * opacity, anchor: .top)
            .blur(radius: 10 * eased)
            .opacity(opacity)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Picker("", selection: $transition) {
                    ForEach(Transition.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("", selection: $preset) {
                    ForEach(MotionPreset.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
            }

            HStack(spacing: 10) {
                Button {
                    isPlaying = false
                    time = max(0, time - Self.frameDuration)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .help("한 프레임 뒤로")

                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(isPlaying ? "일시정지" : "재생")

                Button {
                    isPlaying = false
                    time = min(totalDuration, time + Self.frameDuration)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .help("한 프레임 앞으로")

                Button {
                    isPlaying = false
                    time = 0
                } label: {
                    Image(systemName: "gobackward")
                }
                .help("처음으로")

                Slider(value: $time, in: 0...totalDuration) { editing in
                    if editing { isPlaying = false }
                }

                Text("\(Int(time * 1000))ms")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: time * 1000))
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: - Readouts

    private var readouts: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                caption("프레임")
                value("#\(frame)")
                caption("가로 / 세로 진행")
                value(String(format: "%.3f / %.3f", progress, heightProgress))
            }
            GridRow {
                caption("크기")
                value(String(format: "%.0f × %.0f", currentSize.width, currentSize.height))
                caption("코너")
                value(String(format: "%.1f / %.1f", currentRadii.top, currentRadii.bottom))
            }
            GridRow {
                caption("나가는 불투명도")
                value(String(format: "%.2f", exitOpacity))
                caption("들어오는 불투명도")
                value(String(format: "%.2f", entranceOpacity))
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                caption("스프링")
                value(String(
                    format: "가로 %.0fms·%.2f / 세로 %.0fms·%.2f",
                    timeline.containerDuration * 1000,
                    timeline.containerBounce,
                    timeline.heightDuration * 1000,
                    timeline.heightBounce
                ))
                caption("콘텐츠 지연")
                value("\(Int(timeline.contentLead * 1000))ms")
            }
            GridRow {
                caption("퇴장")
                value("0 → \(Int(timeline.exitDuration * 1000))ms")
                caption("등장")
                value("\(Int(timeline.contentLead * 1000)) → \(Int((timeline.contentLead + timeline.entranceDuration) * 1000))ms")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
    }
}
