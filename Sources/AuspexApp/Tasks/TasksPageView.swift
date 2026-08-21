import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The Tasks page: plans, the tasks under them, and the live sessions on each.
///
/// ## Why a board rather than a list
///
/// The question this page answers is *which of the things I handed out is
/// moving, and which is stuck*. A list sorted by anything answers it badly,
/// because "stuck" is not a property of one row — it is the shape of the
/// column that row is in. Four columns and a glance is the whole interaction.
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

    /// The width of one column. Four of them plus the gaps fit the content
    /// column at its default width, which is what keeps the whole plan
    /// readable without a horizontal scroll.
    static let columnWidth: CGFloat = 176

    @State private var isAddingPlan = false
    @State private var draftPlan = ""

    var body: some View {
        BoardScroll {
            LazyVStack(alignment: .leading, spacing: 16) {
                planBar
                if model.isEmpty {
                    TasksEmptyState()
                } else {
                    ForEach(model.lanes) { lane in
                        PlanLaneView(lane: lane, model: model, board: board)
                    }
                    if let unfiled = model.unfiled {
                        PlanLaneView(lane: unfiled, model: model, board: board)
                    }
                }
                UnregisteredSessionsSection(model: model, board: board)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(BoardSurfaceBackground())
    }

    /// Registering a plan by hand, and the archive switch.
    ///
    /// In the page rather than only in the toolbar, because the toolbar of the
    /// content column is shared with the board and a control that appears and
    /// disappears there is a control nobody finds twice.
    @ViewBuilder
    private var planBar: some View {
        HStack(spacing: 8) {
            if isAddingPlan {
                TextField("What is the whole piece of work?", text: $draftPlan)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                    .onSubmit(commitPlan)
                Button("Register", action: commitPlan)
                    .buttonStyle(.auspex)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.stateThinking)
                    .disabled(draftPlan.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { isAddingPlan = false; draftPlan = "" }
                    .buttonStyle(.auspex)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.text3)
            } else {
                Button("New plan") { isAddingPlan = true }
                    .buttonStyle(.auspex)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.text2)
                Spacer(minLength: 8)
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
                .help("Show plans that have been filed away")
            }
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

    private func commitPlan() {
        model.createPlan(title: draftPlan)
        draftPlan = ""
        isAddingPlan = false
    }

}

// MARK: - One plan

/// A plan and its four columns.
private struct PlanLaneView: View {
    let lane: TasksModel.TaskLane
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isAddingTask = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
                    TaskColumnView(
                        status: status,
                        rows: lane.column(status),
                        model: model,
                        board: board
                    )
                }
            }
            if isAddingTask { newTaskField }
        }
        .padding(14)
        .panelChrome()
        .opacity(lane.isArchived ? 0.6 : 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(lane.title)
                        .font(AuspexType.cardTitle)
                        .foregroundStyle(AuspexPalette.text)
                    if let plan = lane.plan {
                        Text(plan.slug)
                            .font(AuspexType.monoSmall)
                            .foregroundStyle(AuspexPalette.text3)
                            .textSelection(.enabled)
                    }
                    if lane.isArchived {
                        Text("archived")
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                }
                if let summary = lane.summary {
                    Text(summary)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Text(lane.openCount == 1 ? "1 open" : "\(lane.openCount) open")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
            Button {
                isAddingTask.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .foregroundStyle(AuspexPalette.text3)
            .help("File a task under this plan")
            if let plan = lane.plan, !lane.isArchived {
                Button { model.archivePlan(id: plan.id) } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.auspex)
                .foregroundStyle(AuspexPalette.text3)
                .help("File this plan away. Its tasks stay where they are.")
            }
        }
    }

    private var newTaskField: some View {
        HStack(spacing: 8) {
            TextField("What has to be done", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(AuspexType.body)
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
        model.createTask(title: draftTitle, planID: lane.plan?.id)
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
                Text("—")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.line2)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: TasksPageView.columnWidth, alignment: .leading)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? AuspexPalette.selection : AuspexPalette.bg1.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isTargeted ? AuspexPalette.stateThinking.opacity(0.6) : AuspexPalette.line,
                    lineWidth: 1
                )
        )
        // A column takes tasks. Sessions are dropped on *tasks*, not on
        // columns: "this session is working on that piece of work" is a fact
        // about one task, and a column has no id to attach it to.
        .modifier(TaskDropTarget(isEnabled: !isSnapshotRender, isTargeted: $isTargeted) { items in
            guard let id = items.compactMap(TaskDragPayload.taskID(in:)).first else { return false }
            model.move(taskID: id, to: status)
            return true
        })
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
            Text(row.task.title)
                .font(AuspexType.rowTitle)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

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

            if let result = row.task.result, row.task.status == .done {
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
        .modifier(TaskDragSource(isEnabled: !isSnapshotRender, payload: TaskDragPayload.task(row.task.id)))
        // A session card dropped here is linked to this task. The same
        // relationship `tasks.claim` records, made by hand.
        .modifier(TaskDropTarget(isEnabled: !isSnapshotRender, isTargeted: $isTargeted) { items in
            guard let key = items.compactMap(TaskDragPayload.sessionKey(in:)).first
            else { return false }
            model.link(session: key, to: row.task.id)
            return true
        })
        .contextMenu {
            ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
                Button("Move to \(status.label)") { model.move(taskID: row.task.id, to: status) }
                    .disabled(status == row.task.status)
            }
            if !row.sessions.isEmpty {
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
/// page is knowing what is running *outside* the plan — an agent nobody
/// registered is the thing most likely to be duplicating somebody else's work
/// — so it gets a heading of its own and a way to file each one.
private struct UnregisteredSessionsSection: View {
    let model: TasksModel
    let board: LiveBoardModel

    var body: some View {
        let linked = Set(
            (model.lanes + [model.unfiled].compactMap { $0 })
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing is filed yet.")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)
            Text(
                "A plan is registered by whoever hands work out — a supervisor "
                    + "splitting a job, or you. Agents that have Auspex's MCP server "
                    + "installed can register one with plans.create, file a task per "
                    + "worker, and put the task id in each brief; the worker then makes "
                    + "one tasks.claim call and its session appears on the row."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)
            Text("Install the server from the Harnesses page.")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(20)
        .panelChrome()
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
/// The plans are the submenus, so a task's name is read next to the plan that
/// gives it meaning. Anything already linked is dropped from the list: an item
/// that does nothing is a menu telling somebody a lie about what happens next.
struct LinkToTaskMenu: View {
    let key: SessionKey
    let tasks: TasksModel

    var body: some View {
        let lanes = (tasks.lanes + [tasks.unfiled].compactMap { $0 })
            .filter { !$0.isArchived }
        if lanes.isEmpty {
            Button("Link to task…") {}
                .disabled(true)
                .help("Nothing is filed yet. Register a plan on the Tasks page.")
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
