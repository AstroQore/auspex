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

    /// The real `/bin/sleep` one demo session borrows a pid from, so that
    /// Interrupt and Kill can be tried by hand. See ``DemoSignalTarget``.
    private let signalTarget = DemoSignalTarget()

    /// Whether to start that process at all. Off for the offscreen renderers,
    /// which draw a bitmap and exit.
    private let lendsProcess: Bool

    /// Pause between loops, so the board visibly settles before the sessions
    /// start over rather than snapping back mid-animation.
    private static let loopGap = Duration.seconds(5)

    /// Called once per loop, a few seconds in, so the demo's agents can say
    /// the things a board's two loud buckets are made of.
    ///
    /// A hook rather than something this type does itself, because a notice is
    /// not an event: it goes into the task ledger and onto the board model,
    /// neither of which the event source knows about. What it does know is
    /// *when* — see ``DemoScript/noticeOffset``.
    private let onLoop: (@Sendable () async -> Void)?

    init(
        continuation: AsyncStream<AgentEvent>.Continuation,
        seed: UInt64 = DemoScript.defaultSeed,
        lendsProcess: Bool = true,
        onLoop: (@Sendable () async -> Void)? = nil
    ) {
        self.continuation = continuation
        self.seed = seed
        self.lendsProcess = lendsProcess
        self.onLoop = onLoop
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

    /// Ends the stand-in process. Called from the app's own shutdown, so a
    /// demo run leaves nothing behind.
    func stop() async {
        await signalTarget.stop()
    }

    private func replay(generation: Int) async {
        let script = DemoScript.make(seed: seed, startedAt: Date(), generation: generation)
        let start = ContinuousClock.now
        var lentPID = false
        var didCall = false
        for step in script.steps {
            // After every session's live prompt has landed, because a call is
            // cleared by the person talking to that session again — one filed
            // before the loop's prompts would answer itself within seconds.
            if !didCall, step.offset >= DemoScript.noticeOffset {
                didCall = true
                await onLoop?()
            }
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

            // Straight after the first session opens, and once per loop: the
            // identity patch has to follow the `sessionStarted` it belongs to,
            // or the registry seeds the session from the patch instead.
            if lendsProcess, !lentPID, case let .sessionStarted(identity) = step.event.kind {
                lentPID = true
                await lendProcess(to: identity.key)
            }
        }
        // A short script — a test's, or one whose last beat lands early — never
        // reached the offset above, and a demo with nothing on its header is
        // not the demo.
        if !didCall { await onLoop?() }
    }

    /// Gives one demo session the pid of a live `/bin/sleep`.
    ///
    /// Through the ordinary identity patch, so nothing downstream is aware the
    /// demo did anything unusual — the guard, the menu, and the trace all see
    /// exactly what they would see for a harness whose store recorded a pid.
    private func lendProcess(to key: SessionKey) async {
        guard let stand = await signalTarget.current() else { return }
        continuation.yield(
            AgentEvent(
                session: key,
                timestamp: Date(),
                kind: .identityUpdated(
                    SessionIdentityPatch(pid: stand.pid, procStart: stand.procStart)
                )
            )
        )
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
