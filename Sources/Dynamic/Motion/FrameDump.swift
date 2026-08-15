import AppKit
import SwiftUI

/// Renders a transition to a contact sheet, one cell per frame.
///
/// Run with `Dynamic --dump-frames <directory>`. It exists so the animation can
/// be *looked at* rather than only described: springs are easy to reason about
/// wrongly, and a filmstrip shows immediately whether the shape passes through
/// states that make sense.
///
/// Everything comes from the same `Motion` curves and the same `NotchShape` the
/// app draws, so a frame here is the frame on screen — not a re-implementation
/// that could drift.
@MainActor
enum FrameDump {
    private static let fps: Double = 60
    private static let frameCount = 30
    private static let columns = 6
    private static let cell = CGSize(width: 680, height: 250)

    /// A representative 14" MacBook, so the proportions match real hardware.
    private static let closed = CGSize(width: 189, height: 32)
    private static let compact = CGSize(width: closed.width + 64, height: closed.height)

    private static var expanded: CGSize {
        CGSize(
            width: min(690, max(560, (closed.width * NotchGeometry.expansionWidthRatio))).rounded(),
            height: NotchGeometry.expandedHeight
        )
    }

    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for preset in MotionPreset.allCases {
            for opening in [true, false] {
                let name = "\(opening ? "expand" : "collapse")-\(preset.rawValue).png"
                let sheet = contactSheet(preset: preset, opening: opening)
                write(sheet, to: directory.appendingPathComponent(name))
            }
        }

        FileHandle.standardOutput.write(
            "wrote \(MotionPreset.allCases.count * 2) sheets to \(directory.path)\n".data(using: .utf8)!
        )
    }

    // MARK: - Sampling

    /// Everything visible about the container at one instant.
    struct Frame {
        var index: Int
        var time: Double
        var size: CGSize
        var radii: (top: CGFloat, bottom: CGFloat)
        var squash: CGFloat
    }

    static func frames(preset: MotionPreset, opening: Bool) -> [Frame] {
        let line = Motion.timeline(preset, opening: opening)
        let from = opening ? compact : expanded
        let to = opening ? expanded : compact
        let fromRadii = opening ? NotchShape.closedRadii : NotchShape.expandedRadii
        let toRadii = opening ? NotchShape.expandedRadii : NotchShape.closedRadii
        let impulse: CGFloat = opening ? 0.8 : -1.0
        let delay = Motion.squashDelay(preset, opening: opening)

        return (0..<frameCount).map { index in
            let time = Double(index) / fps
            let widthProgress = index == 0 ? 0 : line.spring.value(target: 1.0, time: time)
            let heightProgress = index == 0 ? 0 : line.heightSpring.value(target: 1.0, time: time)

            return Frame(
                index: index,
                time: time,
                size: CGSize(
                    width: from.width + (to.width - from.width) * widthProgress,
                    height: from.height + (to.height - from.height) * heightProgress
                ),
                radii: (
                    top: fromRadii.top + (toRadii.top - fromRadii.top) * widthProgress,
                    bottom: fromRadii.bottom + (toRadii.bottom - fromRadii.bottom) * widthProgress
                ),
                squash: Motion.squash(amount: impulse, delay: delay, at: time)
            )
        }
    }

    // MARK: - Rendering

    private static func contactSheet(preset: MotionPreset, opening: Bool) -> NSImage? {
        let samples = frames(preset: preset, opening: opening)
        let rows = Int((Double(samples.count) / Double(columns)).rounded(.up))

        let view = VStack(spacing: 0) {
            Text("\(opening ? "Expand" : "Collapse") · \(preset.label) · 1/60s")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < samples.count {
                            cellView(samples[index])
                        } else {
                            Color.clear.frame(width: cell.width, height: cell.height)
                        }
                    }
                }
            }
        }
        .frame(width: cell.width * CGFloat(columns))
        .background(Color(white: 0.11))

        let renderer = ImageRenderer(content: view)
        // Half scale: a full-resolution sheet is enormous and the shape reads
        // perfectly well at this size.
        renderer.scale = 1
        return renderer.nsImage
    }

    private static func cellView(_ frame: Frame) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                // The screen edge, so the shape can be judged against the thing
                // it is pretending to be part of.
                Color(white: 0.24)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity, alignment: .top)

                NotchShape(topRadius: frame.radii.top, bottomRadius: frame.radii.bottom)
                    .fill(Color.black)
                    .overlay {
                        NotchShape(topRadius: frame.radii.top, bottomRadius: frame.radii.bottom)
                            .stroke(Color.cyan.opacity(0.55), lineWidth: 1)
                    }
                    .frame(width: max(frame.size.width, 1), height: max(frame.size.height, 1))
                    .scaleEffect(
                        x: 1 + frame.squash * 0.075,
                        y: 1 - frame.squash * 0.016,
                        anchor: .top
                    )
            }
            .frame(width: cell.width - 16, height: cell.height - 46, alignment: .top)

            Text(String(
                format: "#%02d  %.0fms  %.0f×%.0f  r%.0f/%.0f  s%+.2f",
                frame.index, frame.time * 1000,
                frame.size.width, frame.size.height,
                frame.radii.top, frame.radii.bottom,
                frame.squash
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: cell.width, height: cell.height)
        .background(Color(white: 0.16))
        .overlay(
            Rectangle().stroke(Color(white: 0.24), lineWidth: 0.5)
        )
    }

    private static func write(_ image: NSImage?, to url: URL) {
        guard
            let image,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            Log.app.error("could not render \(url.lastPathComponent, privacy: .private)")
            return
        }
        try? png.write(to: url)
    }
}
