import AgentSessionKit
import AgentSessionLive
import Foundation
import Synchronization

/// What a grouping pass remembers from the one before it, so a quiet machine
/// does not re-derive the same answer every three seconds.
///
/// Two things, both kept here rather than in the kit's ``ProcessTable``:
///
/// - **Environments, by process.** ``ProcessLinker/infer(identities:table:)``
///   asks for the environment of every parentless session that has a pid, on
///   every pass. The table caches those answers only for its own three-second
///   window, so each pass re-read them all — a `KERN_PROCARGS2` call, an
///   `ARG_MAX` buffer and a parse of the whole environment per process. An
///   environment is fixed at `exec`, so the pair `(pid, start time)` names one
///   answer for as long as that process lives; it is remembered for
///   ``environmentLifetime`` and forgotten when the pid is reused or the
///   process has gone.
/// - **The identities the last inference ran over.** The links a pass can
///   propose are a function of each session's key, pid, process start and
///   parent. When none of those moved, the previous pass already proposed
///   everything there was, and the registry already applied or refused it.
final class LinkerMemo: Sendable {
    /// How long one process's environment is trusted.
    static let environmentLifetime: TimeInterval = 10 * 60

    private struct Remembered {
        let start: Date
        let environment: [String: String]?
        let readAt: Date
    }

    /// The part of an identity an inference reads.
    struct Signature: Hashable {
        let key: SessionKey
        let pid: pid_t?
        let procStart: Date?
        let parent: SessionKey?

        init(_ identity: SessionIdentity) {
            key = identity.key
            pid = identity.pid
            procStart = identity.procStart
            parent = identity.parent
        }
    }

    private struct State {
        var environments: [pid_t: Remembered] = [:]
        var lastInference: Set<Signature>?
        var environmentReads = 0
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// `true` when `identities` give an inference nothing it has not already
    /// answered; otherwise records them as the latest and returns `false`.
    func isUnchanged(_ identities: [SessionIdentity]) -> Bool {
        let signature = Set(identities.map(Signature.init))
        return state.withLock { state in
            if state.lastInference == signature { return true }
            state.lastInference = signature
            return false
        }
    }

    /// How many environments have actually been read through this memo.
    /// Diagnostic, and what the suite asserts on.
    var environmentReadCount: Int { state.withLock { $0.environmentReads } }

    /// One process's environment, read from `table` at most once per
    /// ``environmentLifetime`` for the same process.
    func environment(pid: pid_t, in table: any ProcessTableReading) -> [String: String]? {
        // A process the table cannot place has no start to key an answer by,
        // and is most likely gone; ask, but do not remember.
        guard let start = table.record(pid: pid)?.startTime else {
            return table.environment(pid: pid)
        }
        let instant = now()
        let remembered = state.withLock { state -> [String: String]?? in
            guard let entry = state.environments[pid],
                  entry.start == start,
                  instant.timeIntervalSince(entry.readAt) < Self.environmentLifetime
            else { return .none }
            return .some(entry.environment)
        }
        if let remembered { return remembered }

        let environment = table.environment(pid: pid)
        state.withLock { state in
            state.environmentReads += 1
            state.environments[pid] = Remembered(start: start, environment: environment, readAt: instant)
        }
        return environment
    }

    /// Drops what has expired, so a machine that has run a thousand processes
    /// does not remember a thousand environments.
    func prune() {
        let instant = now()
        state.withLock { state in
            state.environments = state.environments.filter {
                instant.timeIntervalSince($0.value.readAt) < Self.environmentLifetime
            }
        }
    }
}

/// A process table whose environments come through a ``LinkerMemo``.
///
/// Everything else is the underlying table's own answer, so its caching and
/// its indexed lookups still apply.
struct MemoizedEnvironmentTable: ProcessTableReading {
    let base: any ProcessTableReading
    let memo: LinkerMemo

    func processes() -> [ProcessRecord] { base.processes() }
    func environment(pid: pid_t) -> [String: String]? { memo.environment(pid: pid, in: base) }
    func record(pid: pid_t) -> ProcessRecord? { base.record(pid: pid) }
    func children(of pid: pid_t) -> [ProcessRecord] { base.children(of: pid) }
    func ancestors(of pid: pid_t) -> [ProcessRecord] { base.ancestors(of: pid) }
    func find(where predicate: (ProcessRecord) -> Bool) -> [ProcessRecord] {
        base.find(where: predicate)
    }
}
