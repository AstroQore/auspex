import AgentSessionKit
import AgentSessionLive
import Foundation

// MARK: - Scope

/// Which slice of the explicit ledger the Tasks page shows.
///
/// The four questions a person opens the page with, as chips: what is waiting
/// for my judgement, what is stuck, what is moving, and what nobody has
/// picked up. "In progress" includes what is stuck — stuck work is work in
/// progress that needs a hand — so the default view answers "what is happening
/// and what is waiting for me" without a third chip.
public enum TaskScope: String, CaseIterable, Sendable, Hashable {
    case review
    case blocked
    case inProgress
    case unclaimed
}

/// The chips that are on. Empty is "All".
public struct TaskScopeSelection: Sendable, Hashable {
    public private(set) var scopes: Set<TaskScope>

    public init(_ scopes: Set<TaskScope>) {
        self.scopes = scopes
    }

    /// Everything, done included.
    public static let all = TaskScopeSelection([])
    /// What the page opens on: the work that is moving or stuck, and the work
    /// waiting to be read. Not the whole ledger, which is mostly backlog.
    public static let `default` = TaskScopeSelection([.inProgress, .review])

    public var isAll: Bool { scopes.isEmpty }

    public func contains(_ scope: TaskScope) -> Bool { scopes.contains(scope) }

    /// Turns one chip on or off. Turning the last one off is "All".
    public mutating func toggle(_ scope: TaskScope) {
        if scopes.contains(scope) {
            scopes.remove(scope)
        } else {
            scopes.insert(scope)
        }
    }

    /// Whether a task in `kind` is on the page.
    func admits(_ kind: TaskLaneKind) -> Bool {
        guard !isAll else { return true }
        switch kind {
        case .review: return scopes.contains(.review)
        case .blocked: return scopes.contains(.blocked) || scopes.contains(.inProgress)
        case .doing, .claimedTodo: return scopes.contains(.inProgress)
        case .unclaimed: return scopes.contains(.unclaimed)
        case .done: return false
        }
    }
}

/// What one task *is*, for the purpose of which chip and which column it is
/// counted under. Read off the task's live status — see
/// ``TaskUnitBuilder/status(task:attention:counts:rows:)`` — so a `doing` whose
/// worker is waiting on a permission prompt counts as blocked.
enum TaskLaneKind: Sendable, Hashable {
    case unclaimed
    case claimedTodo
    case doing
    case blocked
    case review
    case done

    var column: AuspexTaskStatus {
        switch self {
        case .unclaimed, .claimedTodo: .todo
        case .doing: .doing
        case .blocked: .blocked
        case .review: .review
        case .done: .done
        }
    }
}

// MARK: - Rows

/// One task, as one card on the Tasks page draws it: every string already
/// formatted, every decision already made.
///
/// ## Why it is compared by revision
///
/// A card's body must not derive anything — the page used to have
/// `TaskCardView.body` as its hottest frame, re-filtering sessions and
/// re-reading notices on every frame for four hundred cards. So everything a
/// card shows is computed once here, and the ``revision`` is a hash of exactly
/// those fields. Two cards are equal when their ids and revisions are, which
/// is one integer comparison per card for SwiftUI's diff instead of a walk
/// through a `TaskUnit` and every member row it carries.
public struct TaskLaneCard: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let revision: Int
    public let shortID: String
    public let title: String
    /// Where the card is drawn: the ledger's column, corrected by what the
    /// sessions are doing.
    public let status: AuspexTaskStatus
    /// What the ledger itself says, which is what Close and Reopen act on.
    public let ledgerStatus: AuspexTaskStatus
    public let importance: TaskImportance
    public let milestone: Milestone?
    /// Who holds it, or `nil` when nobody does.
    public let claimer: Claimer?
    /// The last progress line or result, one line.
    public let detail: String?
    /// Whether ``detail`` is the worker's own account of what it finished.
    public let detailIsResult: Bool
    /// "unclaimed · filed 12d ago", or "2h ago" — formatted by the caller's
    /// ``TaskLaneText``.
    public let age: String
    public let notice: Notice?
    public let isOrphaned: Bool
    public let isOldReview: Bool
    public let isStale: Bool
    /// Sessions folded in under the claimer.
    public let subagentCount: Int
    /// The board unit this card opens — `task:<id>`.
    public var unitID: String { "task:\(id)" }
    public var isUnclaimed: Bool { claimer == nil }

    public struct Milestone: Sendable, Equatable, Hashable {
        public let id: Int64
        public let title: String
        public let isArchived: Bool
    }

    public struct Claimer: Sendable, Equatable, Hashable {
        public let session: SessionKey
        public let harness: Harness
        /// The session's title, or the claim's role when the session has left
        /// the board.
        public let title: String
        /// What the session is doing, or `nil` when it has left the board.
        public let state: SessionState?
        /// Whether the session is on the board and has not ended.
        public let isLive: Bool
    }

    public struct Notice: Sendable, Equatable, Hashable {
        public let kind: AgentNoticeKind
        public let message: String
    }

    public static func == (lhs: TaskLaneCard, rhs: TaskLaneCard) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

