import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// The Tasks page's state, and the handful of task numbers the rest of the
/// window shows.
///
/// ## Two halves with two costs
///
/// **The page** — ``page``, one lane per project with only its non-empty
/// columns — is derived by ``TaskLanes`` and is rebuilt only while the page is
/// on screen. It used to be rebuilt on every frame the wall adopted, whether
/// or not anybody was looking at it: `onFrame → apply → rebuild` ran on the
/// main actor eight times a second on a busy machine, and a `sample` with the
/// Ledger on screen still had `TasksModel.rebuild()` in it. Now a frame that
/// arrives while the page is hidden costs storing a reference to an array.
///
/// **The numbers** — ``openCount`` for the sidebar, ``projectTaskCounts`` for
/// the Projects page, the menus' targets — come from the ledger alone, are
/// recomputed when the ledger is re-read (a few times a minute at most), and
/// never per frame.
///
/// ## Explicit tasks only
///
/// Implicit units — a session's own work that nobody filed — are not on this
/// page and are not in its numbers. They are Now's and the Sessions page's.
/// Counting them is how the header used to say "850 tasks open" over a ledger
/// of 376.
///
/// Read on demand rather than observed. The ledger changes when a person drags
/// a card or an agent calls a tool; ``reload()`` is called from both of those
/// places and from the page appearing.
@MainActor
@Observable
final class TasksModel {
    // MARK: The page

    /// What the Tasks page draws. Compared lane by lane on (id, revision), so
    /// assigning a rebuild that changed one lane invalidates one lane.
    private(set) var page: TaskLaneBoard = .empty

    /// Which chips are on. The page opens on the work in progress and the
    /// work waiting for review rather than on the whole ledger.
    private(set) var scope: TaskScopeSelection = .default

    /// Whether tasks under archived milestones that are finished are drawn.
    /// Open work under an archived milestone is always drawn.
    var showsArchived = false {
        didSet { if oldValue != showsArchived { rebuildNow() } }
    }

    /// Whether the to-dos the hygiene pass set aside are drawn.
    var showsStale = false {
        didSet { if oldValue != showsStale { rebuildNow() } }
    }

    /// The task a person is dragging, so a column can say it will take it.
    var draggingTaskID: Int64?

    /// A bulk close waiting on the person's confirmation — "Close all" on a
    /// Review column, or "Close all old reviews".
    var pendingClose: BulkClose?

    struct BulkClose: Identifiable, Equatable {
        let id = UUID()
        let ids: [Int64]
    }

    /// Closes what ``pendingClose`` named, and puts the sheet away.
    func confirmPendingClose() {
        guard let request = pendingClose else { return }
        pendingClose = nil
        close(taskIDs: request.ids)
    }

    /// What has been folded and opened on the page.
    private(set) var expansion = TaskLaneExpansion()

    // MARK: The numbers

    /// Whether anything has ever been filed. Distinguishes "nobody has used
    /// this yet" from "everything is finished", which want different pages.
    private(set) var isEmpty = true

    /// Explicit tasks still open, stale ones not counted — the number beside
    /// the sidebar row.
    ///
    /// An `Int` rather than a derivation over the page, because the sidebar is
    /// on screen always and reading the page would invalidate it every time
    /// any task moved.
    private(set) var openCount = 0

    /// The last person-authored write conflict, surfaced by Perch/Tasks UI.
    private(set) var writeErrorDescription: String?

    /// How much work each project is carrying, by the board's project key.
    ///
    /// Folded through the person's claims here rather than grouped in SQLite,
    /// which would not know about them. Read by the Projects page and by the
    /// sidebar's project rows.
    private(set) var projectTaskCounts: [String: TaskProjectCounts] = [:]

    /// What one project is carrying. Zero for a project nobody has filed
    /// anything in, so a caller can draw a pill without unwrapping.
    func taskCounts(byProjectKey key: String) -> TaskProjectCounts {
        projectTaskCounts[key] ?? TaskProjectCounts(total: 0, open: 0)
    }

    /// The projects a task can be re-filed into — "File under…".
    private(set) var projectChoices: [ProjectChoice] = []

    /// The open tasks "Link to task…" offers, by project.
    private(set) var linkTargets: [LinkProject] = []

