import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The Tasks page: which project, what is being done in it, where it is
/// stuck, and what is waiting for the person to accept.
///
/// ## One lane per project
///
/// Everything else in this app divides by project — the wall's sections, the
/// sidebar's tree, the scene's floor plates — so the page does too, and it
/// does nothing else: a lane is a project, its columns are the statuses that
/// have something in them, and a milestone is a line of chips under the
/// lane's title and a tag on each card. The page it replaced drew a full-width
/// band per milestone with five columns under each, most of them empty, and
/// on a ledger of a few hundred tasks that was more empty boxes than cards.
///
/// ## Explicit tasks only
///
/// A session's own work that nobody filed is on Now and the Sessions page.
/// This page is the ledger: what somebody handed out.
///
/// ## Cost
///
/// Nothing on this page derives anything. ``TasksModel`` builds every lane,
/// column and card once, as flat values compared by revision; the lanes sit
/// in a lazy stack and every column draws at most eight cards until it is
/// opened. A card's body reads its value and nothing else — in particular,
/// nothing observable, so a frame that moved one task redraws one card.
struct TasksPageView: View {
    let model: TasksModel
    let board: LiveBoardModel

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        let page = model.page
        BoardScroll(autoScrolls: true) {
            LanesStack(isLazy: !isSnapshotRender) {
                pageBar(page)
                if model.isEmpty {
                    TasksEmptyState()
                } else if page.lanes.isEmpty {
                    EmptyStateView(
                        title: L10n.Trace.nothingInView,
                        detail: L10n.Tasks.scopeEmptyDetail
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(page.lanes) { lane in
                        ProjectLaneView(lane: lane, model: model, board: board)
                            .equatable()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(BoardSurfaceBackground())
        // One confirmation for every bulk close on the page — a Review
        // column's "Close all" and the bar's "Close all old reviews". A sheet
        // with no default action, like the kill confirmation: Return must not
        // close a hundred tasks.
        .sheet(item: pendingClose) { request in
            BulkCloseSheet(
                count: request.ids.count,
                onConfirm: { model.confirmPendingClose() },
                onCancel: { model.pendingClose = nil }
            )
            .auspexNoInitialFocus()
        }
    }

    private var pendingClose: Binding<TasksModel.BulkClose?> {
        Binding(
            get: { model.pendingClose },
            set: { if $0 == nil { model.pendingClose = nil } }
        )
    }

    // MARK: The bar

    /// What the page is showing, the chips that choose it, and the page-wide
    /// actions. One panel, in the page rather than the toolbar, because the
    /// toolbar is shared with the board and a control that comes and goes
    /// there is one nobody finds twice.
    private func pageBar(_ page: TaskLaneBoard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.Tasks.summary(
                    projects: L10n.Tasks.Summary.projects(count: page.projectCount),
                    tasks: L10n.Projects.tasksOpen(count: page.openCount)
                ))
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                Spacer(minLength: 8)
                if board.reviewCount > 0 {
                    BarButton(
                        title: L10n.Tasks.reviewNext(count: board.reviewCount),
                        symbol: "checklist",
                        tint: AuspexPalette.stateWriting,
                        help: L10n.Tasks.reviewNextHelp
                    ) { board.openNextReview() }
                }
                if !page.oldReviewIDs.isEmpty {
                    BarButton(
                        title: L10n.Tasks.closeOldReviews(count: page.oldReviewIDs.count),
                        symbol: "tray.full",
                        tint: AuspexPalette.text2,
                        help: L10n.Tasks.oldReviewsHelp
                    ) { model.pendingClose = TasksModel.BulkClose(ids: page.oldReviewIDs) }
                }
                if page.staleCount > 0 || model.showsStale {
                    ToggleChip(
                        title: model.showsStale
                            ? L10n.Tasks.hideStale : L10n.Tasks.showStale(count: page.staleCount),
                        isOn: model.showsStale,
                        help: L10n.Tasks.staleToggleHelp
                    ) { model.showsStale.toggle() }
                }
                ToggleChip(
                    title: model.showsArchived ? L10n.Tasks.hideArchived : L10n.Tasks.showArchived,
                    isOn: model.showsArchived,
                    help: L10n.Tasks.archivedHelp
                ) { model.showsArchived.toggle() }
            }
            ScopeChips(scope: model.scope, counts: page.scopeCounts, model: model)
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
}

/// A lazy stack on screen, an eager one in an offscreen render.
///
/// `ImageRenderer` has no scroll view to be lazy inside, and a picture of the
/// page has to contain the lanes it is a picture of.
private struct LanesStack<Content: View>: View {
    let isLazy: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 14) { content }
        } else {
            VStack(alignment: .leading, spacing: 14) { content }
        }
    }
}

