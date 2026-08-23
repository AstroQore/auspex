import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The Tasks page: the projects on this machine, the work inside each, and the
/// live sessions on it.
///
/// ## Why a board rather than a list
///
/// The question this page answers is *which of the things I handed out is
/// moving, and which is stuck*. A list sorted by anything answers it badly,
/// because "stuck" is not a property of one row — it is the shape of the
/// column that row is in. Four columns and a glance is the whole interaction.
///
/// ## Why the lanes are projects
///
/// Because everything else on this app already divides by project — the wall's
/// sections, the sidebar's tree, the scene's floor plates — and a task board
/// that divided by something else would be a second map of the same machine.
/// A milestone is a sub-heading *inside* a lane: optional, and never the thing
/// that contains the work. Nothing is "unfiled", because a task filed by an
/// agent is filed in the project that agent was working in.
///
/// ## What is live and what is filed
///
/// A task's column is what somebody — a person dragging, or an agent calling
/// `tasks.update` — *said*. The dot on its row is what its session is actually
/// doing, read from the same board frame the wall draws. Keeping both is the
/// point: a task filed under "doing" whose only session ended an hour ago is
/// exactly the row this page exists to surface, and a board that overwrote one
/// with the other could not show it.
struct TasksPageView: View {
    let model: TasksModel
    let board: LiveBoardModel

    /// The width of one column. Five of them plus the gaps fit the content
    /// column at its default width, which is what keeps a whole project
    /// readable without a horizontal scroll — and there are five since
    /// finishing stopped meaning closing. See ``AuspexTaskStatus/review``.
    static let columnWidth: CGFloat = 148

    var body: some View {
        BoardScroll {
            // Deliberately eager. Roost rows have dynamic heights, nested
            // columns, drag targets and native controls. On macOS 26.5.2 a
            // `LazyVStack` enters a self-sustaining prefetch/update cycle after
            // a short scroll: LazyLayoutViewCache.signalPrefetch asks the
            // hosting view for another transaction while the current one is
            // still placing task cards. The real failure holds the main thread
            // at 100% CPU and grows memory until the window stops answering.
            //
            // `VStack` has no prefetch cache to feed back. The page is already
            // bounded by the ledger read and groups rows by project; more
            // importantly, one project lane eagerly builds its task columns
            // even under a lazy outer stack, so the lazy container never
            // provided a meaningful per-card saving here.
            VStack(alignment: .leading, spacing: 16) {
                pageBar
                if model.isEmpty {
                    TasksEmptyState()
                } else {
                    ForEach(visibleLanes) { lane in
                        ProjectLaneView(lane: lane, model: model, board: board)
                    }
                }
                UnregisteredSessionsSection(model: model, board: board)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(BoardSurfaceBackground())
    }

    /// Which projects are drawn.
    ///
    /// A project with nothing in it is not a lane: on a machine with thirty
    /// repositories, twenty-eight empty headings would bury the two that have
    /// work in them. The exception is the project a person has *focused* —
    /// they bound the window to it, so the honest answer to "what is in it" is
    /// an empty lane saying so rather than a page that omits the thing they
    /// asked about.
    private var visibleLanes: [TasksModel.ProjectLane] {
        guard let focus = board.focusedProjectKey else {
            return model.lanes.filter { !$0.isEmpty }
        }
        return [model.lanes.first { $0.key == focus } ?? model.emptyLane(forKey: focus)]
    }

    /// The archive switch, and what the page is showing.
    ///
    /// In the page rather than only in the toolbar, because the toolbar of the
    /// content column is shared with the board and a control that appears and
    /// disappears there is a control nobody finds twice.
    @ViewBuilder
    private var pageBar: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 8)
            if board.reviewCount > 0 {
                Button { board.openNextReview() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Review next · \(board.reviewCount)")
                            .font(AuspexType.pill)
                    }
                    .foregroundStyle(AuspexPalette.stateWriting)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AuspexPalette.stateWriting.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.auspex(cornerRadius: 6))
                .help("Open the first task waiting for review")
            }
            Button { model.showsArchived.toggle() } label: {
                Text(model.showsArchived ? "Hide archived" : "Show archived")
                    .font(AuspexType.pill)
                    .foregroundStyle(
                        model.showsArchived ? AuspexPalette.text : AuspexPalette.text3
                    )
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(model.showsArchived ? AuspexPalette.selection : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help("Show milestones that have been filed away")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AuspexPalette.bg1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AuspexPalette.line, lineWidth: 1)
        )
    }

    private var summary: String {
        let lanes = visibleLanes.count
        let open = visibleLanes.reduce(0) { $0 + $1.openCount }
        let projects = lanes == 1 ? "1 project" : "\(lanes) projects"
        let tasks = open == 1 ? "1 task open" : "\(open) tasks open"
        return "\(projects) · \(tasks)"
    }
}

