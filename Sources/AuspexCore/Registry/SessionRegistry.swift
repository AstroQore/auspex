import AgentSessionKit
import AgentSessionLive
import Foundation
import GRDB

/// The live set of sessions: it consumes the merged ``AgentEvent`` stream,
/// folds it through ``SessionStateReducer``, persists what it learns, and
/// publishes ``BoardSnapshot`` frames for the UI.
///
/// An actor because three things touch the same state from different places —
/// the ingest task, the one-second staleness ticker, and whoever pulls
/// ``snapshot()`` — and none of them should have to know about the others.
///
/// ## Rates
///
/// Events arrive in bursts: a harness writes a whole turn's worth of records
/// in one flush, so a hundred events can land in the same millisecond. Two
/// separate valves keep that from reaching either end untouched:
///
/// - **Publishing is coalesced** to at most one frame per `publishInterval`
///   (50 ms, so ≤ 20 Hz). A board redrawn faster than that is redrawn for
///   nobody, and each frame sorts every session.
/// - **Persistence is batched** into one transaction per `persistInterval`
///   (250 ms). Committing per event would turn a burst into a hundred fsyncs.
///
/// Both are configurable, and both accept `0` to mean "immediately", which is
/// what tests use so a scripted sequence produces one frame per event.
///
/// ## Restarts
///
/// ``bootstrap()`` reloads stored snapshots before the first event, so
/// relaunching Auspex shows the board it had rather than an empty one that
/// fills in as each harness happens to write its next line.
public actor SessionRegistry {
    /// The frame stream the UI observes. Single-consumer, like every
    /// `AsyncStream`; the board model is that consumer.
    ///
    /// Buffered newest-first: a consumer that stalls loses old frames rather
    /// than growing the buffer, because a stale frame has no value once a
    /// newer one exists.
    public nonisolated let boardSnapshots: AsyncStream<BoardSnapshot>

    private let continuation: AsyncStream<BoardSnapshot>.Continuation
    private let repository: SessionRepository
    private let reducer: SessionStateReducer
    private let publishInterval: TimeInterval
    private let persistInterval: TimeInterval
    private let tickInterval: TimeInterval
    private let bootstrapLimit: Int?
    private let policy: RetentionPolicy

    /// The live set. The reducer's output is the only thing that writes here.
    private var snapshots: [SessionKey: SessionSnapshot] = [:]

    // Write buffers, drained by `flushPendingWrites()`.
    private var dirtyKeys: Set<SessionKey> = []
    private var pendingEvents: [AgentEvent] = []
    private var pendingMessages: [IndexedMessage] = []
    private var pendingToolCalls: [ToolCallWrite] = []

    private var lastPublishedAt: Date?
    private var publishTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isFlushing = false
    private var didBootstrap = false
    private var isStopped = false

    /// How many persist transactions have failed. A board that is live but
    /// not durable is still worth showing, so a write failure is counted
    /// rather than thrown — but it must be visible.
    public private(set) var persistFailureCount = 0

    /// The most recent persist failure. GRDB's plain description carries the
    /// statement but not its bound arguments, which is what keeps prompt text
    /// out of a diagnostic string.
    public private(set) var lastPersistErrorDescription: String?

    /// Creates a registry over `store`.
    ///
    /// - Parameters:
    ///   - reducer: the fold from events to state. Injectable so a caller can
    ///     change `staleAfter`.
    ///   - publishInterval: minimum gap between published frames. `0` publishes
    ///     on every change.
    ///   - persistInterval: how long writes are batched before committing. `0`
    ///     commits on every event.
    ///   - tickInterval: how often staleness is re-evaluated while
    ///     ``run(events:)`` is active. `0` disables the internal ticker;
    ///     ``tick(now:)`` still works when called directly.
    ///   - policy: consulted before indexing text, so an excluded harness is
    ///     never written to the search index in the first place.
    ///   - bootstrapLimit: how many stored sessions ``bootstrap()`` reloads,
    ///     most recently active first. `nil` reloads all of them.
    public init(
        store: AuspexStore,
        reducer: SessionStateReducer = SessionStateReducer(),
        publishInterval: TimeInterval = 0.05,
        persistInterval: TimeInterval = 0.25,
        tickInterval: TimeInterval = 1,
        policy: RetentionPolicy = .default,
        bootstrapLimit: Int? = 500,
        boardBufferSize: Int = 256
    ) {
        self.repository = SessionRepository(store: store)
        self.reducer = reducer
        self.publishInterval = publishInterval
        self.persistInterval = persistInterval
        self.tickInterval = tickInterval
        self.policy = policy
        self.bootstrapLimit = bootstrapLimit
        let (stream, continuation) = AsyncStream<BoardSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(boardBufferSize)
        )
        self.boardSnapshots = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    /// Reloads stored snapshots into the live set, once.
    ///
    /// Only sessions the live set does not already know are taken, so calling
    /// this after events have arrived cannot overwrite fresher state with what
    /// was on disk.
    public func bootstrap() throws {
        guard !didBootstrap else { return }
        didBootstrap = true
        let stored = try repository.fetchAll(activeOnly: false, limit: bootstrapLimit)
        for snapshot in stored where snapshots[snapshot.key] == nil {
            snapshots[snapshot.key] = snapshot
        }
        if !stored.isEmpty { schedulePublish() }
    }

    /// Consumes the event stream until it finishes or ``stop()`` is called,
    /// then flushes.
    public func run(events: AsyncStream<AgentEvent>) async {
        if !didBootstrap {
            do {
                try bootstrap()
            } catch {
                didBootstrap = true
                recordFailure(error)
            }
        }
        startTicker()
        for await event in events {
            if isStopped { break }
            ingest(event)
        }
        await stop()
    }

    /// Stops the timers, commits everything buffered, publishes a final frame,
    /// and closes ``boardSnapshots``.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true

        tickerTask?.cancel()
        tickerTask = nil
        publishTask?.cancel()
        publishTask = nil

        // Wait for an in-flight persist rather than cancelling it: GRDB honours
        // task cancellation, so cancelling here would abort the transaction it
        // is in the middle of and lose the batch it had already drained. The
        // cost is at most one `persistInterval` of shutdown latency.
        let inFlight = persistTask
        persistTask = nil
        await inFlight?.value

        await flushPendingWrites()
        publish()
        continuation.finish()
    }

    // MARK: - Reading

    /// The current board, for a pull rather than a subscription.
    public func snapshot() -> BoardSnapshot {
        BoardSnapshot(generatedAt: Date(), sessions: Array(snapshots.values))
    }

    /// The live snapshot for one session, if it is known.
    public func session(for key: SessionKey) -> SessionSnapshot? {
        snapshots[key]
    }

    // MARK: - Ingest

    /// Applies one event: fold, buffer, and schedule.
    ///
    /// Public so a hook ingress can hand over an out-of-band event without
    /// having to own a stream of its own.
    public func ingest(_ event: AgentEvent) {
        guard !isStopped else { return }
        let key = event.session
        let previous = snapshots[key] ?? seedSnapshot(for: event)
        let next = reducer.reduce(previous, event: event)
        let isNew = snapshots[key] == nil

        snapshots[key] = next
        dirtyKeys.insert(key)
        pendingEvents.append(event)
        collectDerivedWrites(from: event, before: previous)

        schedulePersist()
        if isNew || next != previous { schedulePublish() }
    }

    /// The snapshot an unknown session starts from.
    ///
    /// A tail almost never begins at `sessionStarted` — it begins wherever the
    /// transcript was when Auspex looked. When that is all we have, the
    /// identity is just the key and whatever file the event was read from;
    /// every other field stays empty until an `identityUpdated` patch fills it
    /// in, because an invented cwd is worse than a blank one.
    private func seedSnapshot(for event: AgentEvent) -> SessionSnapshot {
        if case .sessionStarted(let identity) = event.kind, identity.key == event.session {
            return SessionStateReducer.initialSnapshot(identity: identity)
        }
        return SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(key: event.session, sourcePath: event.raw?.path ?? "")
        )
    }

    /// Pulls the rows that are not part of the snapshot out of an event: the
    /// tool-call ledger and the search index.
    ///
    /// `before` is the snapshot as it was *prior* to this event, because a
    /// `toolCallFinished` names only the call id — the tool's name and kind
    /// are still in the pending set that the reduction is about to clear.
    private func collectDerivedWrites(from event: AgentEvent, before: SessionSnapshot) {
        switch event.kind {
        case .toolCallStarted(let id, let name, let kind, let target):
            pendingToolCalls.append(.started(
                session: event.session,
                callID: id,
                name: name,
                kind: kind,
                target: target,
                at: event.timestamp
            ))

        case .toolCallFinished(let id, let isError):
            pendingToolCalls.append(.finished(
                session: event.session,
                callID: id,
                // A finish whose start was never seen still deserves a row;
                // the call id stands in for the name we never learned.
                fallbackName: before.pending.openToolCalls[id]?.name ?? id,
                at: event.timestamp,
                isError: isError
            ))

        case .userPrompt(let preview):
            indexText(preview, role: .user, event: event)

        case .assistantText(let preview):
            indexText(preview, role: .assistant, event: event)

        default:
            break
        }
    }

    /// Queues text for the search index, unless the policy excludes the
    /// harness or the text is empty.
    private func indexText(_ text: String, role: MessageRole, event: AgentEvent) {
        let harness = event.session.harness
        guard policy.indexesText(for: harness), !text.isEmpty else { return }
        pendingMessages.append(IndexedMessage(
            session: event.session,
            harness: harness,
            role: role,
            ts: event.timestamp,
            content: text
        ))
    }

    // MARK: - Staleness

    /// Re-evaluates ``SessionSnapshot/isStale`` for every live session.
    ///
    /// Staleness is the one derived value that changes because time passed
    /// rather than because something happened: a session that goes quiet
    /// mid-tool-call produces no event to notice it by. A frame is published
    /// only if a flag actually flipped, so an idle machine publishes nothing.
    public func tick(now: Date = Date()) {
        var changed = false
        for (key, snapshot) in snapshots where snapshot.isAlive {
            let refreshed = reducer.refreshStaleness(snapshot, now: now)
            guard refreshed.isStale != snapshot.isStale else { continue }
            snapshots[key] = refreshed
            dirtyKeys.insert(key)
            changed = true
        }
        guard changed else { return }
        schedulePersist()
        schedulePublish()
    }

    private func startTicker() {
        guard tickerTask == nil, tickInterval > 0, !isStopped else { return }
        let interval = tickInterval
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.tick(now: Date())
            }
        }
    }

    // MARK: - Publishing

    private func schedulePublish() {
        guard !isStopped else { return }
        guard publishInterval > 0, let last = lastPublishedAt else {
            publish()
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed >= publishInterval {
            publish()
            return
        }
        // Inside the coalescing window: let the already-scheduled trailing
        // publish carry this change, or schedule one.
        guard publishTask == nil else { return }
        let delay = publishInterval - elapsed
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.publishFromTimer()
        }
    }

    private func publishFromTimer() {
        publishTask = nil
        guard !isStopped else { return }
        publish()
    }

    private func publish() {
        lastPublishedAt = Date()
        continuation.yield(snapshot())
    }

    // MARK: - Persistence

    private func schedulePersist() {
        guard persistTask == nil, !isStopped else { return }
        guard persistInterval > 0 else {
            // Synchronous batching is off; commit this event's batch now.
            persistTask = Task { [weak self] in
                await self?.persistFromTimer()
            }
            return
        }
        let interval = persistInterval
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            await self?.persistFromTimer()
        }
    }

    /// Runs the scheduled flush and only then releases the slot.
    ///
    /// Clearing `persistTask` *before* the flush would leave ``stop()`` with
    /// nothing to wait on while a transaction was still open, and its own
    /// flush would find `isFlushing` set and return having written nothing.
    /// Events buffered at shutdown would be lost. Holding the handle until the
    /// flush returns is what makes "stop flushes" true.
    private func persistFromTimer() async {
        await flushPendingWrites()
        persistTask = nil
    }

    /// Commits everything buffered, in one transaction per drained batch.
    ///
    /// Sessions are written before the events that reference them, because
    /// `events.session_key` and `tool_calls.session_key` are foreign keys. The
    /// loop re-checks for work after each commit so events that arrived during
    /// the write are not left for a timer that may never be scheduled again.
    public func flushPendingWrites() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while hasPendingWork {
            let sessionsToWrite = dirtyKeys.compactMap { snapshots[$0] }
            let events = pendingEvents
            let messages = pendingMessages
            let toolCalls = pendingToolCalls
            dirtyKeys.removeAll(keepingCapacity: true)
            pendingEvents.removeAll(keepingCapacity: true)
            pendingMessages.removeAll(keepingCapacity: true)
            pendingToolCalls.removeAll(keepingCapacity: true)

            let repository = self.repository
            do {
                try await repository.dbWriter.write { db in
                    try repository.upsert(snapshots: sessionsToWrite, in: db)
                    try repository.insertEvents(events, in: db)
                    for call in toolCalls {
                        try call.apply(using: repository, in: db)
                    }
                    try repository.indexMessages(messages, in: db)
                }
            } catch {
                recordFailure(error)
            }
        }
    }

    private var hasPendingWork: Bool {
        !dirtyKeys.isEmpty || !pendingEvents.isEmpty
            || !pendingMessages.isEmpty || !pendingToolCalls.isEmpty
    }

    private func recordFailure(_ error: any Error) {
        persistFailureCount += 1
        lastPersistErrorDescription = String(describing: error)
    }

    /// A buffered write to `tool_calls`. Two cases rather than one row because
    /// a finish must not overwrite the name and kind the start recorded.
    private enum ToolCallWrite: Sendable {
        case started(
            session: SessionKey,
            callID: String,
            name: String,
            kind: ToolKind,
            target: String?,
            at: Date
        )
        case finished(
            session: SessionKey,
            callID: String,
            fallbackName: String,
            at: Date,
            isError: Bool
        )

        func apply(using repository: SessionRepository, in db: Database) throws {
            switch self {
            case .started(let session, let callID, let name, let kind, let target, let at):
                try repository.upsertToolCall(
                    sessionKey: session,
                    callID: callID,
                    name: name,
                    kind: kind,
                    target: target,
                    startedAt: at,
                    endedAt: nil,
                    isError: nil,
                    in: db
                )
            case .finished(let session, let callID, let fallbackName, let at, let isError):
                try repository.finishToolCall(
                    sessionKey: session,
                    callID: callID,
                    fallbackName: fallbackName,
                    endedAt: at,
                    isError: isError,
                    in: db
                )
            }
        }
    }
}
