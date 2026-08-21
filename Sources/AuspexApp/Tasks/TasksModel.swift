import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// The Tasks page's state: the projects, the tasks inside them, and which live
/// sessions are attached to each.
///
/// ## One hierarchy
///
/// **Project ⊃ task ⊃ sessions.** A lane is a project — the same project the
/// wall groups cards into and the sidebar lists — and a milestone is a
/// sub-heading *inside* a lane rather than a lane of its own. There is no
/// "Unfiled": a task filed by an agent is filed in the project that agent is
/// working in, resolved before it ever reaches the store.
///
/// Read on demand rather than observed. The ledger changes when a person drags
/// a card or an agent calls a tool — a few times a minute at most — so a
/// `ValueObservation` over four tables would spend a connection to save a query
/// nobody is waiting on. ``reload()`` is called from both of those places and
/// from the page appearing.
///
/// The *live* half of a row — what the attached session is doing right now —
/// does not come from here at all. It comes from the board frame, through
/// ``apply(board:notices:attention:)``, which is what keeps the state dot on a
/// task row and the state pill on its card from ever disagreeing.
@MainActor
@Observable
final class TasksModel {
    /// One lane per project, in board order: the projects being worked in
    /// first.
    private(set) var lanes: [ProjectLane] = []

    /// Whether anything has ever been filed. Distinguishes "nobody has used
    /// this yet" from "everything is finished", which want different pages.
    private(set) var isEmpty = true

    /// Tasks not yet in the `done` column — the number beside the sidebar row.
    ///
    /// An `Int` rather than a derivation over ``lanes``, because the sidebar is
    /// on screen always and reading the lanes would invalidate it every time
    /// any task moved.
    private(set) var openCount = 0

    /// How much work each project is carrying, by the board's project key.
    ///
    /// Derived here rather than queried, because the folding that puts a task
    /// into a person's project (see ``rebuild()``) happens here and a `GROUP BY`
    /// in SQLite would not know about it.
    ///
    /// TODO: the sidebar's project rows should draw `taskCounts(byProjectKey:)`
    /// as a quiet pill beside the live count — `ProjectsSidebar.swift` belongs
    /// to another branch, so this is left as the seam rather than the edit.
    private(set) var projectTaskCounts: [String: TaskProjectCounts] = [:]

    /// What one project is carrying. Zero for a project nobody has filed
    /// anything in, so a caller can draw a pill without unwrapping.
    func taskCounts(byProjectKey key: String) -> TaskProjectCounts {
        projectTaskCounts[key] ?? TaskProjectCounts(total: 0, open: 0)
    }

    /// Whether archived milestones are drawn as well.
    var showsArchived = false {
        didSet { if oldValue != showsArchived { reload() } }
    }

    /// The task a person is dragging, so a column can say it will take it.
    var draggingTaskID: Int64?

    /// The row the detail strip is about.
    var selectedTaskID: Int64?

    private var repository: TaskRepository?
    private var live: [SessionKey: LiveSessionState] = [:]
    /// The user's projects, as the frame carries them.
    ///
    /// Kept so a lane can be titled and a task can be folded into the project a
    /// person made *after* it was filed. Compared before it is stored: claims
    /// change when somebody edits the Projects page, which is not eight times a
    /// second.
    private var claims: ProjectClaims = .empty
    /// The sessions any task is attached to.
    ///
    /// The whole reason ``apply(board:notices:attention:)`` is affordable. It is
    /// called from the frame hook, which runs eight times a second whether or
    /// not this page is on screen, and deriving a title and a project for every
    /// session on a six-hundred-session board at that rate is exactly the kind
    /// of always-on cost `AGENTS.md` § 4.1 exists to prevent. A task board with
    /// nothing linked to it does no work at all.
    private var linkedKeys: Set<SessionKey> = []
    private var reloadTask: Task<Void, Never>?

    /// What a task row knows about a session attached to it.
    struct LiveSessionState: Sendable, Equatable {
        let key: SessionKey
        let harness: Harness
        let title: String
        let state: SessionState
        let isAlive: Bool
        let notice: AgentNotice?
        /// What the board says this session is signalling. Passed in rather
        /// than re-derived, so a task row and the card behind it cannot
        /// disagree about whether its worker is stuck.
        let attention: AttentionState
    }