// MARK: - One project

/// One project: its milestones, the tasks in none of them, and four columns
/// under each.
private struct ProjectLaneView: View {
    let lane: TasksModel.ProjectLane
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isAddingMilestone = false
    @State private var draftMilestone = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isAddingMilestone { milestoneField }
            ForEach(lane.groups) { group in
                MilestoneGroupView(
                    group: group,
                    lane: lane,
                    // A lane with milestones in it needs to say what the last
                    // set of columns is, or two identical column headers look
                    // like a rendering mistake. A lane with none says nothing:
                    // "not in a milestone" over the only thing there is would
                    // be a heading about an absence.
                    namesLooseGroup: lane.groups.contains { $0.plan != nil },
                    model: model,
                    board: board
                )
            }
        }
        .padding(14)
        .panelChrome()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if let harness = lane.harness {
                        HarnessBadge(harness: harness, size: 15)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AuspexPalette.text3)
                    }
                    Text(lane.title)
                        .font(AuspexType.cardTitle)
                        .foregroundStyle(AuspexPalette.text)
                }
                if let subtitle = lane.subtitle {
                    Text(subtitle)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            Text(lane.openCount == 1 ? "1 open" : "\(lane.openCount) open")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
            Button {
                isAddingMilestone.toggle()
            } label: {
                Text("Milestone")
                    .font(AuspexType.pill)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .foregroundStyle(AuspexPalette.text3)
            .help("Register a milestone inside this project")
        }
    }

    private var milestoneField: some View {
        HStack(spacing: 8) {
            TextField("What is the whole piece of work?", text: $draftMilestone)
                .textFieldStyle(.plain)
                .font(AuspexType.body)
                .auspexSystemControlFocus()
                .onSubmit(commit)
            Button("Register", action: commit)
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.stateThinking)
                .disabled(draftMilestone.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { isAddingMilestone = false; draftMilestone = "" }
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.text3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AuspexPalette.bg2)
        )
    }

    private func commit() {
        model.createMilestone(title: draftMilestone, projectKey: lane.key)
        draftMilestone = ""
        isAddingMilestone = false
    }
}

// MARK: - One milestone

/// A milestone's sub-header and its four columns — or, for the tasks in no
/// milestone, the four columns on their own.
private struct MilestoneGroupView: View {
    let group: TasksModel.MilestoneGroup
    let lane: TasksModel.ProjectLane
    /// Whether the tasks in no milestone get a heading of their own.
    var namesLooseGroup = false
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isAddingTask = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if group.tasks.isEmpty {
                // One quiet line rather than four boxes with a dash in each:
                // an empty project says one thing, and it should say it once.
                // No symbol — the lane's own header already says what kind of
                // thing is missing — and no box, per `EmptyStateView`.
                EmptyStateView(
                    title: "Nothing to do",
                    detail: group.plan == nil
                        ? "Nothing is filed in this project yet."
                        : "This milestone has no tasks under it."
                )
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
                        TaskColumnView(
                            status: status,
                            rows: group.column(status),
                            model: model,
                            board: board
                        )
                    }
                }
            }
            if isAddingTask { newTaskField }
        }
        .opacity(group.isArchived ? 0.6 : 1)
    }

    /// The sub-header, when there is a milestone to head. The tasks in none get
    /// the add button and nothing else: a heading over them would be a heading
    /// that says "the rest".
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if group.plan == nil, namesLooseGroup {
                Text("Not in a milestone")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }
            if let title = group.title {
                Text(title)
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text2)
                if let plan = group.plan {
                    Text(plan.slug)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .textSelection(.enabled)
                }
                if group.isArchived {
                    Text("archived")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                }
                if let summary = group.summary {
                    Text(summary)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button {
                isAddingTask.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .foregroundStyle(AuspexPalette.text3)
            .help(group.plan == nil ? "File a task in this project" : "File a task under this milestone")
            if let plan = group.plan, !group.isArchived {
                Button { model.archivePlan(id: plan.id) } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.auspex)
                .foregroundStyle(AuspexPalette.text3)
                .help("File this milestone away. Its tasks stay in this project.")
            }
        }
        .overlay(alignment: .bottom) {
            if group.title != nil || namesLooseGroup {
                Rectangle().fill(AuspexPalette.line).frame(height: 1).offset(y: 3)
            }
        }
    }

    private var newTaskField: some View {
        HStack(spacing: 8) {
            TextField("What has to be done", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(AuspexType.body)
                .auspexSystemControlFocus()
                .onSubmit(commit)
            Button("Add", action: commit)
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.stateThinking)
                .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AuspexPalette.bg2)
        )
    }

    private func commit() {
        model.createTask(title: draftTitle, projectKey: lane.key, planID: group.plan?.id)
        draftTitle = ""
        isAddingTask = false
    }
}

