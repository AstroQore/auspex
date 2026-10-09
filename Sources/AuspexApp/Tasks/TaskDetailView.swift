import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// One piece of work, at length.
///
/// ## What this page is for
///
/// The wall answers *what is happening*. This answers *what happened*, which
/// is a different question and the one a person asks when they are about to
/// close something: who took it, what they said along the way, what evidence
/// they left, what it is waiting on, and what every session on it did.
///
/// It is deliberately not a second board. Nothing here is a live tile — the
/// only moving parts are the member rows' state dots and the freshness clocks
/// — because a page somebody is reading should not reflow under them.
///
/// ## Two kinds of task on one page
///
/// A unit the board *derived* has no row in the ledger, so it has no history,
/// no notes and no dependencies to show. It gets the same page with those
/// sections absent and one button in their place, which is the honest picture:
/// this is a real piece of work, and nobody has written it down yet.
struct TaskDetailView: View {
    let unit: TaskUnit
    @Bindable var board: LiveBoardModel
    let tasks: TasksModel

    @Environment(AppEnvironment.self) private var environment
    @State private var draftNote = ""
    @State private var draftRef = ""
    @State private var noteKind = TaskNoteKind.note
    @State private var delivery = TaskDeliveryModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            BoardScroll {
                VStack(alignment: .leading, spacing: 22) {
                    title
                    if let body = unit.body { bodyText(body) }
                    if unit.isInReview, let result = unit.result { reviewBox(result) }
                    TaskDeliverySection(unit: unit, board: board, model: delivery)
                    if unit.isInReview { TaskReviewRecordSection(log: tasks.openLog) }
                    TaskHandoffSection(
                        unit: unit, board: board, log: tasks.openLog, delivery: delivery
                    )
                    properties
                    if !unit.waitingOn.isEmpty || !unit.dependsOn.isEmpty { dependencies }
                    if let taskID = unit.origin.taskID,
                       let message = tasks.takeoverResolutionMessage(taskID: taskID) {
                        Text(message)
                            .font(AuspexType.body)
                            .foregroundStyle(AuspexPalette.statePermission)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panelChrome()
                    }
                    if !pendingTakeovers.isEmpty { takeoverRequests }
                    members
                    if unit.origin.taskID != nil {
                        notes
                    } else {
                        promotion
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .background(BoardSurfaceBackground())
        // The page has a fact on it that copies, so it has to be able to say
        // so — see ``CopyToast``.
        .auspexCopyToast()
        .task(id: unit.id) {
            tasks.loadLog(taskID: unit.origin.taskID)
            await delivery.load(unit: unit, board: board)
        }
    }

    // MARK: Header

    /// Back, where you are, and the actions.
    ///
    /// The crumb reads `Tasks › AUX-3f9k` rather than repeating the title,
    /// which is the first thing under it in twenty-two point type.
    private var header: some View {
        HStack(spacing: 10) {
            Button { board.openUnitID = nil } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text(BoardViewMode.board.localizedTitle).font(AuspexType.caption)
                }
                .foregroundStyle(AuspexPalette.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help(L10n.TaskDetail.backHelp)
            Text("›")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            // The handle a person pastes into a message, a `tasks.get`, or a
            // brief for the next agent. It is the one fact on this page whose
            // whole purpose is to be taken somewhere else, so it copies when
            // it is clicked — the same rule the trace header follows.
            CopyFact(
                text: unit.shortID,
                what: L10n.Copy.What.taskHandle,
                font: AuspexType.monoCount
            )
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 20)
        .frame(height: BoardHeader.height)
        .background(AuspexPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if unit.isInReview {
            let previous = board.reviewNeighbor(of: unit, direction: .previous)
            let next = board.reviewNeighbor(of: unit, direction: .next)
            reviewNavigationButton("chevron.left", help: L10n.TaskDetail.previousReview) {
                board.openUnitID = previous?.id
            }
            .disabled(previous == nil)
            reviewNavigationButton("chevron.right", help: L10n.TaskDetail.nextReview) {
                board.openUnitID = next?.id
            }
            .disabled(next == nil)
            actionButton(L10n.TaskDetail.defer) { board.deferReview(unit) }
            actionButton(L10n.Task.Menu.reopen, tint: AuspexPalette.stateStale) {
                let replacement = board.reviewReplacement(after: unit)
                tasks.reopen(unit: unit)
                board.openUnitID = replacement?.id
            }
            actionButton(L10n.Common.close, tint: AuspexPalette.stateWriting) {
                let replacement = board.reviewReplacement(after: unit)
                tasks.close(unit: unit)
                board.openUnitID = replacement?.id
            }
        } else if unit.status == .done {
            actionButton(L10n.Task.Menu.reopen) {
                tasks.reopen(unit: unit)
            }
        }
        if unit.isClaimOrphaned, let id = unit.origin.taskID {
            actionButton(L10n.Task.Menu.releaseClaim, tint: AuspexPalette.stateStale) {
                tasks.releaseClaim(taskID: id)
            }
        }
        // Review already has five compact controls in this bar. A member row
        // below still opens Flight in one click, so duplicating it here would
        // make the minimum-width task page overflow for no added capability.
        if unit.counts.live > 0, !unit.isInReview {
            actionButton(L10n.TaskDetail.openFlight) {
                board.selectedKey = unit.lead.key
                board.openUnitID = nil
                board.openTrajectory()
            }
        }
    }

    private func reviewNavigationButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuspexPalette.text2)
                .frame(width: 24, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 7))
        .help(help)
    }

