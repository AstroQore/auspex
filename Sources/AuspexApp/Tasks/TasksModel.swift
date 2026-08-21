import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// The Tasks page's state: the plans, the tasks under them, and which live
/// sessions are attached to each.
///
/// Read on demand rather than observed. The ledger changes when a person drags
/// a card or an agent calls a tool — a few times a minute at most — so a
/// `ValueObservation` over four tables would spend a connection to save a query
/// nobody is waiting on. ``reload()`` is called from both of those places and
/// from the page appearing.
///
/// The *live* half of a row — what the attached session is doing right now —
/// does not come from here at all. It comes from the board frame, through
/// ``apply(board:)``, which is what keeps the state dot on a task row and the
/// state pill on its card from ever disagreeing.
@MainActor
@Observable
final class TasksModel {
    /// Plans, most recently touched first, each with its tasks.
    private(set) var lanes: [TaskLane] = []

    /// Tasks filed under no plan. A legitimate shape — somebody filed one
    /// thing — and drawn as a lane of its own rather than hidden.
    private(set) var unfiled: TaskLane?

    /// Whether anything has ever been filed. Distinguishes "nobody has used
    /// this yet" from "everything is finished", which want different pages.
    private(set) var isEmpty = true

    /// Tasks not yet in the `done` column — the number beside the sidebar row.
    ///
    /// An `Int` rather than a derivation over ``lanes``, because the sidebar is
    /// on screen always and reading the lanes would invalidate it every time
    /// any task moved.
    private(set) var openCount = 0

    /// Whether archived plans are drawn as well.
    var showsArchived = false {
        didSet { if oldValue != showsArchived { reload() } }
    }

    /// The task a person is dragging, so a column can say it will take it.
    var draggingTaskID: Int64?

    /// The row the detail strip is about.
    var selectedTaskID: Int64?

    private var repository: TaskRepository?
    private var live: [SessionKey: LiveSessionState] = [:]
    /// The sessions any task is attached to.
    ///
    /// The whole reason ``apply(board:notices:)`` is affordable. It is called
    /// from the frame hook, which runs eight times a second whether or not this
    /// page is on screen, and deriving a title and a project for every session
    /// on a six-hundred-session board at that rate is exactly the kind of
    /// always-on cost `AGENTS.md` § 4.1 exists to prevent. A task board with
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

    /// One plan and everything under it.
    struct TaskLane: Identifiable, Equatable {
        /// `plan-<id>`, or `unfiled`. Stable across reloads so SwiftUI keeps
        /// the column's scroll position while the board churns.
        let id: String
        let plan: AuspexPlan?
        let title: String
        let summary: String?
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
    /// the same fact as its card's pill.
    func apply(
        board: BoardSnapshot,
        notices: [SessionKey: AgentNotice],
        attention: [SessionKey: AttentionState] = [:]
    ) {
        guard !linkedKeys.isEmpty else {
            if !live.isEmpty { live = [:]; rebuild() }
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
        guard next != live else { return }
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

    private func rebuild() {
        guard let latest else { return }
        isEmpty = latest.plans.isEmpty && latest.tasks.isEmpty
        openCount = latest.tasks.count { $0.status != .done }


        let linksByTask = Dictionary(grouping: latest.links) { $0.taskID }
        linkedKeys = Set(latest.links.map(\.session))
        func row(_ task: AuspexTask) -> TaskRow {
            let attached = (linksByTask[task.id] ?? [])
                .compactMap { live[$0.session] }
            return TaskRow(task: task, sessions: attached)
        }

        let byPlan = Dictionary(grouping: latest.tasks) { $0.planID }
        lanes = latest.plans.map { plan in
            TaskLane(
                id: "plan-\(plan.id)",
                plan: plan,
                title: plan.title,
                summary: plan.summary,
                tasks: (byPlan[plan.id] ?? []).map(row)
            )
        }
        let orphans = byPlan[nil] ?? []
        unfiled = orphans.isEmpty
            ? nil
            : TaskLane(
                id: "unfiled",
                plan: nil,
                title: "Unfiled",
                summary: "Filed without a plan — by a person, or by an agent working alone.",
                tasks: orphans.map(row)
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
                createdBy: task.createdBy, claimRole: task.claimRole, claimScope: task.claimScope,
                claimedBy: task.claimedBy, claimedAt: task.claimedAt,
                completedAt: status == .done ? (task.completedAt ?? Date()) : nil,
                result: task.result, source: task.source,
                createdAt: task.createdAt, updatedAt: Date()
            )
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

    /// Files a task by hand.
    func createTask(title: String, planID: Int64?) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.createTask(
                title: title, planID: planID, source: "ui"
            )
        }
        reload()
    }

    /// Registers a plan by hand.
    func createPlan(title: String) {
        guard let repository, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? repository.createPlan(title: title)
        }
        reload()
    }

    /// Files a plan away.
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