/// One status column inside a project's lane. Only non-empty columns exist.
public struct TaskLaneColumn: Identifiable, Sendable, Equatable {
    /// `<project key>|<status>`.
    public let id: String
    public let status: AuspexTaskStatus
    /// Every card in the column, old reviews included.
    public let total: Int
    /// What is drawn: the first ``TaskLanes/columnLimit`` cards, or every card
    /// once the column has been opened.
    public let cards: [TaskLaneCard]
    /// How many cards the "+N more" control would add.
    public let hiddenCount: Int
    public let isExpanded: Bool
    /// The Review column's folded group: reviews waiting more than two weeks
    /// with nobody live to answer for them. Empty everywhere else.
    public let oldReviews: [TaskLaneCard]
    public let showsOldReviews: Bool
    /// Every task "Close all" in the column header would close: the Review
    /// column's whole content. Empty for the other columns.
    public let closableIDs: [Int64]
    public let revision: Int

    public static func == (lhs: TaskLaneColumn, rhs: TaskLaneColumn) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

/// One project, and the work in it the current scope admits.
public struct TaskLane: Identifiable, Sendable, Equatable {
    /// `project-<key>`. Stable, so SwiftUI keeps a lane's place while the
    /// ledger churns.
    public let id: String
    public let key: String
    public let title: String
    public let subtitle: String?
    public let harness: Harness?
    /// The lane's whole load, whatever the scope: the header's numbers.
    public let counts: Counts
    public let isCollapsed: Bool
    /// The non-empty columns, in board order.
    public let columns: [TaskLaneColumn]
    /// Active milestones with open work in this lane — the lane's
    /// sub-headings, drawn as one line rather than a band each.
    public let milestones: [MilestoneSummary]
    /// How many archived milestones still have something on the page.
    public let archivedMilestoneCount: Int
    /// The milestone the lane is narrowed to, if a person picked one.
    public let milestoneFilter: Int64?
    public let revision: Int

    public struct Counts: Sendable, Equatable, Hashable {
        public var doing = 0
        public var review = 0
        public var blocked = 0
        public var unclaimed = 0
        public var done = 0
        public var open: Int { doing + review + blocked + unclaimed }
    }

    public struct MilestoneSummary: Identifiable, Sendable, Equatable, Hashable {
        public let id: Int64
        public let title: String
        public let openCount: Int
    }

    public var isEmpty: Bool { columns.isEmpty }

    public static func == (lhs: TaskLane, rhs: TaskLane) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

/// The whole page: the lanes, and the numbers over them.
public struct TaskLaneBoard: Sendable, Equatable {
    public var lanes: [TaskLane] = []
    /// What each chip says, over every explicit task whatever the scope.
    public var scopeCounts = ScopeCounts()
    /// Explicit tasks still open, stale ones not counted: the sidebar's number.
    public var openCount = 0
    /// Projects with at least one open, non-stale task.
    public var projectCount = 0
    /// Tasks set aside as stale, for the "Show stale" switch.
    public var staleCount = 0
    /// Every old review on the page, for "Close all old reviews".
    public var oldReviewIDs: [Int64] = []
    /// Whether the ledger holds anything at all.
    public var hasTasks = false

    public static let empty = TaskLaneBoard()