// MARK: - One column

/// One kanban column, and the target a dragged task lands on.
private struct TaskColumnView: View {
    let status: AuspexTaskStatus
    let rows: [TasksModel.TaskRow]
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isTargeted = false
    // `ImageRenderer` cannot draw a view carrying a drop interaction and
    // substitutes a placeholder for it, which would put a yellow box over every
    // column of every screenshot. The offscreen renderer has nothing to drop on
    // anyway.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(status.label)
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                Spacer(minLength: 2)
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(AuspexType.monoCount)
                        .auspexTabularDigits()
                        .foregroundStyle(AuspexPalette.text3)
                }
            }
            .padding(.horizontal, 2)

            ForEach(rows) { row in
                TaskCardView(row: row, model: model, board: board)
            }
            if rows.isEmpty {
                // Empty, and quiet about it: the column keeps enough height to
                // be somewhere a task can be dropped, and says nothing at all.
                // A dash in every empty column is four pieces of punctuation
                // where the honest answer is one absence — and the frame goes
                // with it, because a border around nothing is how a
                // placeholder ends up looking like a control that failed to
                // draw. See `EmptyStateView`.
                Color.clear.frame(height: 28)
            }
        }
        .frame(width: TasksPageView.columnWidth, alignment: .leading)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
        // The chrome is gone when the column is empty, so the area a drag can
        // be dropped on has to be declared rather than inherited from a shape
        // that is no longer painted.
        .contentShape(Rectangle())
        // A column takes tasks. Sessions are dropped on *tasks*, not on
        // columns: "this session is working on that piece of work" is a fact
        // about one task, and a column has no id to attach it to.
        .modifier(TaskDropTarget(isEnabled: !isSnapshotRender, isTargeted: $isTargeted) { items in
            guard let id = items.compactMap(TaskDragPayload.taskID(in:)).first else { return false }
            model.move(taskID: id, to: status)
            return true
        })
    }

    /// A container has a background when it contains something — or when a
    /// task is being dragged over it, which is the one moment an empty column
    /// has to show where it is.
    private var fill: Color {
        if isTargeted { return AuspexPalette.selection }
        return rows.isEmpty ? .clear : AuspexPalette.bg1.opacity(0.6)
    }

    private var stroke: Color {
        if isTargeted { return AuspexPalette.stateThinking.opacity(0.6) }
        return rows.isEmpty ? .clear : AuspexPalette.line
    }
}

/// A drop target that can be switched off.
///
/// One modifier rather than an `if` around the whole view: branching on a
/// condition inside a `body` gives SwiftUI two different view types for the
/// same row, which throws away its identity and with it any animation across
/// the change.
private struct TaskDropTarget: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([String]) -> Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: String.self) { items, _ in
                onDrop(items)
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - One task

/// One task: what it is, who took it, and what their session is doing.
private struct TaskCardView: View {
    let row: TasksModel.TaskRow
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isTargeted = false
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                TaskStatusIcon(status: row.displayStatus, size: 12).padding(.top, 1)
                Text(row.task.title)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(row.isImplicit ? AuspexPalette.text2 : AuspexPalette.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.task.importance.isMarked, !row.isImplicit {
                    TaskImportanceIcon(importance: row.task.importance, size: 11)
                        .padding(.top, 1)
                }
            }