/// The four scope chips and All.
private struct ScopeChips: View {
    let scope: TaskScopeSelection
    let counts: TaskLaneBoard.ScopeCounts
    let model: TasksModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TaskScope.allCases, id: \.self) { item in
                ToggleChip(
                    title: Self.title(item, count: counts.count(item)),
                    isOn: scope.contains(item),
                    tint: Self.tint(item),
                    help: L10n.Tasks.Scope.help
                ) { model.toggle(item) }
            }
            ToggleChip(
                title: L10n.Common.all,
                isOn: scope.isAll,
                help: L10n.Tasks.Scope.help
            ) { model.showEverything() }
            Spacer(minLength: 0)
        }
    }

    private static func title(_ scope: TaskScope, count: Int) -> String {
        switch scope {
        case .review: L10n.Tasks.Scope.review(count: count)
        case .blocked: L10n.Tasks.Scope.blocked(count: count)
        case .inProgress: L10n.Tasks.Scope.inProgress(count: count)
        case .unclaimed: L10n.Tasks.Scope.unclaimed(count: count)
        }
    }

    private static func tint(_ scope: TaskScope) -> Color {
        switch scope {
        case .review: AuspexPalette.stateWriting
        case .blocked: AuspexPalette.statePermission
        case .inProgress: AuspexPalette.stateThinking
        case .unclaimed: AuspexPalette.text2
        }
    }
}

/// A pill that is a switch.
private struct ToggleChip: View {
    let title: String
    let isOn: Bool
    var tint: Color = AuspexPalette.text
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AuspexType.pill)
                .auspexTabularDigits()
                .foregroundStyle(isOn ? tint : AuspexPalette.text3)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? AuspexPalette.selection : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? tint.opacity(0.35) : AuspexPalette.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 6))
        .help(help)
    }
}

/// A tinted action in the page bar.
private struct BarButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(AuspexType.pill).auspexTabularDigits()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 6))
        .help(help)
    }
}

// MARK: - One project

/// One project: its header, its milestone line, and its non-empty columns.
///
/// Equatable on the lane alone, so SwiftUI skips the body of every lane whose
/// revision did not move.
private struct ProjectLaneView: View, Equatable {
    let lane: TaskLane
    let model: TasksModel
    let board: LiveBoardModel

    @State private var draft: Draft?
    @State private var draftText = ""

    private enum Draft { case task, milestone }

