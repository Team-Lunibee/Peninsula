import AVKit
import SwiftUI

/// The expanded Now Playing panel, laid out like the Dynamic Island's own
/// expanded presentation: artwork, metadata and meter on one row; a full-width
/// scrubber with elapsed and remaining *outside* the bar; then five evenly
/// distributed transport controls.
struct MediaPanelView: View {
    let model: NotchViewModel
    let morph: Namespace.ID

    private static let artworkEdge: CGFloat = 72

    private var media: MediaEngine { model.media }
    private var tint: Color {
        Preferences.shared.tintFromArtwork ? media.accent : .white
    }

    var body: some View {
        Group {
            if let reason = media.unavailableReason {
                placeholder(
                    symbol: "exclamationmark.triangle",
                    tint: .orange.opacity(0.75),
                    title: "재생 정보를 가져올 수 없음",
                    detail: reason
                )
            } else if let track = media.nowPlaying {
                player(track)
            } else {
                placeholder(
                    symbol: "music.note.list",
                    tint: .white.opacity(0.3),
                    title: "재생 중인 항목 없음",
                    detail: "음악, Spotify 등 어떤 플레이어든 재생하면 여기에 나타납니다"
                )
            }
        }
        .animation(Motion.transition(Preferences.shared.motion), value: media.hasTrack)
    }

    // MARK: - Player

    private func player(_ track: NowPlaying) -> some View {
        VStack(spacing: 14) {
            header(track)
            progress(track)
            transport
        }
    }

    private func header(_ track: NowPlaying) -> some View {
        HStack(alignment: .center, spacing: 18) {
            artwork

            if showsLyrics {
                LyricsStrip(track: track, media: media)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: track.title, font: .system(size: 16, weight: .semibold))

                    Text(track.artist ?? track.album ?? "아티스트 정보 없음")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .transition(.blurFade(radius: 6))
            }

            Spacer(minLength: 14)

            // The gap between the metadata and the meter was dead space, and
            // volume is the one control the island has no answer for on a Mac.
            VolumeControl(tint: tint)
                .frame(width: 132)
                .transition(.blurFade(radius: 6, spread: -26))

            if Preferences.shared.visualizerEnabled {
                SpectrumView(isActive: media.isPlaying, tint: tint, barCount: 6, maxHeight: 26)
                    .transition(.blurFade(radius: 6, spread: -34))
                    .morphing(
                        Morph.spectrum,
                        in: morph,
                        isSource: model.presentation == .expanded,
                        enabled: model.morphsSpectrum
                    )
            }
        }
        .frame(height: Self.artworkEdge)
        .animation(Motion.transition(Preferences.shared.motion), value: showsLyrics)
    }

    /// Lyrics take over the metadata column only when there is something timed
    /// to show. A block of unsynced text in a 72pt row is worse than the title.
    private var showsLyrics: Bool {
        Preferences.shared.lyricsEnabled
            && Preferences.shared.showLyrics
            && (media.lyrics.lyrics?.isSynced ?? false)
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(media.trackToken)
                    .transition(.artworkFlip)
            } else {
                LinearGradient(
                    colors: [tint.opacity(0.32), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: Self.artworkEdge, height: Self.artworkEdge)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .dimmedWhenPaused(media.isPlaying)
        .morphing(
            Morph.artwork,
            in: morph,
            isSource: model.presentation == .expanded,
            enabled: model.morphsArtwork
        )
        // The flip wants a spring, not the flat curve the rest of the content
        // swaps on — a card turning over has weight.
        .animation(Motion.open(Preferences.shared.motion), value: media.trackToken)
    }

    /// Elapsed and remaining sit either side of the bar rather than under it,
    /// and remaining counts down as a negative — both straight from the island.
    ///
    /// Position is extrapolated from the last sample the adapter sent, so this
    /// ticks locally at 2Hz instead of asking the media player anything.
    private func progress(_ track: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: media.isPlaying ? 0.5 : 3600)) { context in
            let elapsed = track.elapsed(at: context.date)
            let duration = track.duration ?? 0
            let remaining = max(0, duration - elapsed)

            HStack(spacing: 14) {
                Text(elapsed.playbackClock)
                    // Digits roll rather than swap. It is the system's own
                    // treatment for a changing number, and at 2Hz a hard cut
                    // reads as a flicker.
                    .contentTransition(.numericText(countsDown: false))
                    .animation(Motion.content(Preferences.shared.motion), value: Int(elapsed))
                    .frame(width: 42, alignment: .leading)

                Scrubber(
                    progress: duration > 0 ? min(1, elapsed / duration) : 0,
                    tint: .white.opacity(0.85),
                    onSeek: { media.seek(toFraction: $0) }
                )

                Text(duration > 0 ? "−" + remaining.playbackClock : "--:--")
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.content(Preferences.shared.motion), value: Int(remaining))
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Favourite and output pin to the edges; the three transport controls are
    /// grouped in the middle rather than spread across the full width. They are
    /// used together and in sequence, so travel between them is what the layout
    /// should minimise.
    private var transport: some View {
        HStack(spacing: 0) {
            glyph(
                media.isFavorite ? "star.fill" : "star",
                size: 17,
                action: media.toggleFavorite
            )
            .opacity(media.supportsFavorite ? 1 : 0.28)
            .disabled(!media.supportsFavorite)

            Spacer(minLength: 12)

            HStack(spacing: 22) {
                glyph("backward.fill", size: 19, action: media.previousTrack)
                glyph(media.isPlaying ? "pause.fill" : "play.fill", size: 23, action: media.togglePlayPause)
                glyph("forward.fill", size: 19, action: media.nextTrack)
            }

            Spacer(minLength: 12)

            // Mounted only once the panel has landed.
            //
            // `AVRoutePickerView` is an AppKit view, and SwiftUI has to hand any
            // AppKit view it hosts new geometry through `-[NSView setFrame…]` on
            // every animation frame, which dirties Auto Layout and the window's
            // tracking areas all the way up. Keeping it out of the resize is
            // worth a point of CPU, and it costs a 100ms-late fade on a glyph
            // nobody is looking at while the panel is still moving.
            ZStack {
                Color.clear
                if model.isSettled {
                    RoutePickerButton(tint: .white.opacity(0.9))
                        .transition(.blurFade(radius: 4))
                }
            }
            .frame(width: 28, height: 28)
        }
        .foregroundStyle(.white)
        .frame(height: 30)
    }

    private func glyph(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        NotchButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 36, height: 30)
    }

    // MARK: - Fallback

    private func placeholder(symbol: String, tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Paused artwork loses colour and a little light, so playback state reads
    /// at a glance instead of only from the play/pause glyph.
    func dimmedWhenPaused(_ isPlaying: Bool) -> some View {
        saturation(isPlaying ? 1 : 0.45)
            .opacity(isPlaying ? 1 : 0.72)
            .animation(Motion.content(Preferences.shared.motion), value: isPlaying)
    }
}