    /// One project and all the work in it.
    struct ProjectLane: Identifiable, Equatable {
        /// `project-<key>`. Stable across reloads so SwiftUI keeps the lane's
        /// state while the board churns.
        let id: String
        /// The board's project key — a path, a `PseudoProject` key, or the
        /// scratch project.
        let key: String
        let title: String
        /// The path under the title, when the key is one.
        let subtitle: String?
        /// The harness a pseudo project stands for, so a lane can wear its
        /// mark instead of a folder icon.
        let harness: Harness?
        /// The milestones inside it, and the tasks that are in none.
        let groups: [MilestoneGroup]

        var tasks: [TaskRow] { groups.flatMap(\.tasks) }
        var openCount: Int { groups.reduce(0) { $0 + $1.openCount } }
        var isEmpty: Bool { groups.allSatisfy(\.tasks.isEmpty) }
    }

    /// One milestone inside a project, or the tasks that are in none.
    struct MilestoneGroup: Identifiable, Equatable {
        /// `plan-<id>`, or `<project key>-loose`.
        let id: String
        let plan: AuspexPlan?
        /// `nil` for the tasks that are in no milestone: they are the ordinary
        /// case and a heading over them would be a heading saying "the rest".
        var title: String? { plan?.title }
        var summary: String? { plan?.summary }
        let tasks: [TaskRow]

        var isArchived: Bool { plan?.status == .archived }

        /// The tasks in one column, in board order.
        ///
        /// By what the task is *doing* rather than by what somebody last
        /// dragged it to — see ``TaskRow/displayStatus``.
        func column(_ status: AuspexTaskStatus) -> [TaskRow] {
            tasks.filter { $0.displayStatus == status }
        }

        var openCount: Int { tasks.count { $0.task.status != .done } }
    }

    /// One task, with the sessions on it.
    struct TaskRow: Identifiable, Equatable {
        var id: Int64 { task.id }
        let task: AuspexTask
        let sessions: [LiveSessionState]

        /// The loudest thing any attached session is saying, which is what the
        /// row's dot shows: a task whose worker is blocked is a blocked task,
        /// whatever column somebody last dragged it into.
        var liveState: SessionState? {
            sessions.first { if case .waitingPermission = $0.state { true } else { false } }?.state
                ?? sessions.first { $0.isAlive && !$0.state.isEnded }?.state
                ?? sessions.first?.state
        }

        /// A session on this task that is calling for a person.
        var callingNotice: AgentNotice? {
            sessions.compactMap(\.notice).first { $0.kind.wantsPerson }
        }

        /// Whether a worker on this task is asking for a person.
        var wantsPerson: Bool { sessions.contains { $0.attention.wantsPerson } }

        /// Which column this row is drawn in.
        ///
        /// A task whose worker is stuck is a blocked task, whatever column it
        /// was last dragged into. The column and the card have to agree,
        /// because the board is read to find out where the work is — and a
        /// task sitting in `Doing` with a red card on it is the board telling
        /// two different stories about one thing.
        ///
        /// A finished task stays in `Done` rather than leaving the board:
        /// something a person still has to read is exactly what this app
        /// exists to surface, and `done` is a column rather than a closure.
        var displayStatus: AuspexTaskStatus {
            guard task.status != .done, wantsPerson else { return task.status }
            return .blocked
        }
    }

    /// Starts reading from `repository`, and does the first read.
    func start(repository: TaskRepository) {
        self.repository = repository
        reload()
    }

    /// Re-reads the ledger. Coalesced: a burst of tool calls is one read.
    func reload() {
        guard let repository else { return }
        let showsArchived = showsArchived
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) { () -> LedgerSnapshot in
                LedgerSnapshot(
                    plans: (try? repository.plans(includingArchived: showsArchived)) ?? [],
                    tasks: (try? repository.tasks(limit: 1_000)) ?? [],
                    links: (try? repository.allLinks()) ?? []
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(snapshot)
        }
    }

    /// Hands the page the frame the board is drawing, so a task row's dot is
    /// the same fact as its card's pill — and so a lane is named the way the
    /// wall names the same project.
    func apply(
        board: BoardSnapshot,
        notices: [SessionKey: AgentNotice],
        attention: [SessionKey: AttentionState] = [:]
    ) {
        var changed = false
        if board.claims != claims {
            claims = board.claims
            changed = true
        }
        guard !linkedKeys.isEmpty else {
            if !live.isEmpty { live = [:]; changed = true }
            if changed { rebuild() }
            return
        }
        var next: [SessionKey: LiveSessionState] = [:]
        next.reserveCapacity(linkedKeys.count)
        for session in board.sessions where linkedKeys.contains(session.key) {
            next[session.key] = LiveSessionState(
                key: session.key,
                harness: session.key.harness,
                title: BoardRowBuilder.title(
                    for: session,
                    project: board.projectKey(for: session).map(BoardGrouping.projectName(forPath:))
                ),
                state: session.state,
                isAlive: session.isAlive,
                notice: notices[session.key],
                attention: attention[session.key] ?? .none
            )
        }
        guard next != live || changed else { return }
        live = next
        rebuild()
    }

