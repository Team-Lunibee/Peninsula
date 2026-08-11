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

        var from: IslandPhase {
            switch self {
            case .expand, .banner: .compact
            case .collapse: .expanded
            }
        }

        var to: IslandPhase {
            switch self {
            case .expand: .expanded
            case .collapse: .compact
            case .banner: .peek
            }
        }

        /// The same impulses `NotchViewModel` kicks.
        var squashAmount: CGFloat {
            switch self {
            case .expand: 0.8
            case .collapse: -1.0
            case .banner: 0.5
            }
        }
    }

    /// Which presentation's contents are being drawn.
    enum IslandPhase {
        case compact, peek, expanded

        /// Matches the `.island(blur:scale:)` values in `NotchRootView`.
        var blur: CGFloat {
            switch self {
            case .compact: 7
            case .peek: 11
            case .expanded: 15
            }
        }

        var scale: CGFloat {
            switch self {
            case .compact: 0.9
            case .peek: 0.94
            case .expanded: 0.955
            }
        }
    }

    /// 60fps stepping. The panel can render at 120 on a ProMotion display, but
    /// 60 is the granularity anyone can actually judge by eye.
    private static let frameDuration: Double = 1.0 / 60.0

    @State private var transition: Transition = .expand
    @State private var preset: MotionPreset = Preferences.shared.motion
    @State private var time: Double = 0
    @State private var isPlaying = false
    /// Draws the camera housing over the preview. The one rule nothing may
    /// break is easiest to check by looking at it.
    @State private var showsCutout = false

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
                // Not black. The island *is* black, and drawing it on black
                // leaves nothing to look at but a hairline rim — which is
                // exactly what this tab exists to show.
                .background(
                    LinearGradient(
                        colors: [Color(white: 0.34), Color(white: 0.19)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

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

    /// The recoil at this instant, sampled from the same function
    /// `kickSquash` schedules against.
    private var squash: CGFloat {
        Motion.squash(
            amount: transition.squashAmount,
            delay: Motion.squashDelay(preset, opening: transition.isOpening),
            at: time
        )
    }

    private var preview: some View {
        GeometryReader { proxy in
            // Everything is drawn at true point size and then scaled to fit, so
            // the shape's proportions stay honest.
            let scale = min(1, (proxy.size.width - 40) / 660)
            let size = currentSize
            let radii = currentRadii
            // Deformed exactly the way the notch itself is: by scaling the path,
            // not the view.
            let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
                .scale(
                    x: 1 + squash * JellyModifier.horizontalGain,
                    y: 1 - squash * JellyModifier.verticalGain,
                    anchor: .top
                )

            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .overlay {
                        shape.stroke(.white.opacity(0.18), lineWidth: 0.75 / scale)
                    }
                    .frame(width: max(size.width, 1), height: max(size.height, 1))
                    // Clipped to the silhouette, not to its bounding box. A rect
                    // clip lets defocused content spill past the rounded corners,
                    // where it sits outside the black shape entirely.
                    .overlay(alignment: .top) {
                        islandContent(containerSize: size)
                            .frame(width: max(size.width, 1), height: max(size.height, 1))
                            .clipShape(shape)
                    }
                    .overlay(alignment: .top) {
                        if showsCutout {
                            Rectangle()
                                .fill(.red.opacity(0.18))
                                .overlay(Rectangle().stroke(.red.opacity(0.5), lineWidth: 0.75 / scale))
                                .frame(width: Self.cutoutWidth, height: Self.cutoutHeight)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .frame(width: proxy.size.width, alignment: .center)
            .scaleEffect(scale, anchor: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
        }
    }

    /// The island's actual contents, outgoing and incoming, each carrying the
    /// real blur, opacity and scale for this instant.
    ///
    /// Abstract blocks used to stand in here, and they were useless for judging
    /// the thing that actually matters: whether a title, a thumbnail and a row
    /// of controls arrive *together* and land where they belong. A transition
    /// only reads wrong once there is something in it to read.
    private func islandContent(containerSize: CGSize) -> some View {
        ZStack(alignment: .top) {
            islandPhase(transition.from, containerSize: containerSize)
                .modifier(standInEffect(phase: transition.from, entering: false))
            islandPhase(transition.to, containerSize: containerSize)
                .modifier(standInEffect(phase: transition.to, entering: true))
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .top)
        .clipped()
    }

    /// Opacity and blur are sampled from *different* curves, because the app
    /// animates them on different curves.
    private func standInEffect(phase: IslandPhase, entering: Bool) -> IslandContentModifier {
        let opacity = entering ? entranceOpacity : exitOpacity
        return IslandContentModifier(
            blurRadius: phase.blur * Motion.focusFactor(preset, at: time, entering: entering),
            opacity: opacity,
            scale: phase.scale + (1 - phase.scale) * opacity,
            anchor: .top
        )
    }

    /// Laid out at the size the state belongs to and scaled to the container,
    /// exactly as `NotchRootView` does it.
    @ViewBuilder
    private func islandPhase(_ phase: IslandPhase, containerSize: CGSize) -> some View {
        let target = size(of: phase)
        Group {
            switch phase {
            case .compact: MotionLabCompact(width: target.width, gap: Self.cutoutWidth)
            case .peek: MotionLabPeek(width: target.width, gap: Self.cutoutWidth)
            case .expanded: MotionLabExpanded(width: target.width, gap: Self.cutoutWidth)
            }
        }
        .frame(width: target.width, height: target.height, alignment: .top)
        .clipShape(NotchShape(topRadius: radii(of: phase).top, bottomRadius: radii(of: phase).bottom))
        // Uniform, matching the app: independent axes stretch the contents
        // whenever the container's proportions differ from theirs, which is most
        // of a transition.
        .scaleEffect(
            min(
                containerSize.width / max(target.width, 1),
                containerSize.height / max(target.height, 1)
            ),
            anchor: .top
        )
    }

    private func radii(of phase: IslandPhase) -> (top: CGFloat, bottom: CGFloat) {
        switch phase {
        case .compact: NotchShape.closedRadii
        case .peek: (top: 8, bottom: 18)
        case .expanded: NotchShape.expandedRadii
        }
    }

    private func size(of phase: IslandPhase) -> CGSize {
        let closed = CGSize(width: 189, height: 32)
        switch phase {
        case .compact: return CGSize(width: closed.width + 64, height: closed.height)
        case .peek: return CGSize(width: closed.width + 250, height: 46)
        case .expanded: return CGSize(width: 624, height: NotchGeometry.expandedHeight)
        }
    }

    /// Representative 14" cutout, matching the geometry `sizes` is built from.
    private static let cutoutWidth: CGFloat = 189
    private static let cutoutHeight: CGFloat = 32

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

                Toggle("컷아웃", isOn: $showsCutout)
                    .toggleStyle(.checkbox)
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
            GridRow {
                caption("흐림 (나가는/들어오는)")
                value(String(
                    format: "%.0f%% / %.0f%%",
                    Motion.focusFactor(preset, at: time, entering: false) * 100,
                    Motion.focusFactor(preset, at: time, entering: true) * 100
                ))
                caption("변형")
                value(String(format: "%+.3f", squash))
            }
            GridRow {
                caption("컨테이너 폭 진행")
                value(String(format: "%.3f", progress))
                caption("실폭 (변형 포함)")
                value(String(
                    format: "%.0f pt",
                    currentSize.width * (1 + squash * JellyModifier.horizontalGain)
                ))
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

// MARK: - Island stand-ins
//
// Static replicas of what each presentation puts on screen, at the same sizes
// and with the same split around the cutout. They deliberately hold no live
// state: the lab is for judging motion, and a meter that animates on its own
// would make it impossible to tell which movement belongs to the transition.

/// Sample artwork, so the lab has something with edges and colour in it rather
/// than a grey square.
private struct LabArtwork: View {
    var edge: CGFloat
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.95, green: 0.3, blue: 0.45), Color(red: 0.3, green: 0.3, blue: 0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: edge, height: edge)
    }
}

/// Frozen bars at plausible heights.
private struct LabMeter: View {
    var barCount = 5
    var barWidth: CGFloat = 2.5
    var maxHeight: CGFloat

    private static let levels: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.35, 0.7]

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 0.75) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(
                        width: barWidth,
                        height: max(barWidth, maxHeight * Self.levels[index % Self.levels.count])
                    )
            }
        }
        .frame(height: maxHeight)
    }
}

