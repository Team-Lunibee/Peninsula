import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifiers for elements that travel between presentations instead of
/// cross-fading.
enum Morph {
    static let artwork = "morph.artwork"
    static let spectrum = "morph.spectrum"
}

extension View {
    /// Applies `matchedGeometryEffect` only when a partner is guaranteed to
    /// exist in every participating state. An unpaired match has nothing to fly
    /// to and just logs noise.
    @ViewBuilder
    func morphing(_ id: String, in namespace: Namespace.ID, isSource: Bool, enabled: Bool) -> some View {
        if enabled {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

/// The whole notch surface.
///
/// The window is always the size of the fully expanded panel; this view draws
/// the pill top-centre inside it and lets the shape morph between resting,
/// peeking and open.
struct NotchRootView: View {
    let model: NotchViewModel

    @Namespace private var morph
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent filler so the hosting view keeps the window's size.
            Color.clear
            notch
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var notch: some View {
        let size = model.contentSize
        let radii = model.cornerRadii
        let shape = NotchShape(
            topRadius: radii.top,
            bottomRadius: radii.bottom,
            style: model.geometry.style
        )
        let sizing = NotchSizing(
            size: size,
            width: model.widthAnimation,
            height: model.heightAnimation
        )
        // The recoil deforms the *path*, not the view.
        //
        // `scaleEffect` on the container is the obvious way to do this and cost
        // 4.4 points of CPU through every transition. A view transform has to be
        // pushed down into every AppKit view SwiftUI is hosting inside — the
        // meter, the AirPlay button — and each `-[NSView setFrameTransform:]`
        // dirties Auto Layout and the window's tracking areas, recursively, at
        // display refresh. Scaling the silhouette costs one extra affine
        // transform on a path that is being rebuilt anyway.
        //
        // The visible difference is that the content no longer stretches with
        // the shape, which is what the impulse was always supposed to avoid:
        // the island's recoil is the black body flexing, not its text.
        let deformed = shape.scale(
            x: 1 + model.squash * JellyModifier.horizontalGain,
            y: 1 - model.squash * JellyModifier.verticalGain,
            anchor: .top
        )

        return ZStack(alignment: .top) {
            // The shadow gets its own layer, behind everything, holding nothing
            // that animates.
            //
            // Applied to the container instead — the obvious place — it must be
            // recomputed whenever *any* descendant changes, because a shadow is
            // cast by the rendered result. With a meter ticking inside, that
            // means re-blurring a 646x244 region at display refresh. Here it
            // only changes when the shape itself does.
            //
            // This layer is also the notch's black body: filling the shape again
            // inside the clipped layer below drew an identical black silhouette
            // on top of this one, invisibly, every frame — 5 points of CPU for
            // nothing.
            //
            // Both layers take the identical sizing modifier: they have to move
            // as one object, and giving them separate animations makes the
            // shadow visibly lag the panel it belongs to.
            deformed
                .fill(Color.black)
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 7)
                .modifier(sizing)

            // No sizing modifier and no clip out here: each presentation's
            // contents carry their own, in their own coordinate space. See
            // `scaled(_:_:)`.
            content

            // A sibling layer carrying the same sizing modifier, not an overlay
            // on the stack. As an overlay it sat outside the sizing — and so
            // outside the springs — and snapped to each new size while the
            // panel behind it was still travelling. The rim visibly detached
            // from the shape it outlines.
            //
            // Never conditional either: wrapping it in an `if` to skip an
            // invisible stroke changes the view's identity, and SwiftUI rebuilds
            // the subtree mid-transition. A zero line width is the way to skip
            // the work without touching identity — and it is worth skipping,
            // because stroking means computing the outline of the whole Bézier
            // silhouette from scratch on every frame.
            deformed
                .stroke(Color.white.opacity(rimOpacity), lineWidth: rimOpacity > 0 ? 0.5 : 0)
                .modifier(sizing)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: isDropTargeted) { _, targeted in
            model.isDropTargeted = targeted
            if targeted { model.beginDropTargeting() }
        }
    }

    private var rimOpacity: Double {
        switch model.geometry.style {
        case .cutout: model.isOpen ? 0.10 : 0
        case .floating: model.isOpen ? 0.12 : 0.08
        }
    }

    private var shadowOpacity: Double {
        switch model.geometry.style {
        case .cutout: model.isOpen ? 0.55 : 0
        case .floating: model.isOpen ? 0.55 : 0.35
        }
    }

    private var shadowRadius: CGFloat {
        model.isOpen ? 18 : 10
    }

    /// Content is laid out once, at the size of the state it belongs to, and
    /// then *scaled* to whatever the container is at this instant.
    ///
    /// This is how the real island does it, and it is measurable. Tracking the
    /// artwork's left inset through a reference expansion frame by frame: at
    /// 85.5% of final width the inset is 55px, at 94.5% it is 61px, at 98.6% it
    /// is 64px — against a final 65px. A fixed margin would hold at 65
    /// throughout; those are 55.6, 61.4 and 64.1 for a margin scaling with the
    /// container. It scales.
    ///
    /// Laying out at the container's *current* size instead — which is what
    /// this used to do — re-flows everything on every frame: a 624pt layout
    /// crushed into a 384pt-wide, 101pt-tall box puts rows on top of each other
    /// and pushes elements past the silhouette's rounded corners. Nothing is
    /// where it will end up, so nothing reads as travelling there.
    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .idle:
            // Deliberately empty. At rest the shape is the cutout, and the
            // cutout has nothing in it.
            Color.clear
        case .compact:
            scaled(.compact) { CompactContentView(model: model, morph: morph) }
                // Barely any blur: a 19pt thumbnail defocused hard just looks
                // like a smudge.
                .transition(.island(blur: 7, origin: origin(for: .compact)))
        case .peek:
            scaled(.peek) { PeekContentView(model: model, morph: morph) }
                .transition(.island(blur: 11, origin: origin(for: .peek)))
        case .expanded:
            scaled(.expanded) { ExpandedContentView(model: model, morph: morph) }
                .transition(.island(blur: 15, origin: origin(for: .expanded)))
        }
    }