    // MARK: - Building

    private struct LedgerSnapshot: Sendable {
        let plans: [AuspexPlan]
        let tasks: [AuspexTask]
        let links: [AuspexTaskLink]
    }

    private var latest: LedgerSnapshot?

    private func apply(_ snapshot: LedgerSnapshot) {
        latest = snapshot
        rebuild()
    }

    /// Turns the ledger into lanes: one per project, milestones inside.
    ///
    /// A task's stored key is folded through the user's claims first, so a
    /// project somebody makes today collects the tasks that were filed in its
    /// folders yesterday — the same fold ``BoardSnapshot/projectKey(for:)``
    /// applies to a session, applied to a row that was written before the
    /// claim existed.
    private func rebuild() {
        guard let latest else { return }
        isEmpty = latest.plans.isEmpty && latest.tasks.isEmpty
        openCount = latest.tasks.count { $0.status != .done }

        let linksByTask = Dictionary(grouping: latest.links) { $0.taskID }
        linkedKeys = Set(latest.links.map(\.session))
        func row(_ task: AuspexTask) -> TaskRow {
            TaskRow(task: task, sessions: (linksByTask[task.id] ?? []).compactMap { live[$0.session] })
        }

        let plansByID = Dictionary(latest.plans.map { ($0.id, $0) }) { first, _ in first }
        var order: [String] = []
        var tasksByProject: [String: [AuspexTask]] = [:]
        var counts: [String: TaskProjectCounts] = [:]
        for task in latest.tasks {
            // A milestone the reader has hidden hides its tasks with it: the
            // switch says "show archived", and a task that stayed behind would
            // be a row under a heading that is not on the page.
            if let planID = task.planID, plansByID[planID] == nil { continue }
            let key = project(of: task)
            if tasksByProject[key] == nil {
                tasksByProject[key] = []
                order.append(key)
            }
            tasksByProject[key]?.append(task)
            let existing = counts[key] ?? TaskProjectCounts(total: 0, open: 0)
            counts[key] = TaskProjectCounts(
                total: existing.total + 1,
                open: existing.open + (task.status == .done ? 0 : 1)
            )
        }
        projectTaskCounts = counts

        // Lanes in the order a person asks about them — what is stuck, then
        // what is moving, then what is finished — and inside each, whatever was
        // touched most recently. The same argument the wall's sections make:
        // alphabetical order would bury a blocked project under `zzz-scratch`.
        let ranked = order.sorted { lhs, rhs in
            let left = rank(of: tasksByProject[lhs] ?? [])
            let right = rank(of: tasksByProject[rhs] ?? [])
            if left != right { return left < right }
            let leftAt = tasksByProject[lhs]?.map(\.updatedAt).max() ?? .distantPast
            let rightAt = tasksByProject[rhs]?.map(\.updatedAt).max() ?? .distantPast
            if leftAt != rightAt { return leftAt > rightAt }
            return lhs < rhs
        }
        lanes = claims.pinnedFirst(ranked) { $0 }.map { key in
            lane(key: key, tasks: tasksByProject[key] ?? [], plans: plansByID, row: row)
        }
    }

    /// Where a project sits in lane order: blocked work first, then open work,
    /// then a project whose tasks are all finished.
    private func rank(of tasks: [AuspexTask]) -> Int {
        if tasks.contains(where: { $0.status == .blocked }) { return 0 }
        if tasks.contains(where: { $0.status != .done }) { return 1 }
        return 2
    }

    /// The project a stored task is drawn in.
    private func project(of task: AuspexTask) -> String {
        guard let key = task.projectKey, !key.isEmpty else { return TaskProject.scratchKey }
        return claims.key(forPath: key) ?? key
    }