    private func actionButton(
        _ label: String,
        tint: Color = AuspexPalette.text2,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(AuspexType.caption)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 7))
    }

    // MARK: Body

    private var title: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TaskStatusIcon(status: unit.status, size: 18)
                    .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
                Text(unit.title)
                    .font(AuspexType.display)
                    .foregroundStyle(AuspexPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            TaskChips(unit: unit)
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the worker said it finished, which is the whole of what a reviewer
    /// is here to read.
    private func reviewBox(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.TaskDetail.agentReport)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.stateWriting)
            Text(result)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AuspexPalette.stateWriting.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(AuspexPalette.stateWriting.opacity(0.25), lineWidth: 1)
        )
    }

    /// The facts, as a two-column list rather than as a row of chips: this is
    /// a page and the reader is looking one of them up.
    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            property(L10n.Common.status, unit.status.localizedLabel)
            if let version = unit.version { property(L10n.TaskDetail.version, "v\(version)") }
            property(L10n.Task.Filter.importance, unit.importance.localizedLabel)
            if let kind = unit.kind { property(L10n.TaskDetail.kind, kind.localizedLabel) }
            if let key = unit.projectKey {
                property(L10n.Common.project, TaskProject.displayName(forKey: key, in: board.board))
            }
            if let milestone = unit.planTitle { property(L10n.Tasks.milestone, milestone) }
            if let claim = unit.claim {
                property(L10n.TaskDetail.claimedBy, claim.description ?? claim.harness.displayName)
            }
            if !unit.labels.isEmpty {
                property(L10n.TaskDetail.labels, unit.labels.joined(separator: ", "))
            }
            if let created = unit.createdAt {
                property(L10n.TaskDetail.filed, RelativeTimeText.since(created))
            }
        }
        .panelChrome()
    }

    private var pendingTakeovers: [TaskClaimRequest] {
        guard let taskID = unit.origin.taskID else { return [] }
        return tasks.pendingClaims(taskID: taskID)
    }

    /// Claim conflicts wait here for a person. Releasing the current holder
    /// does not auto-promote anybody; the same explicit decision remains.
    private var takeoverRequests: some View {
        section(
            L10n.TaskDetail.takeoverRequests(count: pendingTakeovers.count)
        ) {
            VStack(spacing: 0) {
                ForEach(pendingTakeovers) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            HarnessBadge(harness: request.requester.harness, size: 16)
                            Text(request.requester.harness.displayName)
                                .font(AuspexType.body)
                                .foregroundStyle(AuspexPalette.text)
                            Text(String(request.requester.sessionID.prefix(8)))
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text3)
                            Text(request.role)
                                .font(AuspexType.caption)
                                .foregroundStyle(AuspexPalette.text2)
                            if let scope = request.scope {
                                Text("· \(scope)")
                                    .font(AuspexType.caption)
                                    .foregroundStyle(AuspexPalette.text3)
                            }
                            Spacer(minLength: 8)
                            Text(RelativeTimeText.since(request.requestedAt))
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text3)
                        }
                        if let reason = request.reason {
                            Text(reason)
                                .font(AuspexType.body)
                                .foregroundStyle(AuspexPalette.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Text(L10n.TaskDetail.requestedAt(version: Int(request.taskVersion)))
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text3)
                            Spacer(minLength: 8)
                            actionButton(L10n.TaskDetail.reject, tint: AuspexPalette.text3) {
                                tasks.resolveTakeover(requestID: request.id, approve: false)
                            }
                            actionButton(L10n.TaskDetail.approve, tint: AuspexPalette.stateWriting) {
                                tasks.resolveTakeover(requestID: request.id, approve: true)
                            }
                        }
                    }
                    .padding(12)
                    if request.id != pendingTakeovers.last?.id {
                        Divider().overlay(AuspexPalette.line)
                    }
                }
            }
            .panelChrome()
        }
    }

    private func property(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Dependencies

    /// What this task waits on.
    ///
    /// A strip and not a graph. The whole graph is worth a page of its own and
    /// this is not it — see ``TaskGraphStub`` — but "you cannot start this
    /// until AUX-… is closed" is one line and belongs where the decision is
    /// made.
    private var dependencies: some View {
        section(L10n.TaskDetail.waitsOn) {
            TaskGraphStub()
            if unit.waitingOn.isEmpty {
                Text(L10n.TaskDetail.ready)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.stateWriting)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(unit.waitingOn, id: \.id) { dependency in
                        Button {
                            board.openUnitID = "task:\(dependency.id)"
                        } label: {
                            HStack(spacing: 8) {
                                Text(dependency.shortID)
                                    .font(AuspexType.monoSmall)
                                    .foregroundStyle(AuspexPalette.stateStale)
                                Text(dependency.title)
                                    .font(AuspexType.body)
                                    .foregroundStyle(AuspexPalette.text2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.auspex(cornerRadius: 6))
                        .help(L10n.TaskDetail.openDependency(id: dependency.shortID))
                    }
                }
            }
        }
    }

    // MARK: Members

    /// Everybody on this task, and what each of them is doing.
    private var members: some View {
        section(L10n.TaskDetail.sessions(count: unit.memberCount)) {
            VStack(spacing: 0) {
                ForEach(unit.members, id: \.key) { row in
                    memberRow(row)
                    if row.key != unit.members.last?.key {
                        Divider().overlay(AuspexPalette.line)
                    }
                }
            }
            .panelChrome()
        }
    }

    private func memberRow(_ row: BoardRow) -> some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: row.harness, size: 18, isMuted: row.isEnded)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if row.key == unit.lead.key {
                        Text(L10n.Task.Card.lead)
                            .font(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                    Text(row.title)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text)
                        .lineLimit(1)
                }
                Text(PathDisplay.condense(row.activity, limit: 60))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(row.state.style.color.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FreshnessLabel(at: row.lastEventAt)
            Button {
                board.selectedKey = row.key
                board.openUnitID = nil
                board.openTrajectory()
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex(cornerRadius: 5))
            .help(L10n.TaskDetail.openSessionFlight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            board.selectedKey = row.key
            board.openUnitID = nil
        }
    }

    // MARK: Notes and history

    /// What was decided, what was checked, what is still at risk — and
    /// everything the ledger recorded about itself, in one column.
    ///
    /// One list rather than two, because a reader following a task's story
    /// wants "claimed, then decided this, then finished" in the order it
    /// happened. The *kind* is what tells the agent's sentences from the
    /// ledger's bookkeeping, and it is a coloured word rather than a separate
    /// section.
    private var notes: some View {
        section(L10n.TaskDetail.history) {
            VStack(alignment: .leading, spacing: 10) {
                if tasks.openLog.isEmpty {
                    Text(L10n.TaskDetail.nothingWritten)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(tasks.openLog) { entry in
                            TaskLogRow(entry: entry)
                            if entry.id != tasks.openLog.last?.id {
                                Divider().overlay(AuspexPalette.line)
                            }
                        }
                    }
                    .panelChrome()
                }
                noteComposer
            }
        }
    }

    /// A person's own line, with the same four kinds an agent gets.
    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(TaskNoteKind.allCases, id: \.self) { kind in
                    Button { noteKind = kind } label: {
                        Text(kind.localizedLabel)
                            .font(AuspexType.caption)
                            .foregroundStyle(
                                noteKind == kind
                                    ? TaskLogRow.colour(kind) : AuspexPalette.text3
                            )
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        noteKind == kind
                                            ? TaskLogRow.colour(kind).opacity(0.12) : .clear
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auspex(cornerRadius: 6))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                TextField(L10n.TaskDetail.writeItDown, text: $draftNote)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                    .auspexSystemControlFocus()
                TextField(L10n.TaskDetail.ref, text: $draftRef)
                    .textFieldStyle(.plain)
                    .font(AuspexType.monoSmall)
                    .frame(width: 96)
                    .auspexSystemControlFocus()
                Button(L10n.Common.add) { commitNote() }
                    .buttonStyle(.auspex)
                    .disabled(draftNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AuspexPalette.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            )
        }
    }

    private func commitNote() {
        guard let id = unit.origin.taskID else { return }
        tasks.log(
            taskID: id,
            kind: noteKind,
            message: draftNote,
            ref: draftRef.isEmpty ? nil : draftRef
        )
        draftNote = ""
        draftRef = ""
    }

    /// What a derived unit offers instead of a history.
    private var promotion: some View {
        section(L10n.TaskDetail.notFiled) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.TaskDetail.promoteNote(harness: unit.lead.harness.displayName))
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)
                actionButton(L10n.TaskDetail.promote, tint: AuspexPalette.stateThinking) {
                    tasks.promote(unit: unit)
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.text3)
            content()
        }
    }
}