/// The system's own output-route picker — the Mac counterpart to the island's
/// AirPlay button. Presenting Apple's picker rather than a lookalike means the
/// routes it offers are always the real ones.
private struct RoutePickerButton: NSViewRepresentable {
    var tint: NSColor

    init(tint: Color) {
        self.tint = NSColor(tint)
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(tint, for: .normal)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.setRoutePickerButtonColor(tint, for: .normal)
    }
}


/// Three lines of a song: what just went, what is being sung, what is next.
///
/// Only the current line is fully lit. Showing the whole sheet would be a
/// karaoke display; the point here is a glance that tells you where you are.
private struct LyricsStrip: View {
    let track: NowPlaying
    let media: MediaEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: media.isPlaying ? 0.25 : 3600)) { context in
            let elapsed = track.elapsed(at: context.date)
            let lines = media.lyrics.lyrics?.lines ?? []
            let index = media.lyrics.lyrics?.index(at: elapsed)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)

                Text(text(lines, at: index))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .id(index ?? -1)
                    .transition(.blurFade(radius: 6))

                Text(text(lines, at: index.map { $0 + 1 }))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.transition(Preferences.shared.motion), value: index)
        }
    }

    /// Blank lines are real content in an LRC — they are the instrumental gaps
    /// — so an empty string is rendered as a rest rather than skipped.
    private func text(_ lines: [LyricLine], at index: Int?) -> String {
        guard let index, lines.indices.contains(index) else { return " " }
        let value = lines[index].text
        return value.isEmpty ? "♪" : value
    }
}