    struct ProjectChoice: Identifiable, Equatable, Sendable {
        let key: String
        let title: String
        var id: String { key }
    }

    struct LinkProject: Identifiable, Equatable, Sendable {
        let key: String
        let title: String
        let tasks: [LinkTask]
        var id: String { key }
    }

    struct LinkTask: Identifiable, Equatable, Sendable {
        let id: Int64
        let title: String
        /// The sessions already attached, so the menu can leave them out.
        let sessions: Set<SessionKey>
    }

    // MARK: Inputs

    private var repository: TaskRepository?
    /// The wall's units, kept by reference. Indexed by task only when the page
    /// is rebuilt.
    private var units: [TaskUnit] = []
    /// Which revision of the board's units ``units`` is.
    private var unitsRevision: UInt64 = 0
    /// The user's projects, as the frame carries them. Compared before it is
    /// stored: claims change when somebody edits the Projects page.
    private var claims: ProjectClaims = .empty
    /// The project the window is bound to, if any.
    private(set) var focusedProjectKey: String?
    private var reloadTask: Task<Void, Never>?

    /// Hands a completed UI write back to the live task wall. The Tasks page
    /// owns its own rows; the Ledger owns a separately cached frame, and both
    /// have to be refreshed only after SQLite accepted the change.
    var onLedgerChange: (() -> Void)?

    private struct LedgerSnapshot: Sendable {
        let plans: [AuspexPlan]
        let tasks: [AuspexTask]
        let links: [AuspexTaskLink]
        let pendingClaims: [TaskClaimRequest]
    }

    private var latest: LedgerSnapshot?

    // MARK: Visibility

    /// Whether the page is on screen. Only then is it rebuilt.
    private(set) var isVisible = false
    /// Something the page draws changed while it was not rebuilt.
    private(set) var needsRebuild = true
    /// How many times the page has been derived. Diagnostic: what the suite
    /// reads to prove a hidden page costs nothing.
    private(set) var rebuildCount = 0
    private var rebuildTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var lastRebuildAt: Date = .distantPast

    /// The shortest gap between two rebuilds driven by the board. A burst of
    /// frames is one rebuild, and the budget's "board updates within 0.5 s"
    /// holds with room to spare.
    static let rebuildInterval: TimeInterval = 0.3

