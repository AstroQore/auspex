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
    /// Read by the Projects page and by the sidebar's project rows, which draw
    /// it as a quiet pill after the live count — see `ProjectsSidebar`.
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
    /// The wall's units, by id. The live half of every row on this page, and
    /// the whole of the rows the ledger has never heard of.
    private var units: [String: TaskUnit] = [:]
    /// The units nobody filed a task for, in board order — see
    /// ``TaskUnit/Origin/implicit(_:)``.
    private var implicitUnits: [TaskUnit] = []
    /// The user's projects, as the frame carries them.
    ///
    /// Kept so a lane can be titled and a task can be folded into the project a
    /// person made *after* it was filed. Compared before it is stored: claims
    /// change when somebody edits the Projects page, which is not eight times a
    /// second.
    private var claims: ProjectClaims = .empty
    private var reloadTask: Task<Void, Never>?

    /// What a task row knows about a session attached to it.
    ///
    /// Read off the same ``BoardRow`` the wall drew, so a task row and the
    /// card behind it cannot disagree about whether a worker is stuck.
    struct LiveSessionState: Sendable, Equatable {
        let key: SessionKey
        let harness: Harness
        let title: String
        let state: SessionState
        let isAlive: Bool
        let notice: AgentNotice?
        let attention: AttentionState

        init(_ row: BoardRow) {
            self.key = row.key
            self.harness = row.harness
            self.title = row.title
            self.state = row.state
            self.isAlive = !row.isEnded
            self.notice = row.notice.map {
                AgentNotice(
                    session: row.key, kind: $0.kind, message: $0.message,
                    urgency: $0.urgency, createdAt: $0.at
                )
            }
            self.attention = row.attention
        }
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

    /// One task, and the piece of work the board derived for it.
    ///
    /// Both, because they answer different questions. The ``task`` is what the
    /// ledger holds — the title somebody filed, the column somebody dragged it
    /// to, the milestone it hangs under. The ``unit`` is what is *happening*:
    /// which sessions are on it, what they are doing, and whether any of them
    /// is stuck. A row with no unit is a task the board has no session for,
    /// which is the ordinary state of a backlog.
    struct TaskRow: Identifiable, Equatable {
        var id: Int64 { task.id }
        let task: AuspexTask
        let unit: TaskUnit?

        /// Whether the board worked this row out rather than being told.
        ///
        /// An implicit row is a delegation nobody filed a task for. It is
        /// drawn quieter and offers "Promote to task…" instead of the actions
        /// that need a row in the ledger to act on.
        var isImplicit: Bool { unit?.origin.isImplicit ?? false }

        /// The sessions on it, as the page draws them.
        var sessions: [LiveSessionState] {
            unit?.members.map(LiveSessionState.init) ?? []
        }

        /// A session on this task that is calling for a person.
        var callingNotice: AgentNotice? {
            sessions.compactMap(\.notice).first { $0.kind.wantsPerson }
        }

        /// Whether a worker on this task is asking for a person.
        var wantsPerson: Bool { unit?.needsPerson ?? false }

        /// Which column this row is drawn in.
        ///
        /// The unit's own status when there is one, which is where the
        /// correction lives: a task sitting in `Doing` while its worker is
        /// blocked on a permission prompt is the board telling two stories
        /// about one thing, and a person acts on the louder one. See
        /// ``TaskUnitBuilder/status(task:attention:counts:rows:)``.
        var displayStatus: AuspexTaskStatus { unit?.status ?? task.status }
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

    /// Hands the page the units the wall just drew.
    ///
    /// The whole live half of this page, and it costs nothing to keep in step
    /// because the derivation already happened: the board built these units on
    /// its own executor, once, and this is the same values by reference. What
    /// used to be here — a title and a project derived per session per frame —
    /// was exactly the always-on cost `AGENTS.md` § 4.1 exists to prevent.
    func apply(units: [TaskUnit], board: BoardSnapshot) {
        var changed = false
        if board.claims != claims {
            claims = board.claims
            changed = true
        }
        var next: [String: TaskUnit] = [:]
        next.reserveCapacity(units.count)
        var implicit: [TaskUnit] = []
        for unit in units {
            next[unit.id] = unit
            if unit.origin.isImplicit { implicit.append(unit) }
        }
        guard next != self.units || implicit != implicitUnits || changed else { return }
        self.units = next
        implicitUnits = implicit
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
        updateIsEmpty(latest)
        // Every open piece of work, filed or not. The sidebar's number and the
        // page's own summary have to be the same number, and the page counts
        // what it draws — which since the board became a task board includes
        // the delegations nobody filed a task for.
        openCount = latest.tasks.count { $0.status.isOpen }
            + implicitUnits.count { $0.status.isOpen }

        func row(_ task: AuspexTask) -> TaskRow {
            TaskRow(task: task, unit: units["task:\(task.id)"])
        }

        let plansByID = Dictionary(latest.plans.map { ($0.id, $0) }) { first, _ in first }
        var order: [String] = []
        var tasksByProject: [String: [AuspexTask]] = [:]
        var counts: [String: TaskProjectCounts] = [:]
        // The work the board can see and nobody filed. Its rows carry a
        // *synthesized* task — see ``implicitTask(for:)`` — so one column, one
        // card and one drag path serve both kinds, and the only thing that
        // tells them apart is what the row is allowed to do.
        var implicitByProject: [String: [TaskUnit]] = [:]
        for unit in implicitUnits {
            let key = unit.projectKey.flatMap { claims.key(forPath: $0) ?? $0 }
                ?? TaskProject.scratchKey
            implicitByProject[key, default: []].append(unit)
        }
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
                open: existing.open + (task.status.isOpen ? 1 : 0)
            )
        }
        for (key, units) in implicitByProject where tasksByProject[key] == nil {
            tasksByProject[key] = []
            order.append(key)
            _ = units
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
            lane(
                key: key,
                tasks: tasksByProject[key] ?? [],
                implicit: implicitByProject[key] ?? [],
                plans: plansByID,
                row: row
            )
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
    /// The row a unit nobody filed a task for is drawn as.
    ///
    /// A task with a **negative id**, which the ledger can never mint: it is
    /// what lets one card, one column and one drag path serve both kinds, and
    /// it is what every action on the page checks before it tries to write.
    /// ``TaskRow/isImplicit`` is the question, and it is asked of the unit
    /// rather than of the sign, because the sign is an implementation detail
    /// and the origin is the fact.
    private func implicitTask(for unit: TaskUnit) -> AuspexTask {
        AuspexTask(
            id: -abs(Int64(unit.promotionKey.hashValue % 1_000_000_007) + 1),
            planID: nil,
            title: unit.title,
            body: nil,
            status: unit.status,
            priority: 0,
            projectID: nil,
            projectKey: unit.projectKey,
            createdBy: unit.lead.key,
            claimRole: nil,
            claimScope: nil,
            claimedBy: nil,
            claimedAt: nil,
            completedAt: nil,
            result: nil,
            source: "board",
            createdAt: unit.lastEventAt ?? Date(),
            updatedAt: unit.lastEventAt ?? Date()
        )
    }

    private func lane(
        key: String,
        tasks: [AuspexTask],
        implicit: [TaskUnit],
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
        // The derived work goes under no milestone, because there is nothing
        // to hang it under: nobody filed it, so nobody put it in a stage.
        let derived = implicit.map { TaskRow(task: implicitTask(for: $0), unit: $0) }
        if !loose.isEmpty || !derived.isEmpty || groups.isEmpty {
            groups.append(
                MilestoneGroup(id: "\(key)-loose", plan: nil, tasks: loose.map(row) + derived)
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

    /// Whether the page has anything to draw at all — including work the
    /// board derived, which is what makes this page useful on a machine where
    /// nobody has filed a thing.
    private func updateIsEmpty(_ latest: LedgerSnapshot) {
        isEmpty = latest.plans.isEmpty && latest.tasks.isEmpty && implicitUnits.isEmpty
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
        optimistically { $0.id == taskID ? $0.moved(to: status) : $0 }
        reload()
    }

    /// Closes a task. The one gesture only a person makes.
    ///
    /// `tasks.complete` puts a task in Review; this is what ends it. Keeping
    /// them apart is the whole of the Review state: an agent saying it
    /// finished is a claim about its own work, and a board that let it close
    /// its own task would have one number on it that an agent could move.
    func close(unit: TaskUnit) {
        guard let id = unit.origin.taskID else { return }
        close(taskID: id)
    }

    func close(taskID id: Int64) {
        guard let repository, id > 0 else { return }
        Task.detached(priority: .userInitiated) { _ = try? repository.closeTask(id: id) }
        optimistically { $0.id == id ? $0.moved(to: .done) : $0 }
        reload()
    }

    /// Puts a closed task back in flight.
    func reopen(unit: TaskUnit) {
        guard let id = unit.origin.taskID else { return }
        reopen(taskID: id)
    }

    func reopen(taskID id: Int64) {
        guard let repository, id > 0 else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.updateTask(id: id, status: .doing)
        }
        optimistically { $0.id == id ? $0.moved(to: .doing) : $0 }
        reload()
    }

    /// Turns a unit the board derived into a task somebody filed.
    ///
    /// The card does not move: it keeps its position, its expansion and its
    /// members, because every surface keys on ``TaskUnit/promotionKey`` and
    /// that is the root session either way. What changes is that there is now
    /// a row to close, to give a milestone, to depend on, and to write notes
    /// against.
    func promote(unit: TaskUnit) {
        guard let repository, unit.origin.isImplicit else { return }
        let title = unit.title
        let projectKey = unit.projectKey
        let session = unit.lead.key
        let role = unit.lead.harness.displayName
        Task.detached(priority: .userInitiated) {
            guard let task = try? repository.createTask(
                title: title, projectKey: projectKey, source: "ui"
            ) else { return }
            // Claimed by the session that was already doing it, so the card
            // gains a claim chip rather than reading as unclaimed work that
            // somebody is mysteriously doing.
            _ = try? repository.claimTask(
                id: task.id, role: role, scope: nil, by: session, projectKey: projectKey
            )
        }
        reload()
    }

    /// Lets go of a claim whose session did not live to finish it.
    func releaseClaim(taskID: Int64) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.releaseTask(id: taskID, by: nil)
        }
        reload()
    }

    // MARK: - One task's history

    /// The task the detail page is reading, and its log.
    ///
    /// Loaded on demand and cached by id. The log is the one part of a task
    /// that is not on the frame — it is rows in SQLite, and there is no reason
    /// for the board to carry every note of every task it can see on the off
    /// chance somebody opens one.
    private(set) var openLog: [AuspexTaskLogEntry] = []
    private var openLogTaskID: Int64?
    private var logTask: Task<Void, Never>?

    /// Reads one task's history, if it is not already the one in hand.
    func loadLog(taskID: Int64?) {
        guard let taskID, taskID > 0 else {
            openLogTaskID = nil
            openLog = []
            return
        }
        guard openLogTaskID != taskID else { return }
        openLogTaskID = taskID
        openLog = []
        refreshLog()
    }

    /// Re-reads the history of whatever the detail page is showing.
    func refreshLog() {
        guard let repository, let taskID = openLogTaskID else { return }
        logTask?.cancel()
        logTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                (try? repository.log(taskID: taskID)) ?? []
            }.value
            guard !Task.isCancelled, self?.openLogTaskID == taskID else { return }
            self?.openLog = entries
        }
    }

    /// Every task in the ledger, for a dependency picker.
    var allTasks: [AuspexTask] { latest?.tasks ?? [] }

    /// Writes one line into a task's history.
    func log(taskID: Int64, kind: TaskNoteKind, message: String, ref: String?) {
        guard let repository, !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            try? repository.appendLog(
                taskID: taskID, actor: nil, kind: kind.rawValue, message: message, ref: ref
            )
        }
        reload()
        // The page the person is looking at, not only the board behind it.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.refreshLog()
        }
    }

    /// Sets what a task waits on.
    func setDependencies(_ ids: [Int64], of taskID: Int64) {
        guard let repository else { return }
        Task.detached(priority: .userInitiated) {
            try? repository.setDependencies(ids, of: taskID)
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
