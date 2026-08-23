import AgentSessionKit
import AgentSessionLive
import Foundation

/// The ledger, as one frame of the board sees it.
///
/// Read whole when the ledger changes — which is a few times a minute at
/// most, when an agent calls a tool or somebody drags a card — and then passed
/// into every assembly unchanged. The alternative is a query on the frame
/// path, which is the one place `AGENTS.md` § 4.1 will not have one.
///
/// Its indices are built once, here, rather than per frame: on a machine with
/// a thousand tasks, rebuilding two dictionaries eight times a second to
/// answer questions that have not changed is exactly the always-on cost the
/// budget exists to prevent. They are excluded from `==` because they are a
/// function of the two arrays that are not.
public struct TaskLedgerFrame: Sendable, Equatable {
    public static let empty = TaskLedgerFrame()

    public let tasks: [AuspexTask]
    public let links: [AuspexTaskLink]
    public let plans: [AuspexPlan]
    public let pendingClaims: [TaskClaimRequest]

    /// Tasks by id.
    public let taskByID: [Int64: AuspexTask]
    /// The task a session is attached to. A session can be linked to more than
    /// one; the claim wins, then the most recent link, because a session doing
    /// two things at once is a session doing the one it most recently said.
    public let taskBySession: [SessionKey: Int64]
    /// Every session attached to a task.
    public let sessionsByTask: [Int64: [SessionKey]]
    public let planByID: [Int64: AuspexPlan]
    /// The ids of the tasks that are closed, for the readiness question.
    public let closedTaskIDs: Set<Int64>
    public let knownTaskIDs: Set<Int64>
    public let pendingClaimCountByTask: [Int64: Int]
    public let latestPendingClaimAtByTask: [Int64: Date]

    public init(
        tasks: [AuspexTask] = [],
        links: [AuspexTaskLink] = [],
        plans: [AuspexPlan] = [],
        pendingClaims: [TaskClaimRequest] = []
    ) {
        self.tasks = tasks
        self.links = links
        self.plans = plans
        self.pendingClaims = pendingClaims

        var byID: [Int64: AuspexTask] = [:]
        byID.reserveCapacity(tasks.count)
        var closed: Set<Int64> = []
        for task in tasks {
            byID[task.id] = task
            if task.status == .done { closed.insert(task.id) }
        }
        self.taskByID = byID
        self.closedTaskIDs = closed
        self.knownTaskIDs = Set(byID.keys)
        self.planByID = Dictionary(plans.map { ($0.id, $0) }) { first, _ in first }
        self.pendingClaimCountByTask = Dictionary(grouping: pendingClaims, by: \.taskID)
            .mapValues(\.count)
        self.latestPendingClaimAtByTask = Dictionary(grouping: pendingClaims, by: \.taskID)
            .compactMapValues { $0.map(\.requestedAt).max() }

        var bySession: [SessionKey: Int64] = [:]
        var claimed: Set<SessionKey> = []
        var sessionsByTask: [Int64: [SessionKey]] = [:]
        for link in links {
            // A link to a task the ledger no longer holds is not a link.
            guard byID[link.taskID] != nil else { continue }
            sessionsByTask[link.taskID, default: []].append(link.session)
            if link.kind == .claim {
                bySession[link.session] = link.taskID
                claimed.insert(link.session)
            } else if !claimed.contains(link.session) {
                bySession[link.session] = link.taskID
            }
        }
        self.taskBySession = bySession
        self.sessionsByTask = sessionsByTask
    }

    /// Only the two arrays. The indices are derived from them, and comparing
    /// three dictionaries to learn what two arrays already said is work the
    /// assembler does eight times a second.
    public static func == (lhs: TaskLedgerFrame, rhs: TaskLedgerFrame) -> Bool {
        lhs.tasks == rhs.tasks && lhs.links == rhs.links && lhs.plans == rhs.plans
            && lhs.pendingClaims == rhs.pendingClaims
    }

    public var isEmpty: Bool { tasks.isEmpty && links.isEmpty }
}