private struct MotionLabCompact: View {
    var width: CGFloat
    var gap: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LabArtwork(edge: 19, radius: 5.3)
            Spacer(minLength: 0)
            LabMeter(maxHeight: 13)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 32)
    }
}

private struct MotionLabPeek: View {
    var width: CGFloat
    var gap: CGFloat

    private var side: CGFloat { max(0, (width - 36 - gap) / 2) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                LabArtwork(edge: 28, radius: 8)
                Text("Blue Valentine")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)

            Color.clear.frame(width: gap)

            HStack(spacing: 8) {
                Text("NMIXX")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                LabMeter(maxHeight: 16)
            }
            .frame(width: side, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: width, height: 46)
    }
}

private struct MotionLabExpanded: View {
    var width: CGFloat
    var gap: CGFloat

    private var side: CGFloat {
        max(0, (width - NotchGeometry.contentMargin * 2 - gap) / 2)
    }

    var body: some View {
        VStack(spacing: 16) {
            islandRow
            header
            progress
            transport
        }
        .foregroundStyle(.white)
        .padding(.horizontal, NotchGeometry.contentMargin)
        .padding(.top, 4)
        .padding(.bottom, NotchGeometry.contentMargin - 4)
        .frame(width: width, alignment: .top)
    }

    private var islandRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                chip("music.note", "재생 중", selected: true)
                chip("tray.full", "선반", selected: false)
            }
            .frame(width: side, alignment: .leading)

            Color.clear.frame(width: gap)

            HStack(spacing: 8) {
                Text("음악")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Image(systemName: "quote.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: side, alignment: .trailing)
        }
        .frame(height: 32)
    }

    private func chip(_ symbol: String, _ label: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(label).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.42))
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(selected ? 0.13 : 0)))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            LabArtwork(edge: 72, radius: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text("Blue Valentine").font(.system(size: 16, weight: .semibold))
                Text("NMIXX")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 14)

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Capsule().fill(.white.opacity(0.18))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 44, height: 4)
                    }
            }
            .frame(width: 132)

            LabMeter(barCount: 6, barWidth: 3, maxHeight: 26)
        }
        .frame(height: 72)
    }

    private var progress: some View {
        HStack(spacing: 14) {
            Text("2:16").frame(width: 42, alignment: .leading)
            Capsule().fill(.white.opacity(0.2))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: proxy.size.width * 0.72, height: 4)
                    }
                    .frame(height: 4)
                }
            Text("−0:50").frame(width: 42, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.5))
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Image(systemName: "star").font(.system(size: 17))
            Spacer(minLength: 12)
            HStack(spacing: 22) {
                Image(systemName: "backward.fill").font(.system(size: 19))
                Image(systemName: "pause.fill").font(.system(size: 23))
                Image(systemName: "forward.fill").font(.system(size: 19))
            }
            Spacer(minLength: 12)
            Image(systemName: "airplayaudio").font(.system(size: 16))
        }
        .frame(height: 30)
    }
}