    nonisolated static func == (lhs: ProjectLaneView, rhs: ProjectLaneView) -> Bool {
        lhs.lane == rhs.lane
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let draft { field(for: draft) }
            if !lane.isCollapsed {
                if !lane.milestones.isEmpty || lane.archivedMilestoneCount > 0 {
                    milestoneLine
                }
                if lane.columns.isEmpty {
                    EmptyStateView(
                        title: L10n.Tasks.nothingToDo,
                        detail: L10n.Tasks.nothingFiledInProject
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(lane.columns) { column in
                            TaskColumnView(column: column, laneKey: lane.key, model: model, board: board)
                                .equatable()
                        }
                    }
                }
            }
        }
        .padding(14)
        .panelChrome()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggleLane(lane.key) } label: {
                Image(systemName: lane.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help(lane.isCollapsed ? L10n.Tasks.Lane.unfold : L10n.Tasks.Lane.fold)

            if let harness = lane.harness {
                HarnessBadge(harness: harness, size: 15)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            Text(CoreVocabulary.localized(lane.title))
                .font(AuspexType.cardTitle)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(1)
            if let subtitle = lane.subtitle {
                Text(subtitle)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            LaneCounts(counts: lane.counts)
            Button { toggleDraft(.task) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .foregroundStyle(AuspexPalette.text3)
            .help(L10n.Tasks.fileInProject)
            Button { toggleDraft(.milestone) } label: {
                Text(L10n.Tasks.milestone)
                    .font(AuspexType.pill)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .foregroundStyle(AuspexPalette.text3)
            .help(L10n.Tasks.milestoneHelp)
        }
    }

    /// The lane's milestones as one line of chips: what used to be a band of
    /// five columns each. A chip narrows the lane to that milestone.
    private var milestoneLine: some View {
        FlowLayout(spacing: 6) {
            ForEach(lane.milestones) { milestone in
                let isOn = lane.milestoneFilter == milestone.id
                Button { model.toggleMilestone(milestone.id, inLane: lane.key) } label: {
                    Text("\(milestone.title) · \(milestone.openCount)")
                        .font(AuspexType.caption)
                        .foregroundStyle(isOn ? AuspexPalette.text : AuspexPalette.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isOn ? AuspexPalette.selection : AuspexPalette.bg2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.auspex(cornerRadius: 5))
                .help(L10n.Tasks.Lane.milestoneHelp)
            }
            if lane.archivedMilestoneCount > 0 {
                Text(L10n.Tasks.Lane.archivedMilestones(count: lane.archivedMilestoneCount))
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(height: 18)
            }
        }
    }

    private func field(for draft: Draft) -> some View {
        HStack(spacing: 8) {
            TextField(
                draft == .task ? L10n.Tasks.newTaskPlaceholder : L10n.Tasks.milestonePlaceholder,
                text: $draftText
            )
            .textFieldStyle(.plain)
            .font(AuspexType.body)
            .auspexSystemControlFocus()
            .onSubmit(commit)
            Button(draft == .task ? L10n.Common.add : L10n.Tasks.register, action: commit)
                .buttonStyle(.auspex)
                .font(AuspexType.pill)
                .foregroundStyle(AuspexPalette.stateThinking)
                .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(L10n.Common.cancel) { self.draft = nil; draftText = "" }
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

    private func toggleDraft(_ kind: Draft) {
        draft = draft == kind ? nil : kind
        draftText = ""
    }

    private func commit() {
        switch draft {
        case .task:
            model.createTask(title: draftText, projectKey: lane.key, planID: lane.milestoneFilter)
        case .milestone:
            model.createMilestone(title: draftText, projectKey: lane.key)
        case nil:
            break
        }
        draftText = ""
        draft = nil
    }
}

/// "1 blocked · 5 to review · 2 doing · 3 unclaimed", only the parts that are
/// not zero.
private struct LaneCounts: View {
    let counts: TaskLane.Counts

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").font(AuspexType.monoCount).foregroundStyle(AuspexPalette.text3)
                }
                Text(part.text)
                    .font(AuspexType.monoCount)
                    .auspexTabularDigits()
                    .foregroundStyle(part.color)
                    .fixedSize()
            }
        }
    }

    private var parts: [(text: String, color: Color)] {
        var parts: [(text: String, color: Color)] = []
        if counts.blocked > 0 {
            parts.append((L10n.Tasks.Lane.blocked(count: counts.blocked), AuspexPalette.statePermission))
        }
        if counts.review > 0 {
            parts.append((L10n.Tasks.Lane.review(count: counts.review), AuspexPalette.stateWriting))
        }
        if counts.doing > 0 {
            parts.append((L10n.Tasks.Lane.doing(count: counts.doing), AuspexPalette.stateThinking))
        }
        if counts.unclaimed > 0 {
            parts.append((L10n.Tasks.Lane.unclaimed(count: counts.unclaimed), AuspexPalette.text3))
        }
        return parts
    }
}

// MARK: - One column

/// One status column, and the target a dragged task lands on.
private struct TaskColumnView: View, Equatable {
    let column: TaskLaneColumn
    let laneKey: String
    let model: TasksModel
    let board: LiveBoardModel

    @State private var isTargeted = false
    // `ImageRenderer` cannot draw a view carrying a drop interaction and
    // substitutes a placeholder for it, which would put a yellow box over every
    // column of every screenshot. The offscreen renderer has nothing to drop on
    // anyway.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    nonisolated static func == (lhs: TaskColumnView, rhs: TaskColumnView) -> Bool {
        lhs.column == rhs.column
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(column.status.localizedLabel)
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                Text("\(column.total)")
                    .font(AuspexType.monoCount)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
                Spacer(minLength: 2)
                if !column.closableIDs.isEmpty {
                    Button {
                        model.pendingClose = TasksModel.BulkClose(ids: column.closableIDs)
                    } label: {
                        Text(L10n.Tasks.Column.closeAll(count: column.closableIDs.count))
                            .font(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.stateWriting)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auspex)
                    .help(L10n.Tasks.Column.closeAllHelp)
                }
            }
            .padding(.horizontal, 2)

            ForEach(column.cards) { card in
                TaskCardView(card: card, model: model, board: board).equatable()
            }
            if column.hiddenCount > 0 {
                FoldButton(title: L10n.Projects.Fold.more(count: column.hiddenCount)) {
                    model.toggleColumn(column.id)
                }
            } else if column.isExpanded {
                FoldButton(title: L10n.Projects.Fold.showFewer) {
                    model.toggleColumn(column.id)
                }
            }
            if !column.oldReviews.isEmpty {
                Button { model.toggleOldReviews(laneKey) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: column.showsOldReviews ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(L10n.Tasks.oldReviews(count: column.oldReviews.count))
                            .font(AuspexType.labelSmall)
                            .auspexTabularDigits()
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.horizontal, 4)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.auspex)
                .help(L10n.Tasks.oldReviewsHelp)
                if column.showsOldReviews {
                    ForEach(column.oldReviews) { card in
                        TaskCardView(card: card, model: model, board: board).equatable()
                    }
                }
            }
        }
        .frame(minWidth: 132, maxWidth: .infinity, alignment: .topLeading)
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
        .contentShape(Rectangle())
        // A column takes tasks. Sessions are dropped on *tasks*, not on
        // columns: "this session is working on that piece of work" is a fact
        // about one task, and a column has no id to attach it to.
        .modifier(TaskDropTarget(isEnabled: !isSnapshotRender, isTargeted: $isTargeted) { items in
            guard let id = items.compactMap(TaskDragPayload.taskID(in:)).first else { return false }
            model.move(taskID: id, to: column.status)
            return true
        })
    }
}