    public struct ScopeCounts: Sendable, Equatable, Hashable {
        public var review = 0
        public var blocked = 0
        public var inProgress = 0
        public var unclaimed = 0

        public func count(_ scope: TaskScope) -> Int {
            switch scope {
            case .review: review
            case .blocked: blocked
            case .inProgress: inProgress
            case .unclaimed: unclaimed
            }
        }
    }
}

// MARK: - Inputs

/// What the person has opened and folded on the page.
///
/// An input to the derivation rather than view state, so a click rebuilds the
/// one lane it touched — a new revision on that lane, the same revision on
/// every other — and a lane scrolled out of a lazy stack and back keeps its
/// shape.
public struct TaskLaneExpansion: Sendable, Equatable {
    public var collapsedLanes: Set<String> = []
    /// Column ids opened past ``TaskLanes/columnLimit``.
    public var expandedColumns: Set<String> = []
    /// Lane keys whose old reviews are unfolded.
    public var expandedOldReviews: Set<String> = []
    /// Lane key → the milestone that lane is narrowed to.
    public var milestoneFilter: [String: Int64] = [:]

    public init() {}
}

/// Every string a card or lane shows that is not data, so Core can build them
/// without knowing the interface language.
public struct TaskLaneText: Sendable {
    /// "12d ago", from a date and the derivation's instant.
    public var age: @Sendable (Date, Date) -> String
    /// "unclaimed · filed 12d ago", from an age.
    public var unclaimedFiled: @Sendable (String) -> String
    /// A tool target or progress line cut to one line.
    public var condense: @Sendable (String) -> String
    /// What the scratch project is called.
    public var scratch: String

    public init(
        age: @escaping @Sendable (Date, Date) -> String,
        unclaimedFiled: @escaping @Sendable (String) -> String,
        condense: @escaping @Sendable (String) -> String,
        scratch: String
    ) {
        self.age = age
        self.unclaimedFiled = unclaimedFiled
        self.condense = condense
        self.scratch = scratch
    }

    /// Plain English, for the suite and for anything without an interface.
    public static let english = TaskLaneText(
        age: { date, now in
            let seconds = max(0, now.timeIntervalSince(date))
            switch seconds {
            case ..<60: return "just now"
            case ..<3_600: return "\(Int(seconds / 60))m ago"
            case ..<86_400: return "\(Int(seconds / 3_600))h ago"
            default: return "\(Int(seconds / 86_400))d ago"
            }
        },
        unclaimedFiled: { "unclaimed · filed \($0)" },
        condense: { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 },
        scratch: "Scratch"
    )
}

// MARK: - The derivation

/// Turns the explicit ledger and the board's live units into the Tasks page.
///
/// ## The shape, and what it replaced
///
/// One lane per project. Inside it, one column per status that has anything
/// in it — not five columns under every milestone, most of them empty. A
/// milestone is a line of chips under the lane's title and a tag on each card,
/// because it is a heading, not a container. Implicit units — a session's own
/// work that nobody filed — are not here at all: they are Now's and the
/// Sessions page's, and counting them is how the header used to say 850
/// tasks on a ledger of 376.
///
/// ## Cost
///
/// O(tasks) with dictionary lookups, plus one sort per column and one over the
/// lanes. Pure: the same inputs give the same lanes with the same revisions,
/// so a rebuild that changed nothing changes nothing on screen.
public enum TaskLanes {
    /// How many cards a column draws before "+N more".
    public static let columnLimit = 8