    /// Where a state's contents come from and go back to: the resting pill,
    /// expressed as a fraction of that state's own size.
    private func origin(for presentation: NotchPresentation) -> CGSize {
        let resting = model.size(for: model.restingPresentation)
        let target = model.size(for: presentation)
        return CGSize(
            width: min(1, resting.width / max(target.width, 1)),
            height: min(1, resting.height / max(target.height, 1))
        )
    }

    /// Lays a presentation's contents out at their own size and clips them to
    /// their own silhouette. The scale onto the container comes from the
    /// transition — see `AnyTransition.island(blur:origin:)`.
    private func scaled<V: View>(
        _ presentation: NotchPresentation,
        @ViewBuilder _ body: () -> V
    ) -> some View {
        let target = model.size(for: presentation)
        let radii = model.cornerRadii(for: presentation)

        return body()
            .frame(width: max(target.width, 1), height: max(target.height, 1), alignment: .top)
            // Clipped here, in the content's own coordinate space, where the
            // silhouette is a constant. An outer clip sizes itself from layout,
            // and layout resolves to the *destination* size while the shape
            // behind is still travelling — so the contents hang out of the
            // bottom of a panel that has not grown into them yet.
            .clipShape(NotchShape(
                topRadius: radii.top,
                bottomRadius: radii.bottom,
                style: model.geometry.style
            ))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard Preferences.shared.shelfEnabled else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            model.onDrop?(urls)
        }
        return true
    }
}

// MARK: - Compact