/// "Close 12 tasks?" — an explicit two-action confirmation with no implicit
/// default action, the shape `KillConfirmation` set: Escape cancels, and
/// Return does nothing until focus has moved to a button on purpose.
private struct BulkCloseSheet: View {
    let count: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Tasks.ConfirmClose.title(count: count))
                .font(AuspexType.paneTitle)
                .foregroundStyle(AuspexPalette.text)
            Text(L10n.Tasks.ConfirmClose.detail)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.Common.cancel, role: .cancel, action: onCancel)
                    .buttonStyle(.auspex)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.Common.close, role: .destructive, action: onConfirm)
                    .buttonStyle(.auspex)
                    .foregroundStyle(AuspexPalette.stateWriting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(AuspexPalette.canvas)
        .auspexControlFocus()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Tasks.ConfirmClose.title(count: count))
    }
}

/// "+3 more" and "Show fewer" under a column.
private struct FoldButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AuspexType.labelSmall)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
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

/// One task: what it is, who has it, what they last did, and how long ago.
///
/// Everything it draws is on ``card``. It reads nothing observable, so the
/// only thing that redraws it is a new revision of its own value.
private struct TaskCardView: View, Equatable {
    let card: TaskLaneCard
    let model: TasksModel
    let board: LiveBoardModel

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    nonisolated static func == (lhs: TaskCardView, rhs: TaskCardView) -> Bool {
        lhs.card == rhs.card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                TaskStatusIcon(status: card.status, size: 12).padding(.top, 1)
                Text(card.title)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if card.importance.isMarked {
                    TaskImportanceIcon(importance: card.importance, size: 11).padding(.top, 1)
                }
            }

