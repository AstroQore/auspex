import AgentSessionKit
import AgentSessionLive
import Foundation

/// One piece of work, and every session doing it.
///
/// ## Why the board stopped being a wall of sessions
///
/// A session is a *process*, and a process is the wrong unit to look at. Half
/// of them are subagents — a step inside somebody else's job, spawned and
/// finished within one turn — and drawing each as a peer of the thing that
/// spawned it produces a wall where a delegation of four reads as four
/// independent pieces of work. The person scanning it has to reassemble the
/// family in their head, every time, on every frame.
///
/// A task is the unit somebody actually *assigned*. This type is that unit,
/// derived once per frame: what it is called, where it stands, who is holding
/// it, and which sessions are inside it. A subagent is never a unit of its
/// own; it is a member of one.
///
/// ## Explicit and implicit units
///
/// Every session on the board belongs to exactly one unit, whether or not
/// anybody registered anything:
///
/// - **Explicit** — the session claimed a ledger task, or a person linked it
///   to one, or it descends from a session that did. The unit is that task,
///   with its title, status, importance and history.
/// - **Implicit** — nobody filed anything. The unit is the session's *root*:
///   the top of its delegation chain, titled with what that root was asked to
///   do. Its id is `implicit:<root key>`, and it is marked `auto` on screen so
///   nobody mistakes a derivation for a record.
///
/// An implicit unit is not a lesser card. It is the ordinary case on a machine
/// where nobody has adopted the task protocol yet, and it is exactly as
/// legible as an explicit one — which is the whole reason the protocol is
/// enrichment rather than a dependency.
///
/// ## Promotion keeps the card
///
/// When an agent later files a task for a root that already has an implicit
/// unit, the card must not jump: same position, same expansion state, new
/// title. That is what ``promotionKey`` is for — the sidebar and the wall key
/// their rows on it rather than on ``id``, so a unit that gains a task id
/// keeps its place on the frame it gains it.
public struct TaskUnit: Identifiable, Sendable, Equatable {
    /// Whether this unit is a task somebody filed, or one the board derived.
    public enum Origin: Sendable, Equatable, Hashable {
        /// A row in the ledger.
        case task(Int64)
        /// A delegation family nobody filed a task for, keyed on its root.
        case implicit(SessionKey)

        /// The ledger task, when there is one.
        public var taskID: Int64? {
            if case .task(let id) = self { return id }
            return nil
        }

        /// Whether the board worked this unit out rather than being told.
        public var isImplicit: Bool {
            if case .implicit = self { return true }
            return false
        }
    }

    /// `task:<id>` or `implicit:<root key>`.
    public let id: String
    /// The handle a person reads — `AUX-3f9k`. See ``TaskShortID``.
    public let shortID: String
    public let origin: Origin

    /// What the card is keyed on across frames.
    ///
    /// The **root session's** key whenever this unit has members, and the
    /// task's id otherwise. It is deliberately *not* ``id``: an implicit unit
    /// that gets a task filed for it changes its id, and a view keyed on that
    /// would tear the card down and build a new one in its place — losing its
    /// expansion, its selection, and its position mid-scroll. Keyed on the
    /// root, the same card gains a title.
    public let promotionKey: String

    /// The project the work is in — the board's own key space.
    public let projectKey: String?
    /// The milestone it hangs under, when it has one.
    public let planID: Int64?
    /// The milestone's name, for the sub-heading.
    public let planTitle: String?

    /// What the unit is called: the task's title, or what the root session was
    /// asked to do.
    public let title: String
    /// The detail, when a task carries one.
    public let body: String?
    public let status: AuspexTaskStatus
    public let importance: TaskImportance
    public let kind: TaskKind?
    public let labels: [String]

    /// Task ids this one waits on, and their handles, for the ones that are
    /// still open.
    public let dependsOn: [Int64]
    public let waitingOn: [Dependency]
    /// Whether everything it waits on is closed.
    public var isReady: Bool { waitingOn.isEmpty }

    /// One unfinished dependency, as the card draws it.
    public struct Dependency: Sendable, Equatable, Hashable {
        public let id: Int64
        public let shortID: String
        public let title: String

        public init(id: Int64, shortID: String, title: String) {
            self.id = id
            self.shortID = shortID
            self.title = title
        }
    }

    /// Who is holding it, and how fresh that is.
    public let claim: Claim?

    /// A claim whose session ended without finishing the task.
    ///
    /// Its own marker rather than a bucket: a claim left behind by a session
    /// that died is not the same thing as work that is blocked, and folding it
    /// into `needs you` would put the loudest colour on the board's most
    /// common piece of debris. It is amber, filterable, and has a Release
    /// beside it.
    public let isClaimOrphaned: Bool

    /// The session the card is *about*: whoever claimed the task, or the root
    /// of the family.
    public let lead: BoardRow
    /// Every session in the unit, in tree order, ``lead`` first.
    public let members: [BoardRow]
    /// The members that are not the lead — what the strip counts.
    public var subagents: ArraySlice<BoardRow> { members.dropFirst() }
    /// How many sessions are folded into this card.
    public var memberCount: Int { members.count }

    /// The loudest thing any member is saying.
    public let attention: AttentionState
    /// Which member is saying it, when one is.
    public let attentionKey: SessionKey?