/// Turns one frame's sessions into the units the wall draws.
///
/// ## The shape of the pass
///
/// One walk over the sessions to decide which unit each belongs to, one walk
/// over the units to order their members and roll their state up, and a sort.
/// O(sessions + tasks) with dictionary lookups throughout — no view ever walks
/// the delegation forest, and nothing here is quadratic in the number of
/// sessions, which is what the old per-card `descendants(of:)` was.
///
/// Pure and total. The same board and the same ledger always produce the same
/// units in the same order, which is what stops the wall reshuffling under a
/// reader's cursor at eight frames a second.
public enum TaskUnitBuilder {
    /// Derives every unit on a frame.
    ///
    /// - Parameters:
    ///   - sessions: the sessions the frame is about, in board order.
    ///   - board: the frame, for the delegation forest and the project keys.
    ///   - ledger: what has been filed.
    ///   - builder: the one row builder for this frame, so a member row and a
    ///     card drawn beside it read the same brief.
    ///   - now: the frame's own instant.
    /// - Returns: the units, most urgent first.
    public static func units(
        sessions: [SessionSnapshot],
        board: BoardSnapshot,
        ledger: TaskLedgerFrame,
        builder: BoardRowBuilder,
        now: Date
    ) -> [TaskUnit] {
        guard !sessions.isEmpty || !ledger.tasks.isEmpty else { return [] }

        let present = Set(sessions.map(\.key))

        // 1. Which unit each session belongs to. A session's own link wins; a
        //    subagent with none takes its root's, which is what folds a
        //    delegation family into the card its orchestrator claimed.
        var order: [TaskUnit.Origin] = []
        var seen: Set<TaskUnit.Origin> = []
        var membersByOrigin: [TaskUnit.Origin: [SessionSnapshot]] = [:]
        var rootByOrigin: [TaskUnit.Origin: SessionKey] = [:]

        for session in sessions {
            let root = rootKey(of: session, board: board, present: present)
            let origin: TaskUnit.Origin
            if let taskID = ledger.taskBySession[session.key] {
                origin = .task(taskID)
            } else if let taskID = ledger.taskBySession[root] {
                origin = .task(taskID)
            } else {
                origin = .implicit(root)
            }
            if seen.insert(origin).inserted {
                order.append(origin)
                rootByOrigin[origin] = root
            }
            membersByOrigin[origin, default: []].append(session)
        }

        // 2. Tasks nobody is working on are units too — a `todo` with no
        //    session is exactly the row a person files a task to create.
        for task in ledger.tasks {
            let origin = TaskUnit.Origin.task(task.id)
            guard seen.insert(origin).inserted else { continue }
            order.append(origin)
            membersByOrigin[origin] = []
        }

        var units: [TaskUnit] = []
        units.reserveCapacity(order.count)
        for origin in order {
            let members = membersByOrigin[origin] ?? []
            guard let unit = unit(
                origin: origin,
                members: members,
                root: rootByOrigin[origin],
                board: board,
                ledger: ledger,
                builder: builder,
                now: now
            ) else { continue }
            units.append(unit)
        }
        return sorted(units)
    }

    /// The top of a session's delegation chain, among the sessions on this
    /// frame.
    ///
    /// The frame's own forest rather than a walk up `identity.parent`, because
    /// the forest already answered this once for the whole board and a walk
    /// per session would make the pass quadratic on a deep tree. A root whose
    /// parent has aged off the board is its own root — which is what keeps an
    /// orphaned subagent on the wall instead of vanishing with its parent.
    static func rootKey(
        of session: SessionSnapshot,
        board: BoardSnapshot,
        present: Set<SessionKey>
    ) -> SessionKey {
        guard let root = board.tree.rootKey(for: session.key), present.contains(root) else {
            return session.key
        }
        return root
    }