    /// Says whether the Tasks page is the page on screen. Rebuilds at once
    /// when it becomes visible with something new to show, and starts the
    /// clock that keeps "12d ago" honest; stops it when it is hidden.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if needsRebuild { rebuildNow() }
            startClock()
        } else {
            rebuildTask?.cancel()
            rebuildTask = nil
            clockTask?.cancel()
            clockTask = nil
        }
    }

    // MARK: Lifecycle

    /// Starts reading from `repository`, and does the first read.
    func start(repository: TaskRepository) {
        self.repository = repository
        reload()
    }

    /// Re-reads the ledger. Coalesced: a burst of tool calls is one read.
    func reload() {
        guard let repository else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) { () -> LedgerSnapshot in
                LedgerSnapshot(
                    // Every milestone, archived included: a card under one
                    // still wears its tag.
                    plans: (try? repository.plans(includingArchived: true, limit: 1_000)) ?? [],
                    tasks: (try? repository.tasks(includeStale: true, limit: 1_000)) ?? [],
                    links: (try? repository.allLinks()) ?? [],
                    pendingClaims: (try? repository.claimRequests()) ?? []
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.adopt(snapshot)
        }
    }

    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        rebuildTask?.cancel()
        clockTask?.cancel()
    }

    /// Hands the page the units the wall just drew.
    ///
    /// The whole live half of the page — which session is on a task and what
    /// it is doing — and while the page is hidden this is the whole of its
    /// cost: two comparisons and a reference.
    func apply(units: [TaskUnit], revision: UInt64, board: BoardSnapshot) {
        var claimsMoved = false
        if board.claims != claims {
            claims = board.claims
            claimsMoved = true
        }
        if claimsMoved { refreshNumbers() }
        guard revision != unitsRevision || claimsMoved else { return }
        unitsRevision = revision
        self.units = units
        pageInputsChanged()
    }

    /// The project the window is bound to — the Tasks page shows that one
    /// lane, even when it is empty.
    func setFocusedProject(_ key: String?) {
        guard key != focusedProjectKey else { return }
        focusedProjectKey = key
        rebuildNow()
    }

    private func adopt(_ snapshot: LedgerSnapshot) {
        latest = snapshot
        refreshNumbers()
        rebuildNow()
    }

    // MARK: Building

    /// Something the page draws changed. Rebuilt soon if the page is on
    /// screen — at most once per ``rebuildInterval`` — and not at all while it
    /// is hidden.
    private func pageInputsChanged() {
        needsRebuild = true
        guard isVisible, rebuildTask == nil else { return }
        let wait = Self.rebuildInterval - Date().timeIntervalSince(lastRebuildAt)
        rebuildTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
            guard !Task.isCancelled, let self else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    /// For what a person did: a chip, a fold, a drag. Those must land on the
    /// frame they were made on.
    private func rebuildNow() {
        needsRebuild = true
        guard isVisible else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuild()
    }

    private func rebuild() {
        guard let latest else { return }
        needsRebuild = false
        rebuildCount += 1
        lastRebuildAt = Date()
        var byTask: [Int64: TaskUnit] = [:]
        byTask.reserveCapacity(latest.tasks.count)
        for unit in units {
            if let id = unit.origin.taskID { byTask[id] = unit }
        }
        let next = TaskLanes.board(
            tasks: latest.tasks,
            plans: latest.plans,
            units: byTask,
            claims: claims,
            scope: scope,
            showsArchived: showsArchived,
            showsStale: showsStale,
            focusedProjectKey: focusedProjectKey,
            expansion: expansion,
            text: Self.text,
            now: Date()
        )
        if page != next { page = next }
    }

    /// Ages are minutes at their finest, so once a minute is often enough to
    /// keep "4m ago" from going stale on a page nobody is touching.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.pageInputsChanged()
            }
        }
    }

    /// The strings a card carries, in the interface language.
    static let text = TaskLaneText(
        age: { date, now in RelativeTimeText.since(date, now: now, showsSeconds: false) },
        unclaimedFiled: { L10n.Tasks.Card.unclaimedFiled(age: $0) },
        condense: { PathDisplay.condense($0, limit: 60) },
        scratch: L10n.Common.scratch
    )

    /// The numbers that do not depend on the page: counts, menus, emptiness.
    /// O(tasks), and only when the ledger or the claims moved.
    private func refreshNumbers() {
        guard let latest else { return }
        let empty = latest.plans.isEmpty && latest.tasks.isEmpty
        if isEmpty != empty { isEmpty = empty }

        var open = 0
        var counts: [String: TaskProjectCounts] = [:]
        var linkable: [String: [AuspexTask]] = [:]
        var keys: Set<String> = []
        for task in latest.tasks {
            let key = TaskLanes.projectKey(of: task, claims: claims)
            keys.insert(key)
            let isOpen = task.status.isOpen && !task.isStale
            if isOpen { open += 1 }
            let existing = counts[key] ?? TaskProjectCounts(total: 0, open: 0)
            counts[key] = TaskProjectCounts(
                total: existing.total + 1, open: existing.open + (isOpen ? 1 : 0)
            )
            if isOpen { linkable[key, default: []].append(task) }
        }
        if openCount != open { openCount = open }
        if projectTaskCounts != counts { projectTaskCounts = counts }

        let choices = keys.map { ProjectChoice(key: $0, title: title(forKey: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if projectChoices != choices { projectChoices = choices }

        let sessionsByTask = Dictionary(grouping: latest.links, by: \.taskID)
            .mapValues { Set($0.map(\.session)) }
        let targets = linkable.map { key, tasks in
            LinkProject(
                key: key,
                title: title(forKey: key),
                tasks: tasks.map {
                    LinkTask(id: $0.id, title: $0.title, sessions: sessionsByTask[$0.id] ?? [])
                }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if linkTargets != targets { linkTargets = targets }
    }

    /// What a project is called: the name a person gave it, "Scratch", or its
    /// key's last path component.
    private func title(forKey key: String) -> String {
        if TaskProject.isScratch(key) { return L10n.Common.scratch }
        return claims.name(forKey: key) ?? BoardGrouping.projectName(forPath: key)
    }

    // MARK: - What a person changes on the page

    func toggle(_ scope: TaskScope) {
        self.scope.toggle(scope)
        rebuildNow()
    }

    func showEverything() {
        guard !scope.isAll else { return }
        scope = .all
        rebuildNow()
    }

    func toggleLane(_ key: String) {
        expansion.collapsedLanes.formSymmetricDifference([key])
        rebuildNow()
    }

    func toggleColumn(_ id: String) {
        expansion.expandedColumns.formSymmetricDifference([id])
        rebuildNow()
    }

    func toggleOldReviews(_ laneKey: String) {
        expansion.expandedOldReviews.formSymmetricDifference([laneKey])
        rebuildNow()
    }

    /// Narrows one lane to one milestone, or widens it again.
    func toggleMilestone(_ planID: Int64, inLane laneKey: String) {
        if expansion.milestoneFilter[laneKey] == planID {
            expansion.milestoneFilter[laneKey] = nil
        } else {
            expansion.milestoneFilter[laneKey] = planID
        }
        rebuildNow()
    }

    // MARK: - Editing

    /// Moves a task between columns. Written straight through: the drag is the
    /// person's decision and the board should show it on the same frame.
    func move(taskID: Int64, to status: AuspexTaskStatus) {
        guard let repository else { return }
        optimistically { $0.id == taskID ? $0.moved(to: status) : $0 }
        performWrite {
            try? repository.updateTask(id: taskID, status: status)
        }
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
        performWrite {
            try? repository.closeTask(id: id)
        }
        optimistically { $0.id == id ? $0.moved(to: .done) : $0 }
    }

    /// Closes several tasks — "Close all" on a Review column, and "Close all
    /// old reviews". The same close as one card's, once per task, so every
    /// task gets its own line in its own history; one reload and one board
    /// refresh after the last.
    func close(taskIDs ids: [Int64]) {
        guard let repository else { return }
        let ids = ids.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        let closing = Set(ids)
        optimistically { closing.contains($0.id) ? $0.moved(to: .done) : $0 }
        performWrite { () -> Int? in
            var closed = 0
            for id in ids where (try? repository.closeTask(id: id)) != nil { closed += 1 }
            return closed > 0 ? closed : nil
        }
    }

    /// Puts a closed task back in flight.
    func reopen(unit: TaskUnit) {
        guard let id = unit.origin.taskID else { return }
        reopen(taskID: id)
    }

    func reopen(taskID id: Int64) {
        guard let repository, id > 0 else { return }
        performWrite {
            try? repository.updateTask(id: id, status: .doing)
        }
        optimistically { $0.id == id ? $0.moved(to: .doing) : $0 }
    }

    /// Keeps a stale task on the board for another week — see
    /// ``TaskRepository/keepTask(id:by:now:)``.
    func keep(taskID id: Int64) {
        guard let repository, id > 0 else { return }
        performWrite {
            try? repository.keepTask(id: id)
        }
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
        performWrite(operation: { () -> AuspexTask? in
            guard let task = try? repository.createTask(
                title: title, projectKey: projectKey, source: "ui"
            ) else { return nil }
            // Claimed by the session that was already doing it, so the card
            // gains a claim chip rather than reading as unclaimed work that
            // somebody is mysteriously doing.
            _ = try? repository.claimTask(
                id: task.id, role: role, scope: nil, by: session, projectKey: projectKey
            )
            return task
        })
    }

    /// Lets go of a claim whose session did not live to finish it.
    func releaseClaim(taskID: Int64) {
        guard let repository else { return }
        performWrite {
            try? repository.releaseTask(id: taskID, by: nil)
        }
    }

    /// The takeover requests a person can decide from one task's detail page.
    func pendingClaims(taskID: Int64) -> [TaskClaimRequest] {
        latest?.pendingClaims.filter { $0.taskID == taskID } ?? []
    }

    /// The human-only side of takeover. There is no matching MCP tool.
    private var takeoverResolutionNotice: (taskID: Int64, message: String)?

    func takeoverResolutionMessage(taskID: Int64) -> String? {
        guard takeoverResolutionNotice?.taskID == taskID else { return nil }
        return takeoverResolutionNotice?.message
    }

    func resolveTakeover(requestID: Int64, approve: Bool) {
        guard let repository else { return }
        performWrite(refreshesLog: true, operation: {
            try? repository.resolveClaimRequest(id: requestID, approve: approve)
        }, completion: { [weak self] outcome in
            if let outcome, outcome.request.status == .expired {
                self?.takeoverResolutionNotice = (
                    outcome.task.id,
                    L10n.Tasks.takeoverExpired
                )
            } else {
                self?.takeoverResolutionNotice = nil
            }
        })
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
        performWrite(refreshesLog: true) {
            do {
                try repository.appendLog(
                    taskID: taskID, actor: nil, kind: kind.rawValue,
                    message: message, ref: ref
                )
                return true
            } catch { return nil }
        }
    }

    /// Sets what a task waits on.
    func setDependencies(
        _ ids: [Int64],
        of taskID: Int64,
        expectedVersion: Int64? = nil
    ) {
        guard let repository else { return }
        writeErrorDescription = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try repository.setDependencies(
                        ids,
                        of: taskID,
                        expectedVersion: expectedVersion
                    )
                }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                onLedgerChange?()
            case .failure(let error):
                writeErrorDescription = error.localizedDescription
            }
            reload()
        }
    }

    /// Re-files a task into another project — the "File under…" menu.
    func move(taskID: Int64, toProjectKey key: String) {
        guard let repository else { return }
        performWrite {
            try? repository.moveTask(id: taskID, toProjectKey: key)
        }
    }

    /// Attaches a session to a task — the drop target for a card, and the
    /// "Link to task…" menu item.
    func link(session: SessionKey, to taskID: Int64) {
        guard let repository else { return }
        performWrite {
            do {
                try repository.link(taskID: taskID, session: session, kind: .manual)
                return true
            } catch { return nil }
        }
    }

    /// Detaches a session a person attached. A claim is released, not
    /// unlinked — see ``TaskRepository/unlink(taskID:session:)``.
    func unlink(session: SessionKey, from taskID: Int64) {
        guard let repository else { return }
        performWrite {
            do {
                try repository.unlink(taskID: taskID, session: session)
                return true
            } catch { return nil }
        }
    }

    /// Files a task by hand, in a project.
    func createTask(title: String, projectKey: String, planID: Int64?) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        performWrite {
            try? repository.createTask(
                title: title, planID: planID, projectKey: projectKey, source: "ui"
            )
        }
    }

    /// Registers a milestone inside a project, by hand.
    func createMilestone(title: String, projectKey: String) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        performWrite {
            try? repository.createPlan(title: title, projectKey: projectKey)
        }
    }

    /// Files a milestone away.
    func archivePlan(id: Int64) {
        guard let repository else { return }
        performWrite {
            try? repository.archivePlan(id: id)
        }
    }

    /// One ordering for every person-authored ledger mutation: finish the
    /// transaction off-main-actor, then refresh both the Roost model and the
    /// live board from the accepted state. Reading before the write completed
    /// was a race that could leave Catch-up stale until an unrelated MCP call.
    private func performWrite<Result: Sendable>(
        refreshesLog: Bool = false,
        operation: @escaping @Sendable () -> Result?,
        completion: ((Result?) -> Void)? = nil
    ) {
        Task { [weak self] in
            let result = await Task.detached(
                priority: .userInitiated,
                operation: operation
            ).value
            guard let self else { return }
            completion?(result)
            reload()
            if result != nil { onLedgerChange?() }
            if refreshesLog {
                try? await Task.sleep(for: .milliseconds(80))
                refreshLog()
            }
        }
    }

    /// Redraws from an edited copy of the ledger, so a drag lands on the frame
    /// the person dropped it on rather than one store round trip later.
    private func optimistically(_ transform: (AuspexTask) -> AuspexTask) {
        guard let latest else { return }
        self.latest = LedgerSnapshot(
            plans: latest.plans,
            tasks: latest.tasks.map(transform),
            links: latest.links,
            pendingClaims: latest.pendingClaims
        )
        refreshNumbers()
        rebuildNow()
    }
}