    /// One lane: the milestones inside a project, then everything in none.
    ///
    /// Milestones in the order the ledger touched them, and the loose tasks
    /// last — they are the ordinary case, and a reader scanning for a heading
    /// should find the headings together.
    private func lane(
        key: String,
        tasks: [AuspexTask],
        plans: [Int64: AuspexPlan],
        row: (AuspexTask) -> TaskRow
    ) -> ProjectLane {
        var groups: [MilestoneGroup] = []
        var loose: [AuspexTask] = []
        var byPlan: [Int64: [AuspexTask]] = [:]
        var planOrder: [Int64] = []
        for task in tasks {
            guard let planID = task.planID, plans[planID] != nil else {
                loose.append(task)
                continue
            }
            if byPlan[planID] == nil { planOrder.append(planID) }
            byPlan[planID, default: []].append(task)
        }
        for planID in planOrder {
            guard let plan = plans[planID] else { continue }
            groups.append(
                MilestoneGroup(
                    id: "plan-\(plan.id)",
                    plan: plan,
                    tasks: (byPlan[planID] ?? []).map(row)
                )
            )
        }
        if !loose.isEmpty || groups.isEmpty {
            groups.append(
                MilestoneGroup(id: "\(key)-loose", plan: nil, tasks: loose.map(row))
            )
        }
        return ProjectLane(
            id: "project-\(key)",
            key: key,
            title: name(forKey: key),
            subtitle: TaskProject.subtitle(forKey: key),
            harness: PseudoProject.harness(forKey: key),
            groups: groups
        )
    }

    /// What a lane is called: the name a person gave the project, the harness a
    /// pseudo key stands for, "Scratch", or the key's last path component.
    ///
    /// The same ladder ``BoardSnapshot/projectDisplayName(forKey:)`` climbs,
    /// asked of the claims alone — a lane must not need a whole frame to know
    /// its own title, because the frame arrives eight times a second and the
    /// title changes about once a month.
    private func name(forKey key: String) -> String {
        if TaskProject.isScratch(key) { return TaskProject.scratchName }
        return claims.name(forKey: key) ?? BoardGrouping.projectName(forPath: key)
    }

    /// An empty lane for a project a person is looking *at* — the Tasks page
    /// hides projects with nothing in them, except the one they focused.
    func emptyLane(forKey key: String) -> ProjectLane {
        ProjectLane(
            id: "project-\(key)",
            key: key,
            title: name(forKey: key),
            subtitle: TaskProject.subtitle(forKey: key),
            harness: PseudoProject.harness(forKey: key),
            groups: [MilestoneGroup(id: "\(key)-loose", plan: nil, tasks: [])]
        )
    }

    // MARK: - Editing

    /// Moves a task between columns. Written straight through: the drag is the
    /// person's decision and the board should show it on the same frame.
    func move(taskID: Int64, to status: AuspexTaskStatus) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.updateTask(id: taskID, status: status)
        }
        optimistically { task in
            guard task.id == taskID else { return task }
            return AuspexTask(
                id: task.id, planID: task.planID, title: task.title, body: task.body,
                status: status, priority: task.priority, projectID: task.projectID,
                projectKey: task.projectKey,
                createdBy: task.createdBy, claimRole: task.claimRole, claimScope: task.claimScope,
                claimedBy: task.claimedBy, claimedAt: task.claimedAt,
                completedAt: status == .done ? (task.completedAt ?? Date()) : nil,
                result: task.result, source: task.source,
                createdAt: task.createdAt, updatedAt: Date()
            )
        }
        reload()
    }

    /// Re-files a task into another project — the "File under…" menu.
    func move(taskID: Int64, toProjectKey key: String) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.moveTask(id: taskID, toProjectKey: key)
        }
        reload()
    }

    /// Attaches a session to a task — the drop target for a card, and the
    /// "Link to task…" menu item.
    func link(session: SessionKey, to taskID: Int64) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            try? repository.link(taskID: taskID, session: session, kind: .manual)
        }
        reload()
    }

    /// Detaches a session a person attached. A claim is released, not
    /// unlinked — see ``TaskRepository/unlink(taskID:session:)``.
    func unlink(session: SessionKey, from taskID: Int64) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            try? repository.unlink(taskID: taskID, session: session)
        }
        reload()
    }

    /// Files a task by hand, in a project.
    func createTask(title: String, projectKey: String, planID: Int64?) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.createTask(
                title: title, planID: planID, projectKey: projectKey, source: "ui"
            )
        }
        reload()
    }

    /// Registers a milestone inside a project, by hand.
    func createMilestone(title: String, projectKey: String) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.createPlan(title: title, projectKey: projectKey)
        }
        reload()
    }

    /// Files a milestone away.
    func archivePlan(id: Int64) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.archivePlan(id: id)
        }
        reload()
    }

    /// Redraws from an edited copy of the ledger, so a drag lands on the frame
    /// the person dropped it on rather than one store round trip later.
    private func optimistically(_ transform: (AuspexTask) -> AuspexTask) {
        guard let latest else { return }
        self.latest = LedgerSnapshot(
            plans: latest.plans,
            tasks: latest.tasks.map(transform),
            links: latest.links
        )
        rebuild()
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
    }
}
