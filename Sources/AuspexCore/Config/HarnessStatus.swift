import AgentSessionKit
import AgentSessionLive
import Foundation

/// One row of the Harnesses page: what this machine has installed, what it is
/// running, and what it has been told about MCP.
///
/// Three facts of very different provenance, deliberately kept apart. Whether
/// a harness is *installed* is a `stat` of a directory. What it is *running*
/// comes from the live board. What it is *configured with* comes from that
/// harness's own config file. A page that blurred them would let "no sessions
/// on the board" read as "not installed", which is the single most misleading
/// thing this page could say.
public struct HarnessStatus: Identifiable, Sendable, Equatable {
    /// The harness this row is about.
    public let harness: Harness
    /// The store Auspex watches for it, for display. The first of the
    /// adapter's own watch roots, so the page cannot claim to watch something
    /// no adapter opens.
    public let storePath: String?
    /// `true` when at least one of those roots exists on this Mac.
    public let isDetected: Bool
    /// Believed to be running: alive and not ended.
    public let liveCount: Int
    /// On the board and not running.
    public let idleCount: Int
    /// Every session on the board from this harness.
    public let totalCount: Int
    /// The most recent event across them, when there has been one.
    public let lastEventAt: Date?
    /// What its config file says about MCP, when it has one.
    public let mcp: HarnessMCPConfig?
    /// The plan window this harness last said it was billing against, from the
    /// freshest session that recorded one.
    ///
    /// `nil` for every harness but Codex, which is the only store on this Mac
    /// that writes a rate limit down. Read off a rollout like everything else
    /// on this page — Auspex asks no vendor's API what anybody's quota is.
    public let quota: QuotaLine?

    /// What this harness has been doing on the task board.
    ///
    /// Not the same question as the counts above it, and worth the three
    /// numbers. Those say *how many of its sessions are open*, which on a
    /// machine that has run agents all week is mostly history; this says *how
    /// much work it is holding, how much it has finished, and how long that
    /// takes it* — which is the question somebody asks when they are choosing
    /// which harness to hand the next job to.
    public let work: Work

    /// One harness's share of the work.
    public struct Work: Sendable, Equatable, Hashable {
        /// Tasks it currently holds a claim on and has not finished.
        public let claimed: Int
        /// Tasks it finished — in review or closed.
        public let closed: Int
        /// The median time from claim to finish, over the ones it finished.
        ///
        /// A median and not a mean, because a single task somebody left
        /// claimed over a weekend would otherwise be the whole number. `nil`
        /// until it has finished one.
        public let medianSeconds: TimeInterval?

        public static let none = Work(claimed: 0, closed: 0, medianSeconds: nil)

        public init(claimed: Int, closed: Int, medianSeconds: TimeInterval?) {
            self.claimed = claimed
            self.closed = closed
            self.medianSeconds = medianSeconds
        }

        /// Whether there is anything worth drawing.
        public var isEmpty: Bool { claimed == 0 && closed == 0 }
    }

    /// What each harness has been doing on the task board, from the units the
    /// wall just derived.
    ///
    /// One pass over the units rather than a query per harness: the caller
    /// already holds them, and this page is redrawn whenever the board is.
    public static func work(from units: [TaskUnit]) -> [Harness: Work] {
        var claimed: [Harness: Int] = [:]
        var closed: [Harness: Int] = [:]
        var durations: [Harness: [TimeInterval]] = [:]
        for unit in units {
            guard let claim = unit.claim else { continue }
            let harness = claim.harness
            if unit.status == .review || unit.status == .done {
                closed[harness, default: 0] += 1
                // Claim to finish. Both stamps come off the ledger, so a unit
                // the board derived — which has neither — contributes nothing,
                // which is right: nobody claimed it and nobody closed it.
                if let from = claim.claimedAt, let to = unit.updatedAt, to > from {
                    durations[harness, default: []].append(to.timeIntervalSince(from))
                }
            } else if unit.status.isOpen {
                claimed[harness, default: 0] += 1
            }
        }
        var out: [Harness: Work] = [:]
        for harness in Set(claimed.keys).union(closed.keys) {
            let times = (durations[harness] ?? []).sorted()
            out[harness] = Work(
                claimed: claimed[harness] ?? 0,
                closed: closed[harness] ?? 0,
                medianSeconds: times.isEmpty ? nil : times[times.count / 2]
            )
        }
        return out
    }

    public var id: Harness { harness }

    public init(
        harness: Harness,
        storePath: String?,
        isDetected: Bool,
        liveCount: Int,
        idleCount: Int,
        totalCount: Int,
        lastEventAt: Date?,
        mcp: HarnessMCPConfig?,
        quota: QuotaLine? = nil,
        work: Work = .none
    ) {
        self.work = work
        self.harness = harness
        self.storePath = storePath
        self.isDetected = isDetected
        self.liveCount = liveCount
        self.idleCount = idleCount
        self.totalCount = totalCount
        self.lastEventAt = lastEventAt
        self.mcp = mcp
        self.quota = quota
    }

    /// Builds the rows for a page.
    ///
    /// The three inputs stay separate all the way in, because they are read on
    /// three different schedules — the board arrives at up to 20 Hz, detection
    /// and configuration are re-read on a timer — and joining them here is the
    /// one place that has all three.
    ///
    /// - Parameters:
    ///   - harnesses: which rows to build, in display order.
    ///   - board: the live frame the counts come from.
    ///   - storePaths: the store to name per harness, from its adapter's own
    ///     watch roots. Passed in rather than duplicated here, where it could
    ///     drift from what the tailer opens.
    ///   - detected: the harnesses whose store exists on this Mac.
    ///   - configs: what each harness's config file says about MCP.
    public static func rows(
        harnesses: [Harness],
        board: BoardSnapshot,
        storePaths: [Harness: String] = [:],
        detected: Set<Harness> = [],
        configs: [Harness: HarnessMCPConfig] = [:],
        units: [TaskUnit] = []
    ) -> [HarnessStatus] {
        let work = work(from: units)
        let byHarness = board.byHarness
        return harnesses.map { harness in
            let sessions = byHarness[harness] ?? []
            let live = sessions.count { $0.isAlive && !$0.state.isEnded }
            return HarnessStatus(
                harness: harness,
                storePath: storePaths[harness],
                isDetected: detected.contains(harness),
                liveCount: live,
                idleCount: sessions.count - live,
                totalCount: sessions.count,
                lastEventAt: sessions.compactMap(\.lastEventAt).max(),
                mcp: configs[harness],
                // The freshest claim, not the newest session's: a limit is an
                // account-wide fact, and the session that wrote it down most
                // recently is the one that knows the most about it.
                quota: QuotaLine(
                    sessions.compactMap(\.quota).max { $0.at < $1.at }
                ),
                work: work[harness] ?? .none
            )
        }
    }
}
