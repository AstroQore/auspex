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

    var body: some View {
        VStack(spacing: 0) {
            header
            BoardScroll {
                VStack(alignment: .leading, spacing: 22) {
                    title
                    if let body = unit.body { bodyText(body) }
                    if unit.isInReview, let result = unit.result { reviewBox(result) }
                    properties
                    if !unit.waitingOn.isEmpty || !unit.dependsOn.isEmpty { dependencies }
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
        .task(id: unit.origin.taskID) { tasks.loadLog(taskID: unit.origin.taskID) }
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
                    Text("Board").font(AuspexType.caption)
                }
                .foregroundStyle(AuspexPalette.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help("Back to the wall — or press Escape")
            Text("›")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Text(unit.shortID)
                .font(AuspexType.monoCount)
                .foregroundStyle(AuspexPalette.text3)
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
            actionButton("Close", tint: AuspexPalette.stateWriting) {
                tasks.close(unit: unit)
                board.openUnitID = nil
            }
        } else if unit.status == .done {
            actionButton("Reopen") { tasks.reopen(unit: unit) }
        }
        if unit.isClaimOrphaned, let id = unit.origin.taskID {
            actionButton("Release claim", tint: AuspexPalette.stateStale) {
                tasks.releaseClaim(taskID: id)
            }
        }
        if unit.counts.live > 0 {
            actionButton("Open trajectory") {
                board.selectedKey = unit.lead.key
                board.openUnitID = nil
                board.openTrajectory()
            }
        }
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
            Text("Finished, waiting on you")
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
            property("Status", unit.status.label)
            property("Importance", unit.importance.label)
            if let kind = unit.kind { property("Kind", kind.label) }
            if let key = unit.projectKey {
                property("Project", TaskProject.displayName(forKey: key, in: board.board))
            }
            if let milestone = unit.planTitle { property("Milestone", milestone) }
            if let claim = unit.claim {
                property("Claimed by", claim.description ?? claim.harness.displayName)
            }
            if !unit.labels.isEmpty {
                property("Labels", unit.labels.joined(separator: ", "))
            }
            if let created = unit.createdAt {
                property("Filed", RelativeTimeText.since(created))
            }
        }
        .panelChrome()
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
        section("Waits on") {
            if unit.waitingOn.isEmpty {
                Text("Everything it waits on is closed. Ready to start.")
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
                        .help("Open \(dependency.shortID)")
                    }
                }
            }
        }
    }

    // MARK: Members

    /// Everybody on this task, and what each of them is doing.
    private var members: some View {
        section(unit.memberCount == 1 ? "Session" : "\(unit.memberCount) sessions") {
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
                        Text("lead")
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
            .help("Open this session's trajectory")
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
        section("History") {
            VStack(alignment: .leading, spacing: 10) {
                if tasks.openLog.isEmpty {
                    Text("Nothing has been written down yet.")
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
                        Text(kind.label)
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
                TextField("Write it down", text: $draftNote)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                TextField("ref", text: $draftRef)
                    .textFieldStyle(.plain)
                    .font(AuspexType.monoSmall)
                    .frame(width: 96)
                Button("Add") { commitNote() }
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
        section("Not filed") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Auspex worked this out from a delegation: \(unit.lead.harness.displayName) "
                        + "started it and nobody registered a task. Promoting it writes one, "
                        + "claimed by the session already doing the work — the card keeps its "
                        + "place and gains a history, a milestone, and something to close."
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)
                actionButton("Promote to task", tint: AuspexPalette.stateThinking) {
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

/// One line of a task's history.
struct TaskLogRow: View {
    let entry: AuspexTaskLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.kind)
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
