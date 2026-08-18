import AgentSessionLive
import AuspexCore
import Foundation

/// Replays ``DemoScript`` against the wall clock, forever.
///
/// The script says *what* happens and *when*, relative to the start of a loop.
/// This says *now*: it sleeps until each step is due and re-stamps the event
/// with the real emission time, so a card's elapsed-in-state stopwatch and the
/// trace's timestamps are honest even though the session is not.
///
/// Sleeping against a `ContinuousClock` deadline computed from the loop's
/// start — rather than sleeping for each gap in turn — keeps the replay from
/// drifting: a scheduler hiccup costs one late event instead of shifting
/// everything after it.
///
/// Nothing here touches the filesystem. In demo mode the store is in memory
/// and no adapter is constructed, so a demo run reads no harness store and
/// writes nothing to `~/.auspex/`.
actor DemoEventSource {
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let seed: UInt64

    /// Pause between loops, so the board visibly settles before the sessions
    /// start over rather than snapping back mid-animation.
    private static let loopGap = Duration.seconds(5)

    init(continuation: AsyncStream<AgentEvent>.Continuation, seed: UInt64 = DemoScript.defaultSeed) {
        self.continuation = continuation
        self.seed = seed
    }

    /// Runs until the surrounding task is cancelled.
    func run() async {
        var generation = 0
        while !Task.isCancelled {
            await replay(generation: generation)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: Self.loopGap)
            generation += 1
        }
    }

    private func replay(generation: Int) async {
        let script = DemoScript.make(seed: seed, startedAt: Date(), generation: generation)
        let start = ContinuousClock.now
        for step in script.steps {
            let due = start.advanced(by: .seconds(step.offset))
            if due > ContinuousClock.now {
                do {
                    try await Task.sleep(until: due, clock: .continuous)
                } catch {
                    return  // cancelled
                }
            }
            guard !Task.isCancelled else { return }
            continuation.yield(restamped(step.event))
        }
    }

    /// The same event, happening now.
    private func restamped(_ event: AgentEvent) -> AgentEvent {
        let now = Date()
        return AgentEvent(
            id: event.id,
            session: event.session,
            timestamp: now,
            observedAt: now,
            sequence: event.sequence,
            kind: event.kind,
            raw: event.raw
        )
    }
}