            HStack(spacing: 5) {
                Text(row.unit?.shortID ?? row.task.shortID)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
                // The mark that says nobody filed this. Quiet, and one word: an
                // implicit row is the ordinary case on a machine where the task
                // protocol has not been adopted, but somebody about to act on
                // it should know there is no row in the ledger to act on.
                if row.isImplicit {
                    Text("auto")
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.horizontal, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(AuspexPalette.line, lineWidth: 1)
                        )
                        .fixedSize()
                        .help("Auspex worked this out from a delegation. Nobody filed a task.")
                }
                Spacer(minLength: 0)
                if let unit = row.unit, unit.memberCount > 1 {
                    Text("↳ \(unit.subagents.count)")
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.stateDelegating)
                        .fixedSize()
                }
            }

            if let claim = row.task.claimDescription {
                // The whole reason `claim` takes two strings. On a board of a
                // dozen live sessions, "implementer · the TOML half" is what
                // tells two of them apart; a session id does not.
                Text(claim)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = row.callingNotice {
                HStack(spacing: 5) {
                    NoticePill(kind: notice.kind, isCompact: true)
                    Text(notice.message)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let unit = row.unit, unit.isClaimOrphaned {
                Text("claim orphaned")
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.stateStale)
                    .help("The session holding this claim ended without finishing.")
            }

            if let result = row.task.result, !row.task.status.isOpen || row.task.status == .review {
                Text(result)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateWriting.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !row.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.sessions, id: \.key) { session in
                        Button { select(session.key) } label: {
                            HStack(spacing: 5) {
                                StateDot(
                                    color: session.state.style.color,
                                    glows: session.isAlive && !session.state.isEnded
                                )
                                HarnessBadge(harness: session.harness, size: 13)
                                Text(session.title)
                                    .font(AuspexType.caption)
                                    .foregroundStyle(AuspexPalette.text3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.auspex)
                        .help("\(session.harness.displayName) — \(session.state.label)")
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AuspexPalette.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .opacity(row.isImplicit ? 0.72 : 1)
        // A derived row cannot be dragged between columns: there is no row in
        // the ledger to move, and a card that slid across and sprang back
        // would be worse than one that does not move.
        .modifier(
            TaskDragSource(
                isEnabled: !isSnapshotRender && !row.isImplicit,
                payload: TaskDragPayload.task(row.task.id)
            )
        )
        // A session card dropped here is linked to this task. The same
        // relationship `tasks.claim` records, made by hand.
        .modifier(
            TaskDropTarget(
                isEnabled: !isSnapshotRender && !row.isImplicit,
                isTargeted: $isTargeted
            ) { items in
                guard let key = items.compactMap(TaskDragPayload.sessionKey(in:)).first
                else { return false }
                model.link(session: key, to: row.task.id)
                return true
            }
        )
        .contextMenu {
            if row.isImplicit {
                // Everything below writes to a row that does not exist yet.
                // This is the one action that makes one.
                if let unit = row.unit {
                    Button("Promote to task…") { model.promote(unit: unit) }
                }
            } else {
                if row.task.status == .review {
                    Button("Close") { model.close(taskID: row.task.id) }
                } else if row.task.status == .done {
                    Button("Reopen") { model.reopen(taskID: row.task.id) }
                }
                if row.unit?.isClaimOrphaned == true {
                    Button("Release claim") { model.releaseClaim(taskID: row.task.id) }
                }
                Divider()
                ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
                    Button("Move to \(status.label)") { model.move(taskID: row.task.id, to: status) }
                        .disabled(status == row.task.status)
                }
            }
            // Re-filing by hand, which is what makes the scratch project a
            // place work passes through rather than a place it goes to die.
            let elsewhere = row.isImplicit
                ? []
                : model.lanes.filter { $0.key != row.task.projectKey }
            if !elsewhere.isEmpty {
                Divider()
                Menu("File under…") {
                    ForEach(elsewhere) { lane in
                        Button(lane.title) {
                            model.move(taskID: row.task.id, toProjectKey: lane.key)
                        }
                    }
                }
            }
            if !row.sessions.isEmpty, !row.isImplicit {
                Divider()
                ForEach(row.sessions, id: \.key) { session in
                    Button("Unlink \(session.title)") {
                        model.unlink(session: session.key, from: row.task.id)
                    }
                }
            }
        }
    }

    /// Red when a session on this task is calling for a person, blue while
    /// something is being dropped on it, and the ordinary line otherwise.
    private var borderColor: Color {
        if isTargeted { return AuspexPalette.stateThinking.opacity(0.7) }
        if let notice = row.callingNotice { return NoticeStyle.color(notice.kind).opacity(0.55) }
        return AuspexPalette.line
    }

    private func select(_ key: SessionKey) {
        board.selectedKey = key
        board.focusProject(of: key)
    }
}

// MARK: - What is not on the board

/// The live sessions no task claims.
///
/// Not hidden, and not silently folded into a lane. Half the value of this
/// page is knowing what is running *outside* the work somebody wrote down — an
/// agent nobody registered is the thing most likely to be duplicating
/// somebody else's work — so it gets a heading of its own and a way to file
/// each one.
private struct UnregisteredSessionsSection: View {
    let model: TasksModel
    let board: LiveBoardModel

    var body: some View {
        let linked = Set(
            model.lanes
                .flatMap(\.tasks)
                .flatMap(\.sessions)
                .map(\.key)
        )
        let rows = board.rowGroups
            .flatMap(\.rows)
            .filter { !linked.contains($0.key) && !$0.isEnded }

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Not on the board")
                        .auspexLabel(AuspexType.labelLarge)
                        .foregroundStyle(AuspexPalette.text3)
                    Text("\(rows.count)")
                        .font(AuspexType.monoCount)
                        .auspexTabularDigits()
                        .foregroundStyle(AuspexPalette.text3)
                    Spacer(minLength: 4)
                    Text("Drag one onto a task, or use “Link to task…” on its card.")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                FlowLayout(spacing: 6) {
                    ForEach(rows) { row in
                        UnregisteredSessionChip(row: row, board: board)
                    }
                }
            }
            .padding(14)
            .panelChrome()
        }
    }
}