    public let counts: Counts
    /// The most recent event anywhere in the unit.
    public let lastEventAt: Date?
    /// What the lead's stopwatch is measured from.
    public let elapsedSince: Date?
    /// When the unit's work stopped, when all of it has.
    public let endedAt: Date?
    public let tokensIn: Int
    public let tokensOut: Int
    /// The line the worker wrote when it finished. What a reviewer reads.
    public let result: String?
    /// When it was filed, for the implicit units that have no such date.
    public let createdAt: Date?
    public let updatedAt: Date?

    /// How many members are in each activity.
    public struct Counts: Sendable, Equatable, Hashable {
        public var working: Int
        public var idle: Int
        public var ended: Int

        public init(working: Int = 0, idle: Int = 0, ended: Int = 0) {
            self.working = working
            self.idle = idle
            self.ended = ended
        }

        /// Sessions that have not finished.
        public var live: Int { working + idle }
        public var total: Int { working + idle + ended }
    }

    /// Who took the task, in what role, over what part of it, and when they
    /// were last heard from.
    ///
    /// The freshness is the member's own last event and not a heartbeat: a
    /// session Auspex is tailing announces itself by writing its transcript,
    /// and a protocol that asked agents to ping as well would be asking them
    /// to repeat something the machine already knows.
    public struct Claim: Sendable, Equatable, Hashable {
        public let session: SessionKey
        public let harness: Harness
        public let role: String?
        public let scope: String?
        public let claimedAt: Date?
        /// The claimer's last event — what "2 m ago" is measured from.
        public let freshAt: Date?

        public init(
            session: SessionKey,
            harness: Harness,
            role: String?,
            scope: String?,
            claimedAt: Date?,
            freshAt: Date?
        ) {
            self.session = session
            self.harness = harness
            self.role = role
            self.scope = scope
            self.claimedAt = claimedAt
            self.freshAt = freshAt
        }

        /// `implementer · the rollout tailer`, or whichever half exists.
        public var description: String? {
            switch (role, scope) {
            case let (role?, scope?): "\(role) · \(scope)"
            case let (role?, nil): role
            case let (nil, scope?): scope
            case (nil, nil): nil
            }
        }
    }

    public init(
        id: String,
        shortID: String,
        origin: Origin,
        promotionKey: String,
        projectKey: String?,
        planID: Int64? = nil,
        planTitle: String? = nil,
        title: String,
        body: String? = nil,
        status: AuspexTaskStatus,
        importance: TaskImportance = .normal,
        kind: TaskKind? = nil,
        labels: [String] = [],
        dependsOn: [Int64] = [],
        waitingOn: [Dependency] = [],
        claim: Claim? = nil,
        isClaimOrphaned: Bool = false,
        lead: BoardRow,
        members: [BoardRow],
        attention: AttentionState = .none,
        attentionKey: SessionKey? = nil,
        counts: Counts,
        lastEventAt: Date? = nil,
        elapsedSince: Date? = nil,
        endedAt: Date? = nil,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        result: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.shortID = shortID
        self.origin = origin
        self.promotionKey = promotionKey
        self.projectKey = projectKey
        self.planID = planID
        self.planTitle = planTitle
        self.title = title
        self.body = body
        self.status = status
        self.importance = importance
        self.kind = kind
        self.labels = labels
        self.dependsOn = dependsOn
        self.waitingOn = waitingOn
        self.claim = claim
        self.isClaimOrphaned = isClaimOrphaned
        self.lead = lead
        self.members = members
        self.attention = attention
        self.attentionKey = attentionKey
        self.counts = counts
        self.lastEventAt = lastEventAt
        self.elapsedSince = elapsedSince
        self.endedAt = endedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - What a surface asks

    /// Whether a person has something to do about this unit.
    public var needsPerson: Bool { attention.wantsPerson || status == .blocked }

    /// Whether the work is finished and waiting to be looked at.
    public var isInReview: Bool { status == .review }

    /// Whether every session in it has stopped.
    public var isEnded: Bool { counts.live == 0 }

    /// Whether the unit still has work in it as far as a person is concerned.
    public var isOpen: Bool { status.isOpen }

    /// Which bucket the header counts it in.
    ///
    /// The same five the ledger has always used, asked of a unit rather than
    /// of a session — so a delegation of four counts once, which is the whole
    /// point of the wall being a task wall.
    public var bucket: TaskLedger.Bucket {
        if needsPerson { return .needsYou }
        if isInReview { return .doneReported }
        if status == .done { return .ended }
        if counts.working > 0 { return .working }
        if counts.live > 0 { return .idle }
        return status == .todo ? .idle : .ended
    }
}

/// One section of the task wall: a project (or a harness, or everything), and
/// the units in it grouped under their milestones.
public struct TaskUnitGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let harness: Harness?
    /// How many units in it have a session still running.
    public let liveCount: Int
    /// The milestone runs, in order. A run with no title is the ordinary case
    /// — the units under no milestone — and draws no sub-heading.
    public let milestones: [Milestone]

    /// Every unit in the section, in order.
    public var units: [TaskUnit] { milestones.flatMap(\.units) }
    public var unitCount: Int { milestones.reduce(0) { $0 + $1.units.count } }

    /// One milestone's worth of units, under one sub-heading.
    public struct Milestone: Identifiable, Sendable, Equatable {
        public let id: String
        /// `nil` for the units that hang under no milestone.
        public let title: String?
        public let units: [TaskUnit]

        public init(id: String, title: String?, units: [TaskUnit]) {
            self.id = id
            self.title = title
            self.units = units
        }
    }

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        harness: Harness? = nil,
        liveCount: Int,
        milestones: [Milestone]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
        self.liveCount = liveCount
        self.milestones = milestones
    }
}