/// Slivers of information in the margins either side of the cutout — the only
/// place they are visible while the notch is at rest.
private struct CompactContentView: View {
    let model: NotchViewModel
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .frame(maxHeight: .infinity)
        // Padding rather than fixed-width slots: centring content inside equal
        // slots only looks balanced when the two contents happen to be the same
        // width, and a meter is never as wide as a thumbnail.
        .padding(.horizontal, 10)
    }

    private var tint: Color {
        Preferences.shared.tintFromArtwork ? model.media.accent : .white
    }

    @ViewBuilder
    private var leading: some View {
        switch Preferences.shared.idleStyle {
        case .miniMedia:
            if model.showsCompactLyrics {
                HStack(spacing: 8) {
                    artworkThumbnail
                    CompactLyricLine(model: model)
                }
            } else if let artwork = model.media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: model.compactArtworkEdge, height: model.compactArtworkEdge)
                    .clipShape(RoundedRectangle(cornerRadius: model.compactArtworkEdge * 0.28, style: .continuous))
                    .dimmedWhenPaused(model.media.isPlaying)
                    .morphing(
                        Morph.artwork,
                        in: morph,
                        isSource: model.presentation == .compact,
                        enabled: model.morphsArtwork
                    )
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .clock, .plain:
            EmptyView()
        }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let artwork = model.media.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: model.compactArtworkEdge, height: model.compactArtworkEdge)
                .clipShape(
                    RoundedRectangle(cornerRadius: model.compactArtworkEdge * 0.28, style: .continuous)
                )
                .dimmedWhenPaused(model.media.isPlaying)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch Preferences.shared.idleStyle {
        case .miniMedia:
            HStack(spacing: 7) {
                if model.showsFocusIndicator {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple)
                        .transition(.blurFade(radius: 4))
                }
                if Preferences.shared.visualizerEnabled {
                    SpectrumView(
                        isActive: model.media.isPlaying,
                        animates: Preferences.shared.animateRestingMeter,
                        tint: tint,
                        barCount: 5,
                        maxHeight: model.compactMeterHeight,
                        barWidth: 2.5
                    )
                    .morphing(
                        Morph.spectrum,
                        in: morph,
                        isSource: model.presentation == .compact,
                        enabled: model.morphsSpectrum
                    )
                }
            }
        case .clock:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
        case .plain:
            EmptyView()
        }
    }
}

// MARK: - Peek

/// The transient banner: a track change, files landing, a drag hovering.
private struct PeekContentView: View {
    let model: NotchViewModel
    let morph: Namespace.ID

    var body: some View {
        if case .level(let info) = model.activity {
            levelBanner(info)
        } else {
            standard
        }
    }

    /// A HUD is one glyph, one bar and one number — split around the cutout
    /// like every other row at this latitude. The bar stays entirely in the
    /// leading region: running it under the housing would hide the part that is
    /// actually filling, which is the only thing the bar is for.
    private func levelBanner(_ info: HUDInfo) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: info.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(info.tint)
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))

                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(info.tint)
                                .frame(width: proxy.size.width * info.value)
                        }
                    }
                    .frame(height: 5)
            }
            .frame(width: model.peekSideWidth, alignment: .leading)

            Color.clear.frame(width: model.islandGapWidth)

            Text("\(Int((info.value * 100).rounded()))")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                // Digits roll rather than cut, which is the system's own
                // treatment for a number changing under you.
                .contentTransition(.numericText(value: info.value * 100))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: model.peekSideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.content(Preferences.shared.motion), value: info.value)
    }

    /// Split around the cutout, never centred. A banner that puts its text in
    /// the middle of this row posts it behind the camera housing, where there
    /// are no pixels — the message is simply not on screen.
    private var standard: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                icon
                // Keyed on the text, so a banner that absorbs a second event
                // cross-fades to the new wording instead of cutting to it. This
                // is the whole visible half of absorption: without it a burst of
                // track changes reads as the label glitching.
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(title)
                    .transition(.blurFade(radius: 5))
            }
            .frame(width: model.peekSideWidth, alignment: .leading)

            Color.clear.frame(width: model.islandGapWidth)

            HStack(spacing: 8) {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .id(subtitle)
                        .transition(.blurFade(radius: 5))
                }
                trailing
            }
            .frame(width: model.peekSideWidth, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.activity {
        case .trackChanged:
            if let artwork = model.media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .dimmedWhenPaused(model.media.isPlaying)
                    .morphing(
                        Morph.artwork,
                        in: morph,
                        isSource: model.presentation == .peek,
                        enabled: model.morphsArtwork
                    )
            } else {
                badge("music.note")
            }
        case .filesAdded:
            badge("tray.and.arrow.down.fill")
        case .dropTarget:
            badge("arrow.down.circle.fill")
        case .info(let info):
            badge(info.symbol, fill: info.tint)
        case .level, nil:
            EmptyView()
        }
    }

    private func badge(_ symbol: String, fill: Color? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: 28, height: 28)
            .background(Circle().fill(fill ?? tint))
    }

    private var tint: Color {
        Preferences.shared.tintFromArtwork ? model.media.accent : .white
    }

    private var title: String {
        switch model.activity {
        case .trackChanged: model.media.nowPlaying?.title ?? "재생 중"
        case .filesAdded(let count): "선반에 \(count)개 보관됨"
        case .dropTarget: "놓으면 보관됩니다"
        case .info(let info): info.title
        case .level, nil: ""
        }
    }

    private var subtitle: String? {
        switch model.activity {
        case .trackChanged: model.media.nowPlaying?.artist
        case .filesAdded: "노치를 열어 다시 꺼낼 수 있어요"
        case .dropTarget: "노치 위에서 손을 떼세요"
        case .info(let info): info.subtitle
        case .level, nil: nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.activity {
        case .trackChanged:
            SpectrumView(
                isActive: model.media.isPlaying,
                animates: Preferences.shared.animateRestingMeter,
                tint: tint,
                barCount: 5,
                maxHeight: 16,
                barWidth: 2.5
            )
                .morphing(
                    Morph.spectrum,
                    in: morph,
                    isSource: model.presentation == .peek,
                    enabled: model.morphsSpectrum
                )
        case .info(let info):
            if let value = info.trailingValue {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .contentTransition(.numericText())
                    .foregroundStyle(info.tint)
            }
        case .filesAdded, .dropTarget, .level, nil:
            EmptyView()
        }
    }
}

