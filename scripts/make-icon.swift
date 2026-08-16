// Draws the app icon and writes Resources/Peninsula.icns.
//
//   swift scripts/make-icon.swift
//
// The icon is code rather than a binary someone has to open a design tool to
// change: the shape is the same notch silhouette the app draws, so it cannot
// drift away from the thing it depicts.
//
// The tile is the screen and the mark is the notch hanging off its top edge,
// which is why the tile is light and the mark is black — the same way round as
// the hardware. A real notch is about 3% of a screen's height; at icon sizes
// that is invisible, so it is drawn wide and shallow instead. Wide reads as
// "the top of a display", where narrow and deep reads as a tab stuck on.

import AppKit
import SwiftUI

struct NotchMark: Shape {
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.width / 2, rect.height)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct IconArt: View {
    var size: CGFloat

    /// Icons leave room around the tile so they line up optically in the Dock
    /// with everything Apple ships.
    private var tile: CGFloat { size * 0.84 }
    private let accent = Color(red: 0.29, green: 0.78, blue: 0.90)

    var body: some View {
        ZStack {
            Color.clear
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.90), Color(white: 0.72)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.85), .clear],
                                               startPoint: .top, endPoint: .center),
                                lineWidth: max(1, tile * 0.006))
                    }
                mark
            }
            .frame(width: tile, height: tile)
            .shadow(color: .black.opacity(0.30), radius: size * 0.02, y: size * 0.012)
        }
        .frame(width: size, height: size)
    }

    private var mark: some View {
        let width = tile * 0.74
        let height = tile * 0.30

        return NotchMark(bottomRadius: height * 0.46)
            .fill(Color(white: 0.05))
            .overlay {
                // The meter, and the only colour anywhere in the icon. At 16pt
                // it collapses into a smear of cyan, which is the job: the icon
                // has to be identifiable at that size, not readable.
                HStack(alignment: .center, spacing: width * 0.045) {
                    ForEach([0.40, 0.72, 0.52, 1.0, 0.60], id: \.self) { level in
                        Capsule(style: .continuous)
                            .fill(accent)
                            .frame(width: width * 0.052, height: height * 0.46 * level)
                    }
                }
                .offset(y: height * 0.02)
            }
            .frame(width: width, height: height)
    }
}

@MainActor
func writePNG(size: CGFloat, to url: URL) -> Bool {
    let renderer = ImageRenderer(content: IconArt(size: size).frame(width: size, height: size))
    renderer.scale = 1
    guard
        let image = renderer.nsImage,
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: url)) != nil
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconset = root.appendingPathComponent("build/Peninsula.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // The names are fixed: iconutil rejects anything it does not recognise.
    let entries: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    for (name, size) in entries {
        let url = iconset.appendingPathComponent("\(name).png")
        if !writePNG(size: size, to: url) {
            FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    let icns = root.appendingPathComponent("Resources/Peninsula.icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try? task.run()
    task.waitUntilExit()

    guard task.terminationStatus == 0 else {
        FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write("wrote \(icns.path)\n".data(using: .utf8)!)
}