    public static func board(
        tasks: [AuspexTask],
        plans: [AuspexPlan],
        units: [Int64: TaskUnit],
        claims: ProjectClaims,
        scope: TaskScopeSelection,
        showsArchived: Bool,
        showsStale: Bool,
        focusedProjectKey: String?,
        expansion: TaskLaneExpansion,
        text: TaskLaneText,
        now: Date
    ) -> TaskLaneBoard {
        var board = TaskLaneBoard()
        board.hasTasks = !tasks.isEmpty
        let plansByID = Dictionary(plans.map { ($0.id, $0) }) { first, _ in first }

        struct Entry {
            let card: TaskLaneCard
            let kind: TaskLaneKind
            let activity: Date
        }
        var entriesByLane: [String: [Entry]] = [:]
        var countsByLane: [String: TaskLane.Counts] = [:]
        var latestByLane: [String: Date] = [:]
        var openProjects: Set<String> = []
        var oldReviewIDs: [Int64] = []
        // Lane key → active milestone → open tasks in it, for the lane's
        // milestone line. Gathered here so the lane does not walk the ledger.
        var openByPlanByLane: [String: [Int64: Int]] = [:]

        for task in tasks {
            let key = projectKey(of: task, claims: claims)
            // A window bound to one project counts that project: the bar's
            // numbers describe the lanes under it.
            if let focus = focusedProjectKey, key != focus { continue }
            let unit = units[task.id]
            if task.isStale {
                board.staleCount += 1
                guard showsStale else { continue }
            }
            let plan = task.planID.flatMap { plansByID[$0] }
            let isArchivedPlan = plan?.status == .archived
            let status = unit?.status ?? task.status
            let kind = kind(of: task, status: status)
            // An archived milestone hides what is finished under it, never what
            // is still open: a review under a filed-away heading still needs
            // reading.
            if isArchivedPlan, !showsArchived, kind == .done || task.isStale { continue }

            var counts = countsByLane[key] ?? TaskLane.Counts()
            if !task.isStale {
                switch kind {
                case .unclaimed: counts.unclaimed += 1; board.scopeCounts.unclaimed += 1
                case .claimedTodo, .doing: counts.doing += 1; board.scopeCounts.inProgress += 1
                case .blocked:
                    counts.blocked += 1
                    board.scopeCounts.blocked += 1
                    board.scopeCounts.inProgress += 1
                case .review: counts.review += 1; board.scopeCounts.review += 1
                case .done: counts.done += 1
                }
                if kind != .done {
                    board.openCount += 1
                    openProjects.insert(key)
                    if let plan, !isArchivedPlan {
                        openByPlanByLane[key, default: [:]][plan.id, default: 0] += 1
                    }
                }
            }
            countsByLane[key] = counts

            let card = card(for: task, unit: unit, plan: plan, status: status, text: text, now: now)
            if card.isOldReview { oldReviewIDs.append(task.id) }
            let activity = unit?.lastEventAt ?? task.updatedAt
            if activity > (latestByLane[key] ?? .distantPast) { latestByLane[key] = activity }

            // The stale switch shows stale work whatever the chips say: it is
            // the one way to see it at all.
            guard scope.admits(kind) || task.isStale else { continue }
            if let filter = expansion.milestoneFilter[key], task.planID != filter { continue }
            entriesByLane[key, default: []].append(Entry(card: card, kind: kind, activity: activity))
        }
        board.projectCount = openProjects.count
        board.oldReviewIDs = oldReviewIDs

        var keys = Array(entriesByLane.keys)
        if let focus = focusedProjectKey {
            keys = [focus]
        }
        func rank(_ key: String) -> Int {
            let counts = countsByLane[key] ?? TaskLane.Counts()
            if counts.blocked > 0 { return 0 }
            if counts.review > 0 { return 1 }
            if counts.doing > 0 { return 2 }
            return 3
        }
        let ranked = keys.sorted { lhs, rhs in
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            let leftAt = latestByLane[lhs] ?? .distantPast
            let rightAt = latestByLane[rhs] ?? .distantPast
            if leftAt != rightAt { return leftAt > rightAt }
            return lhs < rhs
        }
        board.lanes = claims.pinnedFirst(ranked) { $0 }.map { key in
            lane(
                key: key,
                entries: (entriesByLane[key] ?? []).map { ($0.card, $0.kind, $0.activity) },
                counts: countsByLane[key] ?? TaskLane.Counts(),
                openByPlan: openByPlanByLane[key] ?? [:],
                plansByID: plansByID,
                claims: claims,
                expansion: expansion,
                text: text
            )
        }
        return board
    }

    // MARK: Pieces

    static func kind(of task: AuspexTask, status: AuspexTaskStatus) -> TaskLaneKind {
        switch status {
        case .todo: task.isClaimed ? .claimedTodo : .unclaimed
        case .doing: .doing
        case .blocked: .blocked
        case .review: .review
        case .done: .done
        }
    }

