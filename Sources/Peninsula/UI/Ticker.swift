import SwiftUI

/// Re-renders its contents on a wall clock, without a `TimelineView`.
///
/// Measured, in isolation, against `TimelineView(.periodic(by: 0.25))` — same
/// text, same rate, the same arrangement of a small view inside a large mostly
/// transparent `NSHostingView` in a borderless panel, which is what the notch
/// is. Three interleaved rounds each:
///
///     no clock at all      ~0.09% of a core
///     TimelineView         ~1.91%
///     this                 ~0.50%
///
/// So roughly four times the cost per update, or about 1.4 points of continuous
/// CPU at four ticks a second. That is the arrangement `SpectrumView`'s comment
/// warns about (FB13810482): a `TimelineView` inside a hosting view does far
/// more of the hosting view's layout than the update it is delivering needs.
///
/// The cost is per *tick*, not per existence — a `TimelineView` parked at
/// `by: 3600` measured the same as having no clock at all. So the trick of
/// switching the interval to an hour to stop a clock without changing the view's
/// identity was doing its job. `interval: nil` stops this one just as
/// completely, and says what it means: no task, no wake-ups.
///
/// Where the notch spends this is the resting island. A lyric line ticks four
/// times a second for as long as music plays, which is this app's most common
/// state that is not doing nothing at all.
struct Ticker<Content: View>: View {
    /// `nil` stops the clock entirely.
    var interval: TimeInterval?
    @ViewBuilder var content: (Date) -> Content

    @State private var now = Date()

    var body: some View {
        content(now)
            // Keyed on the interval so a change in rate — playback starting or
            // stopping — restarts the loop, and `nil` cancels it outright
            // without touching the view's identity.
            .task(id: interval) {
                guard let interval, interval > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
    }
}