    /// One unit, with its members ordered and its state rolled up.
    private static func unit(
        origin: TaskUnit.Origin,
        members sessions: [SessionSnapshot],
        root: SessionKey?,
        board: BoardSnapshot,
        ledger: TaskLedgerFrame,
        builder: BoardRowBuilder,
        now: Date
    ) -> TaskUnit? {
        let task = origin.taskID.flatMap { ledger.taskByID[$0] }
        let ordered = order(sessions, root: root, board: board)
        // The claimer leads, when it is here: it is the session a person told
        // to do this, and every other member is something it started.
        let leadKey = task?.claimedBy.flatMap { key in
            ordered.contains { $0.key == key } ? key : nil
        } ?? root
        var rows = ordered.map { builder.row(for: $0) }
        if let leadKey, let index = rows.firstIndex(where: { $0.key == leadKey }), index != 0 {
            rows.insert(rows.remove(at: index), at: 0)
        }

        guard let lead = rows.first ?? placeholderLead(for: task) else { return nil }

        // Attention is the loudest thing anybody in the family is saying, and
        // `needsYou` outranks `doneReported`: a unit with one member blocked
        // and one finished is a unit that is blocked.
        var attention = AttentionState.none
        var attentionKey: SessionKey?
        var counts = TaskUnit.Counts()
        var lastEventAt: Date?
        var endedAt: Date?
        var tokensIn = 0
        var tokensOut = 0
        for row in rows {
            if row.isEnded {
                counts.ended += 1
            } else if row.state.isActive {
                counts.working += 1
            } else {
                counts.idle += 1
            }
            tokensIn += row.tokensIn
            tokensOut += row.tokensOut
            if let at = row.lastEventAt, at > (lastEventAt ?? .distantPast) { lastEventAt = at }
            if let at = row.endedAt, at > (endedAt ?? .distantPast) { endedAt = at }
            if rank(row.attention) > rank(attention) {
                attention = row.attention
                attentionKey = row.key
            }
        }

        // Only now, so the placeholder is not counted as a session: a task
        // nobody has picked up has no members, and a card that said it had one
        // idle worker would be inventing one.
        if rows.isEmpty { rows = [lead] }

        let waitingOn = (task?.dependsOn ?? []).compactMap { id -> TaskUnit.Dependency? in
            guard let dependency = ledger.taskByID[id], dependency.status != .done else {
                return nil
            }
            return TaskUnit.Dependency(
                id: id, shortID: dependency.shortID, title: dependency.title
            )
        }

        let claim = task.flatMap { task -> TaskUnit.Claim? in
            guard task.isClaimed else { return nil }
            let key = task.claimedBy
            return TaskUnit.Claim(
                session: key ?? lead.key,
                harness: key?.harness ?? lead.harness,
                role: task.claimRole,
                scope: task.claimScope,
                claimedAt: task.claimedAt,
                freshAt: rows.first { $0.key == key }?.lastEventAt ?? lead.lastEventAt
            )
        }

        // A claim whose session has stopped without the task being finished.
        // Not a block and not a failure — a piece of debris, and the only
        // thing on the board that nothing else would ever mention.
        let isClaimOrphaned = task.map { task in
            task.status.isOpen && task.status != .review && task.isClaimed
                && (rows.first { $0.key == task.claimedBy }?.isEnded ?? (task.claimedBy != nil
                    && !rows.contains { $0.key == task.claimedBy }))
        } ?? false

        let plan = task?.planID.flatMap { ledger.planByID[$0] }
        let projectKey = task?.projectKey
            ?? rows.first.flatMap { row in board.session(for: row.key) }
                .flatMap { board.projectKey(for: $0) }

        let id: String
        let shortID: String
        let promotionKey: String
        switch origin {
        case .task(let taskID):
            id = "task:\(taskID)"
            shortID = TaskShortID.forTask(taskID)
            // Keyed on the root while there is one, so the card a person is
            // looking at survives being promoted from implicit to filed.
            promotionKey = root.map { "root:\($0.description)" } ?? id
        case .implicit(let rootKey):
            id = "implicit:\(rootKey.description)"
            shortID = TaskShortID.forImplicit(rootKey.description)
            promotionKey = "root:\(rootKey.description)"
        }

        return TaskUnit(
            id: id,
            shortID: shortID,
            origin: origin,
            version: task?.version,
            promotionKey: promotionKey,
            projectKey: projectKey,
            planID: task?.planID,
            planTitle: plan?.title,
            title: task?.title ?? lead.assignedTask ?? lead.title,
            body: task?.body,
            status: status(task: task, attention: attention, counts: counts, rows: rows),
            importance: task?.importance ?? .normal,
            kind: task?.kind,
            labels: task?.labels ?? [],
            dependsOn: task?.dependsOn ?? [],
            waitingOn: waitingOn,
            claim: claim,
            isClaimOrphaned: isClaimOrphaned,
            pendingTakeoverCount: task.map { ledger.pendingClaimCountByTask[$0.id] ?? 0 } ?? 0,
            pendingTakeoverAt: task.flatMap { ledger.latestPendingClaimAtByTask[$0.id] },
            lead: lead,
            members: rows,
            attention: attention,
            attentionKey: attentionKey,
            counts: counts,
            lastEventAt: lastEventAt ?? task?.updatedAt,
            elapsedSince: lead.elapsedSince,
            endedAt: counts.live == 0 ? endedAt : nil,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            result: task?.result,
            createdAt: task?.createdAt,
            updatedAt: task?.updatedAt
        )
    }

    /// Where a unit stands.
    ///
    /// The ledger's word when there is one, corrected by what the sessions are
    /// actually doing — because a task sitting in `doing` while its worker is
    /// blocked on a permission prompt is the board telling two stories about
    /// one thing, and the person acts on the louder one.
    ///
    /// For an implicit unit there is no ledger word, and `todo` is never the
    /// answer: nobody filed it, so it is not waiting to be started. It is
    /// whatever its sessions are doing.
    static func status(
        task: AuspexTask?,
        attention: AttentionState,
        counts: TaskUnit.Counts,
        rows: [BoardRow]
    ) -> AuspexTaskStatus {
        if let task {
            // Closed is closed. A person said so, and a session that carried on
            // afterwards does not un-close it.
            if task.status == .done { return .done }
            if attention.wantsPerson { return .blocked }
            if task.status == .review { return .review }
            if attention.isDoneReported { return .review }
            return task.status
        }
        if attention.wantsPerson { return .blocked }
        if attention.isDoneReported { return .review }
        if counts.live > 0 { return .doing }
        return rows.isEmpty ? .todo : .done
    }