            HStack(spacing: 5) {
                Text(card.shortID)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
                if let milestone = card.milestone {
                    Text(milestone.title)
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AuspexPalette.bg1)
                        )
                        .opacity(milestone.isArchived ? 0.6 : 1)
                }
                if card.isStale {
                    Text(L10n.Tasks.Card.stale)
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.horizontal, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(AuspexPalette.line, lineWidth: 1)
                        )
                        .fixedSize()
                        .help(L10n.Tasks.staleHelp)
                }
                Spacer(minLength: 0)
                if card.subagentCount > 0 {
                    Text("↳ \(card.subagentCount)")
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.stateDelegating)
                        .fixedSize()
                }
            }

            if let notice = card.notice {
                HStack(spacing: 5) {
                    NoticePill(kind: notice.kind, isCompact: true)
                    Text(notice.message)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if card.isOrphaned {
                Text(L10n.Task.Filter.claimOrphaned)
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.stateStale)
                    .help(L10n.Tasks.orphanHelp)
            }

            if let claimer = card.claimer {
                Button { jump(to: claimer.session) } label: {
                    HStack(spacing: 5) {
                        StateDot(
                            color: claimer.state?.style.color ?? AuspexPalette.stateEnded,
                            glows: claimer.isLive && claimer.state?.isActive == true
                        )
                        HarnessBadge(harness: claimer.harness, size: 13)
                        Text(claimer.title)
                            .font(AuspexType.caption)
                            .foregroundStyle(claimer.isLive ? AuspexPalette.text2 : AuspexPalette.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.auspex)
                .help(L10n.Tasks.Card.claimerHelp)
            }

            if let detail = card.detail {
                Text(detail)
                    .font(AuspexType.caption)
                    .foregroundStyle(
                        card.detailIsResult
                            ? AuspexPalette.stateWriting.opacity(0.85) : AuspexPalette.text3
                    )
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(card.age)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
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
        // Nobody has it: quieter, so the work somebody is doing reads first.
        .opacity(card.isUnclaimed && card.status == .todo ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        // Dragged between columns. Not a drop target itself: a drop target is
        // a platform view, one per card is hundreds of them, and the one thing
        // it took — a session dragged from the "not on the board" strip — is
        // not on this page any more. "Link to task…" on a session's card does
        // the same from where the session is.
        .modifier(TaskDragSource(isEnabled: !isSnapshotRender, payload: TaskDragPayload.task(card.id)))
        .contextMenu { TaskLaneCardMenu(card: card, model: model) }
    }

    private var borderColor: Color {
        if let notice = card.notice { return NoticeStyle.color(notice.kind).opacity(0.55) }
        return AuspexPalette.line
    }

    /// The task's own page — the one the wall opens — when the board holds
    /// the task. A stale task is not on the board, and opens nothing.
    private func open() {
        guard board.unit(withID: card.unitID) != nil else { return }
        board.openUnitID = card.unitID
    }

    /// The claimer's session, on Now.
    private func jump(to key: SessionKey) {
        board.selectedKey = key
        board.focusProject(of: key)
        board.requestedSection = .live
    }
}

/// A card's right-click menu. Its own view, so the one value it reads that
/// can change — the projects to re-file into — is its own dependency rather
/// than every card's.
private struct TaskLaneCardMenu: View {
    let card: TaskLaneCard
    let model: TasksModel

    var body: some View {
        if card.ledgerStatus == .review {
            Button(L10n.Common.close) { model.close(taskID: card.id) }
        } else if card.ledgerStatus == .done {
            Button(L10n.Task.Menu.reopen) { model.reopen(taskID: card.id) }
        }
        if card.isStale {
            Button(L10n.Tasks.Menu.keep) { model.keep(taskID: card.id) }
        }
        if card.isOrphaned {
            Button(L10n.Task.Menu.releaseClaim) { model.releaseClaim(taskID: card.id) }
        }
        Divider()
        ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
            Button(L10n.Tasks.moveTo(status: status.localizedLabel)) {
                model.move(taskID: card.id, to: status)
            }
            .disabled(status == card.ledgerStatus)
        }
        // Re-filing by hand, which is what makes the scratch project a place
        // work passes through rather than a place it goes to die.
        let elsewhere = model.projectChoices
        if elsewhere.count > 1 {
            Divider()
            Menu(L10n.Tasks.fileUnder) {
                ForEach(elsewhere) { choice in
                    Button(choice.title) {
                        model.move(taskID: card.id, toProjectKey: choice.key)
                    }
                }
            }
        }
    }
}

// MARK: - Empty

private struct TasksEmptyState: View {
    var body: some View {
        EmptyStateView(
            symbol: "checklist",
            title: L10n.Tasks.nothingFiled,
            detail: L10n.Tasks.nothingFiledDetail
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
/// next. Read from the ledger, not from the Tasks page, so it is right whether
/// or not that page has been opened.
struct LinkToTaskMenu: View {
    let key: SessionKey
    let tasks: TasksModel

    var body: some View {
        let projects = tasks.linkTargets
        if projects.isEmpty {
            Button(L10n.Tasks.linkToTask) {}
                .disabled(true)
                .help(L10n.Tasks.linkDisabledHelp)
        } else {
            Menu(L10n.Tasks.linkToTask) {
                ForEach(projects) { project in
                    let available = project.tasks.filter { !$0.sessions.contains(key) }
                    if !available.isEmpty {
                        Menu(CoreVocabulary.localized(project.title)) {
                            ForEach(available) { task in
                                Button(task.title) {
                                    tasks.link(session: key, to: task.id)
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