/// Where the dependency graph will be, and why it is not here.
///
/// The strip above it answers the question a person asks *at* a task: what is
/// stopping this one. The graph answers a different one — where does the work
/// pile up, and which three tasks would unblock nine — and it is a page, with
/// a layout pass, a worker for it, and a way to page through the tasks nothing
/// links to. That is a piece of work of its own.
///
/// A stub rather than nothing, because "there is no graph" and "the graph is
/// somewhere I have not found" are different things to a person holding a
/// board of forty tasks, and only one of them is true.
struct TaskGraphStub: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.TaskDetail.graphStub)
                .font(AuspexType.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AuspexPalette.text3)
    }
}

/// One line of a task's history.
struct TaskLogRow: View {
    let entry: AuspexTaskLogEntry

    /// The entry's kind as a tag. The stored kind is an identifier the ledger
    /// writes; one this table does not know is shown as stored.
    static func kindLabel(_ kind: String) -> String {
        if let note = TaskNoteKind(rawValue: kind) { return note.localizedLabel }
        switch kind {
        case "created": return L10n.Task.Log.created
        case "project": return L10n.Task.Log.project
        case "status": return L10n.Task.Log.status
        case "claimed": return L10n.Task.Filter.claimed
        case "released": return L10n.Task.Log.released
        case "linked": return L10n.Task.Link.linked
        case "unlinked": return L10n.Task.Log.unlinked
        case "takeover_requested": return L10n.Task.Log.takeoverRequested
        case "takeover_expired": return L10n.Task.Log.takeoverExpired
        case "finished": return L10n.Task.Log.finished
        case "closed": return L10n.Task.Log.closed
        default: return kind
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.kindLabel(entry.kind))
                .font(AuspexType.labelSmall)
                .foregroundStyle(Self.colour(entry.noteKind))
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let message = entry.message {
                    Text(message)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ref = entry.ref {
                    // The whole difference between a work log and a chat
                    // transcript: something a later reader can go and check.
                    Text(ref)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.stateThinking)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(RelativeTimeText.since(entry.timestamp))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One colour per note kind, and the tertiary text colour for everything
    /// the ledger wrote about itself — so an agent's sentences read as
    /// somebody's words and `claimed` reads as bookkeeping.
    static func colour(_ kind: TaskNoteKind?) -> Color {
        switch kind {
        case .decision: AuspexPalette.stateDelegating
        case .evidence: AuspexPalette.stateWriting
        case .risk: AuspexPalette.stateStale
        case .note: AuspexPalette.text2
        case nil: AuspexPalette.text3
        }
    }

    static func colour(_ kind: TaskNoteKind) -> Color { colour(Optional(kind)) }
}
