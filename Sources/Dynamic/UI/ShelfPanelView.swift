import AppKit
import SwiftUI

struct ShelfPanelView: View {
    let model: NotchViewModel

    private var shelf: ShelfStore { model.shelf }
    private var isReceiving: Bool { model.activity == .dropTarget }

    var body: some View {
        Group {
            if isReceiving {
                DropZonesView(model: model)
            } else {
                library
            }
        }
        .animation(Motion.transition(Preferences.shared.motion), value: isReceiving)
    }

    // MARK: - Library

    private var library: some View {
        VStack(spacing: 14) {
            if shelf.isEmpty {
                empty
                    .transition(.blurFade(radius: 6))
            } else {
                items
                toolbar
            }
        }
        .animation(Motion.transition(Preferences.shared.motion), value: shelf.isEmpty)
    }

    private var items: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(shelf.items) { item in
                    ShelfTile(item: item, model: model)
                        .transition(
                            .asymmetric(
                                insertion: .blurFade(radius: 10)
                                    .combined(with: .scale(scale: 0.7, anchor: .top))
                                    .combined(with: .offset(y: -14)),
                                removal: .blurFade(radius: 6)
                                    .combined(with: .scale(scale: 0.8))
                            )
                        )
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(summary)
                .rasterisedText()
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))

            Spacer(minLength: 0)

            Button {
                model.onAirDropAll?()
            } label: {
                Label("전체 AirDrop", systemImage: "shareplay")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(Motion.content(Preferences.shared.motion)) {
                    shelf.removeAll()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("선반 비우기")
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private var summary: String {
        let count = shelf.items.count
        let bytes = shelf.items.reduce(Int64(0)) { $0 + $1.byteSize }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(count)개 항목 · \(size)"
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("노치 위로 파일을 끌어다 놓으세요")
                .rasterisedText()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("\(Preferences.shared.shelfExpiryDays)일 동안 보관한 뒤 자동으로 정리됩니다")
                .rasterisedText()
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Drop zones

/// What the panel becomes while a drag is in flight.
///
/// The library, its counts and its buttons all disappear: mid-drag the only
/// question is where this file is going, and everything else is noise competing
/// for the same pixels. The two destinations split 1:3 because dropping is
/// aimed rather than browsed — AirDrop is the deliberate choice and needs only
/// enough area to be unmissable, while the shelf is the default and should
/// catch everything else.
private struct DropZonesView: View {
    let model: NotchViewModel

    @State private var airDropTargeted = false
    @State private var shelfTargeted = false

    private static let gap: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let unit = (proxy.size.width - Self.gap) / 4

            HStack(spacing: Self.gap) {
                zone(
                    symbol: "shareplay",
                    title: "AirDrop",
                    subtitle: "바로 보내기",
                    tint: .cyan,
                    isTargeted: airDropTargeted
                )
                .frame(width: max(unit, 96))
                .onDrop(of: [.fileURL], isTargeted: $airDropTargeted) { providers in
                    receive(providers) { model.onAirDropFiles?($0) }
                }

                zone(
                    symbol: "tray.and.arrow.down.fill",
                    title: "선반에 보관",
                    subtitle: "\(Preferences.shared.shelfExpiryDays)일 동안",
                    tint: .green,
                    isTargeted: shelfTargeted
                )
                .frame(maxWidth: .infinity)
                .onDrop(of: [.fileURL], isTargeted: $shelfTargeted) { providers in
                    receive(providers) { model.onDrop?($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The armed state has to be unmistakable — mid-drag the pointer is busy
    /// and the only feedback available is what the zone itself does. Border,
    /// fill, glow, icon and scale all move together rather than one of them
    /// changing subtly.
    private func zone(
        symbol: String,
        title: String,
        subtitle: String?,
        tint: Color,
        isTargeted: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isTargeted ? tint.opacity(0.9) : .white.opacity(0.26),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [7, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isTargeted ? tint.opacity(0.18) : .white.opacity(0.04))
            )
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: isTargeted ? 24 : 20, weight: .light))
                        .symbolEffect(.bounce, value: isTargeted)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.72))
                .padding(.horizontal, 8)
                .multilineTextAlignment(.center)
            }
            .shadow(color: tint.opacity(isTargeted ? 0.45 : 0), radius: 14)
            .scaleEffect(isTargeted ? 1.035 : 1)
            .animation(Motion.content(Preferences.shared.motion), value: isTargeted)
            .onChange(of: isTargeted) { _, armed in
                if armed { Haptics.tap(.alignment) }
            }
    }

    private func receive(
        _ providers: [NSItemProvider],
        deliver: @escaping ([URL]) -> Void
    ) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            deliver(urls)
        }
        return true
    }
}

// MARK: - Tile

/// One file on the shelf. Draggable straight back out into any app.
private struct ShelfTile: View {
    let item: ShelfItem
    let model: NotchViewModel

    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @State private var isPressingRemove = false

    private var url: URL { model.shelf.url(for: item) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.08))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(nsImage: ThumbnailCache.shared.icon(for: url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                }
            }
            .frame(width: 66, height: 66)
            .overlay {
                // The scrim is decoration and must not swallow clicks — the
                // middle of the tile belongs to the double-click that opens a
                // preview, and only the button itself removes anything.
                if isHovering {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .allowsHitTesting(false)
                        .transition(.blurFade(radius: 5))
                }
            }
            .overlay(alignment: .topTrailing) {
                // Inside the tile, not overhanging it: a corner badge that
                // sticks out gets clipped by the notch directly above.
                if isHovering {
                    removeButton
                        .padding(4)
                        .transition(.blurFade(radius: 5))
                }
            }

            Text(item.displayName)
                .rasterisedText()
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .scaleEffect(isHovering ? 1.06 : 1)
        .animation(Motion.content(Preferences.shared.motion), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            QuickLook.present([url])
        }
        .onDrag {
            Haptics.tap()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("열기") { model.shelf.open(item) }
            Button("Finder에서 보기") { model.shelf.reveal(item) }
            Button("AirDrop…") { model.onAirDropItem?(item) }
            Divider()
            Button("제거", role: .destructive) { model.shelf.remove(item) }
        }
        .task(id: item.id) {
            thumbnail = await ThumbnailCache.shared.thumbnail(
                for: item,
                url: url,
                size: CGSize(width: 66, height: 66)
            )
        }
    }

    /// Built from a plain glyph on a solid disc rather than `xmark.circle.fill`.
    /// That symbol knocks the cross out of the disc, so against the notch's
    /// black it reads as a dark smudge; an opaque white disc with a black cross
    /// keeps its contrast whatever is behind it.
    private var removeButton: some View {
        Button {
            withAnimation(Motion.content(Preferences.shared.motion)) {
                model.shelf.remove(item)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 17, height: 17)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressingRemove ? 0.88 : 1)
        .animation(Motion.content(Preferences.shared.motion), value: isPressingRemove)
        .onHover { isPressingRemove = $0 }
        .help("선반에서 제거")
    }
}