    /// The project a task is drawn in: its stored key folded through the
    /// person's claims, so a project made today collects what was filed in
    /// its folders yesterday.
    public static func projectKey(of task: AuspexTask, claims: ProjectClaims) -> String {
        guard let key = task.projectKey, !key.isEmpty else { return TaskProject.scratchKey }
        return claims.key(forPath: key) ?? key
    }

    static func card(
        for task: AuspexTask,
        unit: TaskUnit?,
        plan: AuspexPlan?,
        status: AuspexTaskStatus,
        text: TaskLaneText,
        now: Date
    ) -> TaskLaneCard {
        // The claimer's own row, when it is on the board. A unit with no
        // sessions carries a placeholder lead that is not a session at all.
        let row: BoardRow? = unit.flatMap { unit in
            guard unit.hasSessions, let holder = task.claimedBy else { return nil }
            return unit.members.first { $0.key == holder }
        }
        let claimer: TaskLaneCard.Claimer? = task.claimedBy.map { holder in
            if let row {
                return TaskLaneCard.Claimer(
                    session: row.key, harness: row.harness, title: row.title,
                    state: row.state, isLive: !row.isEnded
                )
            }
            return TaskLaneCard.Claimer(
                session: holder, harness: holder.harness,
                title: task.claimDescription ?? String(holder.sessionID.prefix(8)),
                state: nil, isLive: false
            )
        }
        let isOldReview = LedgerHygiene.isOldReview(
            task, claimerIsLive: claimer?.isLive ?? false, now: now
        )

        let finished = status == .review || status == .done
        let detail: String?
        if finished {
            detail = task.result.map(text.condense)
        } else if let row {
            let line = row.reportedFocus ?? row.activity
            detail = line.isEmpty ? nil : text.condense(line)
        } else {
            detail = nil
        }

        let age: String
        if claimer == nil, status == .todo {
            age = text.unclaimedFiled(text.age(task.createdAt, now))
        } else if finished {
            age = text.age(task.completedAt ?? task.updatedAt, now)
        } else {
            age = text.age(row?.lastEventAt ?? task.updatedAt, now)
        }

        let notice: TaskLaneCard.Notice? = unit.flatMap { unit in
            unit.members.lazy.compactMap(\.notice).first { $0.kind.wantsPerson }
                .map { TaskLaneCard.Notice(kind: $0.kind, message: $0.message) }
        }
        let milestone = plan.map {
            TaskLaneCard.Milestone(id: $0.id, title: $0.title, isArchived: $0.status == .archived)
        }
        let isOrphaned = unit?.isClaimOrphaned ?? false
        let subagents = unit.map { $0.hasSessions ? max(0, $0.memberCount - 1) : 0 } ?? 0

        var hasher = Hasher()
        hasher.combine(task.id)
        hasher.combine(task.version)
        hasher.combine(task.title)
        hasher.combine(status)
        hasher.combine(task.status)
        hasher.combine(task.priority)
        hasher.combine(milestone)
        hasher.combine(claimer)
        hasher.combine(detail)
        hasher.combine(age)
        hasher.combine(notice)
        hasher.combine(isOrphaned)
        hasher.combine(isOldReview)
        hasher.combine(task.isStale)
        hasher.combine(subagents)

        return TaskLaneCard(
            id: task.id,
            revision: hasher.finalize(),
            shortID: task.shortID,
            title: task.title,
            status: status,
            ledgerStatus: task.status,
            importance: task.importance,
            milestone: milestone,
            claimer: claimer,
            detail: detail,
            detailIsResult: finished && detail != nil,
            age: age,
            notice: notice,
            isOrphaned: isOrphaned,
            isOldReview: isOldReview,
            isStale: task.isStale,
            subagentCount: subagents
        )
    }