// MARK: - Expanded

private struct ExpandedContentView: View {
    let model: NotchViewModel
    let morph: Namespace.ID

    var body: some View {
        VStack(spacing: 16) {
            islandRow

            Group {
                switch model.tab {
                case .media:
                    MediaPanelView(model: model, morph: morph)
                case .shelf:
                    ShelfPanelView(model: model)
                case .devices:
                    DevicesPanelView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.blurFade(radius: 8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, NotchGeometry.contentMargin)
        .padding(.top, 4)
        .padding(.bottom, NotchGeometry.contentMargin - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The header straddles the camera housing: controls sit in the leading and
    /// trailing regions with an untouchable gap between them, mirroring how the
    /// Dynamic Island splits its compact presentation around the cutout.
    private var visibleTabs: [NotchTab] {
        NotchTab.allCases.filter(isAvailable)
    }

    private var islandRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(visibleTabs) { tab in
                    tabButton(tab, showsLabel: model.showsTabLabels(visibleTabs: visibleTabs.count))
                }
            }
            // A fixed width, not `maxWidth`: letting this flex means it eats
            // into the cutout gap the moment a third tab appears, and the
            // labels get truncated into single syllables against the housing.
            .frame(width: model.islandSideWidth(for: .expanded), alignment: .leading)
            .transition(.blurFade(radius: 6, spread: 22))

            Color.clear
                .frame(width: model.islandGapWidth)

            HStack(spacing: 8) {
                if let name = model.media.sourceName, model.tab == .media, model.showsSourceName {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .transition(.blurFade(radius: 4))
                }

                // Shown whenever lyrics *could* apply, not only once they have
                // arrived. A control that appears and disappears depending on
                // whether a lookup succeeded is a control nobody finds.
                if model.tab == .media, Preferences.shared.lyricsEnabled, model.media.hasTrack {
                    NotchButton(action: {
                        guard model.media.lyrics.lyrics?.isSynced == true else { return }
                        withAnimation(Motion.transition(Preferences.shared.motion)) {
                            Preferences.shared.showLyrics.toggle()
                        }
                    }) {
                        Image(systemName: lyricsSymbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(lyricsOpacity))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 26, height: 26)
                    .help(lyricsHelp)
                    .transition(.blurFade(radius: 4))
                }

                // Read-only, so an indicator rather than a control. A button
                // that cannot act is worse than no button.
                if Preferences.shared.focusEnabled, model.focus.isFocused {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.purple)
                        .frame(width: 20, height: 26)
                        .help("집중 모드 켜짐")
                        .transition(.blurFade(radius: 4))
                }

                NotchButton(action: { model.onOpenSettings?() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 26, height: 26)
            }
            .frame(width: model.islandSideWidth(for: .expanded), alignment: .trailing)
            .transition(.blurFade(radius: 6, spread: -22))
        }
        .frame(height: model.islandRowHeight)
    }

    private var lyricsSymbol: String {
        if model.media.lyrics.isLoading { return "ellipsis.bubble" }
        if model.media.lyrics.lyrics?.isSynced == true { return "quote.bubble.fill" }
        return "quote.bubble"
    }

    private var lyricsOpacity: Double {
        guard model.media.lyrics.lyrics?.isSynced == true else { return 0.28 }
        return Preferences.shared.showLyrics ? 0.9 : 0.45
    }

    private var lyricsHelp: String {
        if model.media.lyrics.isLoading { return "가사 찾는 중…" }
        if model.media.lyrics.lyrics?.isSynced == true {
            return Preferences.shared.showLyrics ? "가사 숨기기" : "가사 보기"
        }
        return "이 곡의 동기화 가사를 찾지 못했습니다"
    }

    private func isAvailable(_ tab: NotchTab) -> Bool {
        switch tab {
        case .media: Preferences.shared.mediaEnabled
        case .shelf: Preferences.shared.shelfEnabled
        // Hidden until something is actually connected: three tabs will not
        // fit beside the cutout on a 14", and an empty tab earns no space.
        case .devices: !model.bluetooth.devices.isEmpty
        }
    }

    private func tabButton(_ tab: NotchTab, showsLabel: Bool) -> some View {
        let selected = model.tab == tab
        return Button {
            guard !selected else { return }
            withAnimation(Motion.transition(Preferences.shared.motion)) {
                model.tab = tab
            }
            Haptics.tap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                if showsLabel {
                    Text(tab.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize()
                }
                if tab == .shelf, !model.shelf.isEmpty {
                    Text("\(model.shelf.items.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(
                            Motion.content(Preferences.shared.motion),
                            value: model.shelf.items.count
                        )
                        .contentTransition(.numericText())
                        .animation(
                            Motion.content(Preferences.shared.motion),
                            value: model.shelf.items.count
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.18)))
                        .transition(.blurFade(radius: 4))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.42))
            .padding(.horizontal, showsLabel ? 11 : 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(selected ? 0.13 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.content(Preferences.shared.motion), value: selected)
    }
}

// MARK: - Drop plumbing

extension NSItemProvider {
    /// Bridges the completion-handler API into async, resolving exactly once.
    func fileURL() async -> URL? {
        guard canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}


/// The line being sung, in the resting island.
///
/// One line only, and only in the region beside the cutout. Two lines would not
/// fit in a 32pt band, and running the text across the middle would post it
/// behind the camera housing.
private struct CompactLyricLine: View {
    let model: NotchViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.media.isPlaying ? 0.25 : 3600)) { context in
            let line = currentLine(at: context.date)

            Text(line)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(line)
                .transition(.blurFade(radius: 5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.transition(Preferences.shared.motion), value: line)
        }
    }

    private func currentLine(at date: Date) -> String {
        guard
            let track = model.media.nowPlaying,
            let lyrics = model.media.lyrics.lyrics,
            let index = lyrics.index(at: track.elapsed(at: date)),
            lyrics.lines.indices.contains(index)
        else { return "♪" }

        let text = lyrics.lines[index].text
        return text.isEmpty ? "♪" : text
    }
}


/// Sizes the notch on two independent clocks.
///
/// Height is set on the inside with its own, faster animation; width wraps it
/// with the slower, springier one. An inner explicit animation wins over an
/// outer one, so the axes genuinely run on separate springs — which is what
/// makes the panel spread along the bezel before it descends, and pull its
/// height home before its width on the way back.
struct NotchSizing: ViewModifier {
    var size: CGSize
    var width: Animation
    var height: Animation

    func body(content: Content) -> some View {
        content
            // Top-aligned rather than centred, so the layer needs no filler view
            // to hold it open. A `Color.clear` behind the content did the same
            // job and measured at three points of CPU through every transition:
            // it is a full-size solid that gets composited on every frame.
            .frame(height: size.height, alignment: .top)
            .animation(height, value: size.height)
            .frame(width: size.width)
            .animation(width, value: size.width)
    }
}
