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

    /// The row starts at the left and grows rightwards, newest last.
    ///
    /// The store keeps the newest first, which is the right shape for the data
    /// — expiry and re-drop promotion both work from the front — but the wrong
    /// one to read. A shelf fills up the way a shelf does, and the file just
    /// dropped lands where the pointer that dropped it already is.
    ///
    /// Left-aligned, not right-aligned: a horizontal `ScrollView` places
    /// content shorter than itself wherever its scroll anchor says, so anchoring
    /// to the trailing edge stacked two or three tiles against the right-hand
    /// side with a gulf of nothing beside them. Filling the width and aligning
    /// the contents leading keeps them where they belong; the scroll only has
    /// anywhere to go once there are enough tiles to overflow.

    private static let scrollSpace = "shelf-scroll"

    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    /// Set by the scroll bar, consumed by the ScrollViewReader below.
    @State private var scrollFraction: CGFloat?

    /// A couple of points of slack: the offset lands on fractional values and an
    /// exact comparison leaves the fade on at rest.
    private var scrolledFromStart: Bool { scrollOffset > 2 }
    private var atEnd: Bool {
        contentWidth <= 0 || scrollOffset >= contentWidth - viewportWidth - 2
    }

    private var items: some View {
        // Fades whichever edge still has tiles behind it.
        //
        // The row has always scrolled, but with hidden indicators nothing said
        // so: a tile cut off at the panel's edge reads as a rendering mistake,
        // not as "there is more". Dragging the row would have been the obvious
        // affordance and is taken — a drag on a tile is how a file leaves the
        // shelf — so the edge does the telling instead.
        GeometryReader { outer in
            // Measured, not estimated from the item count. Counting tiles meant
            // counting a trailing gap that is not there, which overstated the
            // row by one gap and faded the last tile on a shelf that fitted.
            let overflowing = contentWidth > outer.size.width + 1

            scroller
                .onChange(of: outer.size.width) { _, w in viewportWidth = w }
                .onAppear { viewportWidth = outer.size.width }
                .overlay(alignment: .bottom) {
                    if overflowing {
                        ScrollBar(
                            offset: scrollOffset,
                            content: contentWidth,
                            viewport: outer.size.width,
                            onDrag: { scrollFraction = $0 }
                        )
                    }
                }
                .mask(
                    LinearGradient(
                        stops: overflowing
                            ? [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: scrolledFromStart ? 0.045 : 0),
                                .init(color: .white, location: atEnd ? 1 : 0.955),
                                .init(color: .clear, location: 1),
                            ]
                            : [.init(color: .white, location: 0), .init(color: .white, location: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy, because a plain `HStack` builds every tile the shelf
                // holds whether or not it is on screen — and building a tile
                // asks QuickLook for a thumbnail. Seven fit across the panel;
                // the rest can wait until they are scrolled to.
                LazyHStack(spacing: 14) {
                    ForEach(shelf.items.reversed()) { item in
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
                .frame(maxWidth: .infinity, alignment: .leading)
                // 스크롤 위치는 콘텐츠가 컨테이너 좌표계에서 어디 있는지로 읽는다.
                // onScrollGeometryChange 는 macOS 15 부터라 쓸 수 없다.
                .background {
                    GeometryReader { inner in
                        let frame = inner.frame(in: .named(Self.scrollSpace))
                        Color.clear
                            .onChange(of: frame.minX) { _, x in scrollOffset = -x }
                            .onChange(of: frame.width) { _, w in contentWidth = w }
                            .onAppear {
                                scrollOffset = -frame.minX
                                contentWidth = frame.width
                            }
                    }
                }
            }
            .coordinateSpace(name: Self.scrollSpace)
            // Once it does overflow, follow the newest tile out to the right,
            // or a drop onto a full shelf lands off-screen and reads as having
            // done nothing. `items.first` is the newest — the store's order.
            .onChange(of: scrollFraction) { _, fraction in
                guard let fraction else { return }
                let ordered = shelf.items.reversed().map(\.id)
                guard !ordered.isEmpty else { return }
                let index = Int((fraction * CGFloat(ordered.count - 1)).rounded())
                withAnimation(.interactiveSpring(duration: 0.22)) {
                    proxy.scrollTo(ordered[min(max(index, 0), ordered.count - 1)], anchor: .center)
                }
            }
            .onChange(of: shelf.items.first?.id) { _, newest in
                guard let newest else { return }
                withAnimation(Motion.transition(Preferences.shared.motion)) {
                    proxy.scrollTo(newest, anchor: .trailing)
                }
            }
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
                Label("AirDrop All", systemImage: "shareplay")
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
            .help("Empty the shelf")
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    /// Formatted once per shelf change rather than once per frame.
    ///
    /// This is a plural lookup and a byte formatter behind a computed property,
    /// which a transition re-evaluates on every frame — for a line of text whose
    /// two inputs only move when a file is added or removed.
    private var summary: String { shelf.summary }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Drag files onto the notch")
                .rasterisedText()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Kept for \(Preferences.shared.shelfExpiryDays) days, then cleared automatically")
                .rasterisedText()
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A bar under the row, for pointers that cannot scroll sideways.
///
/// A trackpad scrolls this row with two fingers and a mouse with a wheel
/// generally cannot, so without this the tiles past the seventh are reachable
/// on some hardware and not others. Dragging the tiles themselves was not
/// available: a drag on a tile is how a file leaves the shelf.
private struct ScrollBar: View {
    let offset: CGFloat
    let content: CGFloat
    let viewport: CGFloat
    let onDrag: (CGFloat) -> Void

    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.width
            let visible = content > 0 ? min(1, viewport / content) : 1
            let knob = max(28, track * visible)
            let travel = max(0, track - knob)
            let progress = content > viewport ? min(1, max(0, offset / (content - viewport))) : 0

            Capsule()
                .fill(.white.opacity(isHovering ? 0.28 : 0.16))
                .frame(width: knob, height: 4)
                .offset(x: travel * progress)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The knob's own centre, so the row follows the
                            // pointer rather than jumping by the grab offset.
                            let x = travel * progress + value.translation.width
                            onDrag(travel > 0 ? min(1, max(0, x / travel)) : 0)
                        }
                )
        }
        .frame(height: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 1)
        .onHover { isHovering = $0 }
        // Fades in with the pointer: an always-visible bar under a row of
        // thumbnails is another line competing with the labels.
        .opacity(isHovering ? 1 : 0.55)
        .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}

private extension View {
    /// Publishes this view's frame in the panel's coordinate space.
    func reportingFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(NotchRootView.dropSpace))
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { _, new in report(new) }
            }
        }
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

    private static let gap: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let unit = (proxy.size.width - Self.gap) / 4

            HStack(spacing: Self.gap) {
                // Shelf on the left, AirDrop on the right. The shelf is where
                // most drops are going, and a drag arrives from below and to
                // the left far more often than from the right — so the default
                // destination sits where the pointer already is.
                zone(
                    symbol: "tray.and.arrow.down.fill",
                    title: Strings.keepOnShelf,
                    subtitle: String(localized: "For \(Preferences.shared.shelfExpiryDays) days"),
                    tint: .green,
                    isTargeted: model.hoveredDropZone == .shelf
                )
                .frame(maxWidth: .infinity)
                .reportingFrame { model.shelfZoneRect = $0 }

                zone(
                    symbol: "shareplay",
                    title: "AirDrop",
                    subtitle: Strings.sendStraightAway,
                    tint: .cyan,
                    isTargeted: model.hoveredDropZone == .airDrop
                )
                .frame(width: max(unit, 96))
                .reportingFrame { model.airDropZoneRect = $0 }
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

    /// The zones no longer receive drops themselves.
    ///
    /// A nested `.onDrop` inside the panel's own never gets the drag, so a zone
    /// could neither claim the file nor light up. Both now come from
    /// `PanelDrop`, which is told the pointer's position and compares it against
    /// the frames reported above.
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

    /// A directory, but not a package.
    ///
    /// Packages are directories too, and must not be caught here: a `.key` or a
    /// `.numbers` previews properly, and "opening" an `.app` would launch it —
    /// from a double-click that the rest of the shelf treats as "show me this".
    ///
    /// Read from the filesystem rather than from the stored name. A folder has
    /// no extension to recognise it by, and `url.hasDirectoryPath` only reports
    /// the trailing-slash flag the URL was built with, which is false for every
    /// item here.
    private var isFolder: Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.08))

                if let thumbnail {
                    // Fills the tile and is cropped, rather than fitted inside
                    // it. A fitted thumbnail keeps its ratio but letterboxes:
                    // a wide screenshot becomes a thin strip floating in a
                    // 66pt square, and a tall page becomes a sliver. Filling
                    // shows less of the image but shows it at a size worth
                    // looking at, and the ratio is never distorted either way.
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    // Icons are drawn at their own size, not cropped — a file
                    // type glyph filled to the edges reads as a coloured tile
                    // with no glyph in it.
                    Image(nsImage: ThumbnailCache.shared.icon(for: item.id, url: url))
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
            // A folder opens in Finder; everything else previews.
            //
            // Quick Look renders a folder as its own icon blown up to full
            // screen, which is the one thing about a folder nobody needs to
            // look at — what someone wants from a folder is to be inside it.
            isFolder ? model.shelf.open(item) : QuickLook.present([url])
        }
        .onDrag {
            Haptics.tap()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { model.shelf.open(item) }
            Button("Show in Finder") { model.shelf.reveal(item) }
            Button("AirDrop…") { model.onAirDropItem?(item) }
            Divider()
            Button("Remove", role: .destructive) { model.shelf.remove(item) }
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
        .help("Remove from shelf")
    }
}