    /// Attention, ranked, so a roll-up over a family is a maximum.
    private static func rank(_ attention: AttentionState) -> Int {
        switch attention {
        case .none: 0
        case .doneReported: 1
        case .needsYou: 2
        }
    }

    /// A unit's members, root first and children under whoever spawned them.
    ///
    /// Tree order rather than a flat sort, and that is the whole of what makes
    /// the member strip readable: the lead is always the first dot, and a
    /// subagent sits beside the sibling it was spawned with rather than
    /// wherever the wall's urgency sort happened to put it. Inside one level
    /// the forest keeps board order, so the busiest sibling is still the first
    /// of them.
    static func order(
        _ sessions: [SessionSnapshot],
        root: SessionKey?,
        board: BoardSnapshot
    ) -> [SessionSnapshot] {
        guard sessions.count > 1 else { return sessions }
        var bySession: [SessionKey: SessionSnapshot] = [:]
        bySession.reserveCapacity(sessions.count)
        for session in sessions { bySession[session.key] = session }

        var ordered: [SessionSnapshot] = []
        ordered.reserveCapacity(sessions.count)
        var placed: Set<SessionKey> = []
        if let root, let node = board.tree.node(for: root) {
            for member in node.flattened {
                guard let session = bySession[member.key],
                      placed.insert(member.key).inserted else { continue }
                ordered.append(session)
            }
        }
        // Anything the forest did not reach — a member linked by hand, a
        // session whose parent is not on this frame — keeps board order at the
        // end rather than being dropped.
        for session in sessions where !placed.contains(session.key) {
            ordered.append(session)
        }
        return ordered
    }

    /// The row a task with no sessions draws instead of a lead.
    ///
    /// A `todo` nobody has picked up is still a card, and a card needs the
    /// handful of fields every row has. This is that row: the task's own
    /// title, no harness accent worth speaking of, and nothing pretending to
    /// be a live session.
    private static func placeholderLead(for task: AuspexTask?) -> BoardRow? {
        guard let task else { return nil }
        return BoardRow(
            key: SessionKey(harness: task.claimedBy?.harness ?? .claudeCode, sessionID: "task-\(task.id)"),
            harness: task.claimedBy?.harness ?? .claudeCode,
            title: task.title,
            shortID: task.shortID,
            pid: nil,
            modelName: nil,
            state: .idle,
            isStale: false,
            project: task.projectKey.map(BoardGrouping.projectName(forPath:)),
            branch: nil,
            directory: nil,
            activity: task.status == .todo ? "not started" : task.status.label.lowercased(),
            turnCount: 0,
            toolCallCount: 0,
            tokensIn: 0,
            tokensOut: 0,
            elapsedSince: nil,
            endedAt: nil,
            lastEventAt: task.updatedAt,
            descendantCount: 0,
            parent: nil,
            depth: 0,
            assignedTask: task.body
        )
    }

    // MARK: - Order

    /// Board order over units: what needs a person, then what is waiting to be
    /// read, then what is running, then what is open, then what is history.
    ///
    /// The same ladder ``TaskLedger/sorted(_:)`` puts sessions in, and
    /// deliberately: the wall and the header count the same thing in the same
    /// order, and a person who clicks the third chip lands on the third card.
    /// Importance breaks a tie inside a bucket, and then the clock, and then
    /// the id — so a wall of identical cards does not reshuffle on a tick.
    public static func sorted(_ units: [TaskUnit]) -> [TaskUnit] {
        guard units.count > 1 else { return units }
        let keys = units.map(SortKey.init)
        let order = units.indices.sorted { SortKey.precedes(keys[$0], keys[$1]) }
        return order.map { units[$0] }
    }

    private struct SortKey {
        let rank: Int
        let importance: Int
        let clock: Date
        let id: String

        init(_ unit: TaskUnit) {
            self.rank = TaskLedger.rank(unit.bucket)
            self.importance = unit.importance.rank
            self.clock = unit.lastEventAt ?? unit.updatedAt ?? .distantPast
            self.id = unit.id
        }

        static func precedes(_ lhs: SortKey, _ rhs: SortKey) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.importance != rhs.importance { return lhs.importance < rhs.importance }
            if lhs.clock != rhs.clock { return lhs.clock > rhs.clock }
            return lhs.id < rhs.id
        }
    }
}
