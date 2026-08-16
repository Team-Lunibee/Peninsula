// Draws the social preview card and writes docs/og.png.
//
//   swift scripts/make-og.swift
//
// 1200×630 because that is what the crawlers assume. The screenshots are
// 2.65:1, so handing one of those over as the preview gets it letterboxed or
// cropped through the middle — and the preview is the first thing anyone sees
// when the link is pasted into a chat.
//
// Same shape as the icon and the app: the tile is a screen, the mark hangs off
// its top edge.

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

struct Card: View {
    private let accent = Color(red: 0.29, green: 0.78, blue: 0.90)

    var body: some View {
        ZStack(alignment: .top) {
            Color.black

            // The light a screen's top edge catches, so the black mark below has
            // something to be black against.
            RadialGradient(
                colors: [Color(red: 0.49, green: 0.59, blue: 0.82).opacity(0.34),
                         Color(red: 0.16, green: 0.19, blue: 0.28).opacity(0.16),
                         .clear],
                center: .top, startRadius: 0, endRadius: 700
            )

            VStack(spacing: 0) {
                notch
                Spacer(minLength: 0)
                Text("맥북 노치를 다이나믹 아일랜드로")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color(white: 0.53))
                Text("lunibee.kr/peninsula")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color(white: 0.36))
                    .padding(.top, 20)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 64)
        }
        .frame(width: 1200, height: 630)
    }

    /// Attached to the top edge, holding the name — the same move the page makes.
    private var notch: some View {
        NotchMark(bottomRadius: 44)
            .fill(Color.black)
            .overlay {
                HStack(spacing: 26) {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.90), Color(white: 0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 92, height: 92)
                        .overlay(alignment: .top) {
                            NotchMark(bottomRadius: 11)
                                .fill(Color(white: 0.05))
                                .frame(width: 68, height: 28)
                                .overlay {
                                    HStack(spacing: 3) {
                                        ForEach([0.40, 0.72, 0.52, 1.0, 0.60], id: \.self) { l in
                                            Capsule().fill(accent)
                                                .frame(width: 3.5, height: 13 * l)
                                        }
                                    }
                                }
                        }
                    Text("Peninsula")
                        .font(.system(size: 62, weight: .semibold))
                        .foregroundStyle(Color(white: 0.96))
                }
            }
            .frame(width: 640, height: 232)
    }
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = root.appendingPathComponent("docs/og.png")

    let renderer = ImageRenderer(content: Card())
    renderer.scale = 1

    guard
        let image = renderer.nsImage,
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:]),
        (try? png.write(to: out)) != nil
    else {
        FileHandle.standardError.write("failed to render og.png\n".data(using: .utf8)!)
        exit(1)
    }

    FileHandle.standardOutput.write("wrote \(out.path)\n".data(using: .utf8)!)
}