    private static func lane(
        key: String,
        entries: [(card: TaskLaneCard, kind: TaskLaneKind, activity: Date)],
        counts: TaskLane.Counts,
        openByPlan: [Int64: Int],
        plansByID: [Int64: AuspexPlan],
        claims: ProjectClaims,
        expansion: TaskLaneExpansion,
        text: TaskLaneText
    ) -> TaskLane {
        let isCollapsed = expansion.collapsedLanes.contains(key)
        var byColumn: [AuspexTaskStatus: [(card: TaskLaneCard, activity: Date)]] = [:]
        for entry in entries {
            byColumn[entry.kind.column, default: []].append((entry.card, entry.activity))
        }

        var columns: [TaskLaneColumn] = []
        for status in AuspexTaskStatus.allCases {
            guard let rows = byColumn[status], !rows.isEmpty else { continue }
            let sorted = rows.sorted { lhs, rhs in
                Self.precedes(lhs, rhs, in: status)
            }.map(\.card)
            let recent = sorted.filter { !$0.isOldReview }
            let old = sorted.filter(\.isOldReview)
            let id = "\(key)|\(status.rawValue)"
            let isExpanded = expansion.expandedColumns.contains(id)
            let drawn = isExpanded ? recent : Array(recent.prefix(columnLimit))
            let showsOld = expansion.expandedOldReviews.contains(key)
            let closable = status == .review
                ? sorted.filter { $0.ledgerStatus == .review }.map(\.id)
                : []
            var hasher = Hasher()
            hasher.combine(id)
            hasher.combine(sorted.count)
            for card in drawn { hasher.combine(card.id); hasher.combine(card.revision) }
            hasher.combine(old.count)
            if showsOld { for card in old { hasher.combine(card.id); hasher.combine(card.revision) } }
            hasher.combine(isExpanded)
            hasher.combine(showsOld)
            hasher.combine(closable)
            columns.append(TaskLaneColumn(
                id: id,
                status: status,
                total: sorted.count,
                cards: drawn,
                hiddenCount: recent.count - drawn.count,
                isExpanded: isExpanded,
                oldReviews: old,
                showsOldReviews: showsOld,
                closableIDs: closable,
                revision: hasher.finalize()
            ))
        }

        // The lane's milestone line: active milestones with open work here, in
        // the order they were last touched, and a count of the archived ones
        // that still have something on the page.
        let archivedOnPage = Set(entries.compactMap { entry in
            entry.card.milestone.flatMap { $0.isArchived ? $0.id : nil }
        })
        let milestones = openByPlan.compactMap { id, open -> (TaskLane.MilestoneSummary, Date)? in
            guard let plan = plansByID[id] else { return nil }
            return (TaskLane.MilestoneSummary(id: id, title: plan.title, openCount: open), plan.updatedAt)
        }
        .sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.id < rhs.0.id
        }
        .map(\.0)

        let title = TaskProject.isScratch(key)
            ? text.scratch
            : claims.name(forKey: key) ?? BoardGrouping.projectName(forPath: key)
        let filter = expansion.milestoneFilter[key]

        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(title)
        hasher.combine(counts)
        hasher.combine(isCollapsed)
        for column in columns { hasher.combine(column.id); hasher.combine(column.revision) }
        hasher.combine(milestones)
        hasher.combine(archivedOnPage.count)
        hasher.combine(filter)

        return TaskLane(
            id: "project-\(key)",
            key: key,
            title: title,
            subtitle: TaskProject.subtitle(forKey: key),
            harness: PseudoProject.harness(forKey: key),
            counts: counts,
            isCollapsed: isCollapsed,
            columns: columns,
            milestones: milestones,
            archivedMilestoneCount: archivedOnPage.count,
            milestoneFilter: filter,
            revision: hasher.finalize()
        )
    }

    /// Card order inside a column. What is calling for a person first, then
    /// what matters most; then, in Review, the longest-waiting first — a
    /// review queue is first in, first out — and everywhere else the most
    /// recently active first.
    private static func precedes(
        _ lhs: (card: TaskLaneCard, activity: Date),
        _ rhs: (card: TaskLaneCard, activity: Date),
        in status: AuspexTaskStatus
    ) -> Bool {
        let leftCalls = lhs.card.notice != nil
        let rightCalls = rhs.card.notice != nil
        if leftCalls != rightCalls { return leftCalls }
        if lhs.card.importance.rank != rhs.card.importance.rank {
            return lhs.card.importance.rank < rhs.card.importance.rank
        }
        if lhs.activity != rhs.activity {
            return status == .review ? lhs.activity < rhs.activity : lhs.activity > rhs.activity
        }
        return lhs.card.id < rhs.card.id
    }
}