private struct UnregisteredSessionChip: View {
    let row: BoardRow
    let board: LiveBoardModel

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        Button {
            board.selectedKey = row.key
            board.focusProject(of: row.key)
        } label: {
            HStack(spacing: 6) {
                StateDot(color: row.state.style.color, glows: !row.isEnded)
                HarnessBadge(harness: row.harness, size: 14)
                Text(row.title)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AuspexPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .modifier(
            TaskDragSource(isEnabled: !isSnapshotRender, payload: TaskDragPayload.session(row.key))
        )
    }
}

// MARK: - Empty

private struct TasksEmptyState: View {
    var body: some View {
        EmptyStateView(
            symbol: "checklist",
            title: "Nothing is filed yet.",
            detail: "An agent with Auspex's MCP server installed files a task in whatever "
                + "project it is working in — install it from the Harnesses page."
        )
        .centredInPane()
    }
}

// MARK: - Drag payloads

/// What a drag carries, as one plain string.
///
/// A string rather than a custom `Transferable`: the two things this page
/// drags are an integer and a session key, both of which already have a
/// canonical text form, and a bespoke UTI would buy nothing but a registration
/// step. The prefixes are what keep a task from being dropped where a session
/// belongs — an unrecognised payload is declined rather than guessed at.
enum TaskDragPayload {
    static let taskPrefix = "auspex.task:"
    static let sessionPrefix = "auspex.session:"

    static func task(_ id: Int64) -> String { "\(taskPrefix)\(id)" }
    static func session(_ key: SessionKey) -> String { "\(sessionPrefix)\(key.description)" }

    static func taskID(in payload: String) -> Int64? {
        guard payload.hasPrefix(taskPrefix) else { return nil }
        return Int64(payload.dropFirst(taskPrefix.count))
    }

    static func sessionKey(in payload: String) -> SessionKey? {
        guard payload.hasPrefix(sessionPrefix) else { return nil }
        return SessionKey(string: String(payload.dropFirst(sessionPrefix.count)))
    }
}

// MARK: - Linking from a card

/// "Link to task…" — the menu that files a session onto a piece of work.
///
/// A menu rather than only a drag, because a drag is the wrong gesture for a
/// card that is not on the same screen as the task: the wall and the Tasks page
/// are two destinations, and a person on the wall should not have to navigate
/// to somewhere they can see both.
///
/// The projects are the submenus, so a task's name is read next to the project
/// that gives it meaning. Anything already linked is dropped from the list: an
/// item that does nothing is a menu telling somebody a lie about what happens
/// next.
struct LinkToTaskMenu: View {
    let key: SessionKey
    let tasks: TasksModel

    var body: some View {
        let lanes = tasks.lanes.filter { !$0.isEmpty }
        if lanes.isEmpty {
            Button("Link to task…") {}
                .disabled(true)
                .help("Nothing is filed yet. File a task on the Tasks page.")
        } else {
            Menu("Link to task…") {
                ForEach(lanes) { lane in
                    let available = lane.tasks.filter { row in
                        !row.sessions.contains { $0.key == key }
                    }
                    if !available.isEmpty {
                        Menu(lane.title) {
                            ForEach(available) { row in
                                Button(row.task.title) {
                                    tasks.link(session: key, to: row.task.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}


/// A drag source that can be switched off — see ``TaskDropTarget``.
private struct TaskDragSource: ViewModifier {
    let isEnabled: Bool
    let payload: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(payload)
        } else {
            content
        }
    }
}
