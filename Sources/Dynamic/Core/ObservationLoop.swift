import Observation

/// Turns `withObservationTracking`'s one-shot callback into a standing
/// subscription.
///
/// `withObservationTracking` fires `onChange` exactly once and then forgets the
/// dependency, so anything that wants to keep watching has to re-register. This
/// loops that for you and cancels cleanly with the returned task.
///
/// `track` must read at least one observable property, otherwise nothing will
/// ever resume the loop.
@MainActor
func observeChanges(
    track: @escaping @MainActor () -> Void,
    onChange: @escaping @MainActor () -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        while !Task.isCancelled {
            await withCheckedContinuation { continuation in
                withObservationTracking(track) {
                    continuation.resume()
                }
            }

            // `onChange` fires *before* the new value is committed, so yield a
            // turn to let the write land before anyone reads it back.
            await Task.yield()
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
