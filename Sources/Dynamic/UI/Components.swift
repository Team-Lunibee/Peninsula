import AppKit
import SwiftUI

/// Horizontally scrolling text that only moves when it actually overflows.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var speed: Double = 30
    var gap: CGFloat = 44

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                label
                if overflows { label }
            }
            .offset(x: offset)
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .onAppear { containerWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, new in
                containerWidth = new
                restart()
            }
        }
        .frame(height: lineHeight)
        .onChange(of: text) { _, _ in restart() }
        .onChange(of: overflows) { _, _ in restart() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            // Inside the offset, not outside it: the scroll then moves a
            // texture rather than redrawing the title every frame.
            .rasterisedText()
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { textWidth = proxy.size.width }
                        .onChange(of: text) { _, _ in textWidth = proxy.size.width }
                }
            )
    }

    private var lineHeight: CGFloat { 17 }

    private func restart() {
        offset = 0
        guard overflows else { return }
        let distance = textWidth + gap
        withAnimation(.linear(duration: distance / speed).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

/// Circular control sized for the notch, with a press state that reads at a
/// glance without a background plate.
struct NotchButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var size: CGFloat = 30
    var help: String?

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .background(
                    Circle().fill(.white.opacity(isHovering ? 0.13 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // A touch of scale on top of the plate: at notch sizes an opacity
        // change alone is easy to miss against a black background.
        .scaleEffect(isHovering ? 1.09 : 1)
        .animation(Motion.content(Preferences.shared.motion), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help ?? "")
    }
}

/// Playback scrubber. Drag anywhere along the track to seek; the thumb grows
/// while dragging so the hit target is honest about being draggable.
struct Scrubber: View {
    var progress: Double
    var tint: Color
    var onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var shown: Double { isDragging ? dragProgress : progress }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(width, width * shown)))
            }
            .frame(height: isDragging ? 6 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            Haptics.tap()
                        }
                        dragProgress = min(1, max(0, value.location.x / max(width, 1)))
                    }
                    .onEnded { value in
                        let target = min(1, max(0, value.location.x / max(width, 1)))
                        isDragging = false
                        onSeek(target)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 12)
    }
}

extension TimeInterval {
    /// `m:ss`, or `h:mm:ss` past an hour.
    var playbackClock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}


/// System output volume, sized for the notch.
///
/// The speaker glyph reflects the level rather than only mute state, so the
/// control still says something when the slider is too small to read at a
/// glance. Clicking it mutes.
struct VolumeControl: View {
    var tint: Color
    /// Icon of the app whose volume this is, when it is not the system's.
    var sourceIcon: NSImage?

    @State private var volume = SystemVolume.shared
    @State private var player = AppPlayback.shared
    @State private var isDragging = false
    @State private var draft: Float = 0

    /// The playing app's own volume when it has one, the output device's
    /// otherwise. Turning the music down should not take notification sounds
    /// with it — and when the player cannot be addressed (anything in a
    /// browser), the system slider is the honest fallback rather than a control
    /// that does nothing.
    private var controlsApp: Bool { player.controlsVolume }

    private var current: Float { controlsApp ? (player.volume ?? 0) : volume.level }
    private var shown: Float { isDragging ? draft : current }

    var body: some View {
        if volume.isAvailable || controlsApp {
            HStack(spacing: 8) {
                if controlsApp, let sourceIcon {
                    // The app's own icon, because this is the app's own volume
                    // and a speaker glyph here would claim otherwise.
                    Image(nsImage: sourceIcon)
                        .resizable()
                        .frame(width: 15, height: 15)
                        .opacity(0.9)
                        .help("이 앱의 음량")
                } else {
                    Button {
                        volume.toggleMute()
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(volume.isMuted ? 0.4 : 0.7))
                            .frame(width: 16, height: 16)
                            .contentTransition(.symbolEffect(.replace))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("시스템 음량")
                }

                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(!controlsApp && volume.isMuted ? Color.white.opacity(0.3) : tint)
                            .frame(width: max(0, min(width, width * CGFloat(shown))))
                    }
                    .frame(height: isDragging ? 5 : 3.5)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                draft = Float(min(1, max(0, value.location.x / max(width, 1))))
                                if controlsApp {
                                    player.set(volume: draft)
                                } else {
                                    volume.set(level: draft)
                                }
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .animation(.easeOut(duration: 0.12), value: isDragging)
                }
                .frame(height: 12)
            }
        }
    }

    private var symbol: String {
        if volume.isMuted || shown <= 0.001 { return "speaker.slash.fill" }
        if shown < 0.34 { return "speaker.wave.1.fill" }
        if shown < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
