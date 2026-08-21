import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The sidebar's project tree: every repository on the board, the checkouts
/// inside it, and the **tasks** inside those.
///
/// ## Four rows, four meanings
///
/// A project row *focuses* the wall on that project and opens it; a checkout
/// row only opens; a task row *selects its lead's card* and fills the trace;
/// a session row inside an opened task selects that session. Drawing the rows
/// rather than reaching for `OutlineGroup` is what makes those behaviours
/// explicit — a `List(selection:)` binds one type, and this column has three —
/// and it lets the tree carry the board's own chrome instead of the system's
/// blue capsule.
///
/// ## Why a task and not a session
///
/// This column used to list every session on the machine, and a machine with
/// a dozen agents in one checkout put every one of them here permanently.
/// Most of them were subagents: a step inside somebody else's job, listed as
/// a peer of it. A task row is the piece of work, with a `↳ N` for what is
/// inside it, and the sessions appear only for a task somebody has opened —
/// or for everybody, if they turned "Show subagents" on.
///
/// ## Depth is leading space, not a rail
///
/// The mock indents by 14 points a level and draws nothing else, because at
/// 232 points wide a rail per level costs more width than it repays. What
/// carries the hierarchy instead is that each level looks different: a project
/// is a name and a live badge, a checkout is a branch and a count, a session is
/// a mark, a title, and a state dot.
struct ProjectsSidebar: View {
    let tree: ProjectTree
    let model: ProjectsModel
    /// The project every surface is currently bound to.
    let focusedProjectKey: String?
    let selectedKey: SessionKey?
    /// The sessions a rule matched, drawn dimmed while "show ignored" is on.
    var ignoredKeys: Set<SessionKey> = []
    let onSelectProject: (String) -> Void
    let onSelectSession: (SessionKey) -> Void

    @Environment(AppEnvironment.self) private var environment

    /// The branches a person has asked to see the whole of.
    ///
    /// Local to the column and deliberately not persisted: "show me all
    /// nineteen of these" is a thing somebody wants for the next thirty
    /// seconds, and a sidebar that reopened tomorrow with nineteen rows in it
    /// would have quietly undone the cap that keeps the window responsive.
    @State private var openedInFull: Set<String> = []

    var body: some View {
        if tree.isEmpty {
            emptyNote
        } else {
            ForEach(tree.projects) { project in
                let isFocused = focusedProjectKey == project.key
                ProjectRow(
                    project: project,
                    // What this project is carrying on the task board, from
                    // the model that already folded every task into the
                    // person's own projects — the sidebar must not re-derive
                    // that, because the folding is what a `GROUP BY` in SQLite
                    // could not do.
                    tasks: environment.tasks.taskCounts(byProjectKey: project.key),
                    isFocused: isFocused
                ) {
                    // One meaning per click: *show me this project*. It opens
                    // the row and focuses the wall together, because a sidebar
                    // that expanded without focusing would make the same
                    // gesture mean two things depending on where in the row it
                    // landed.
                    model.toggle(project: project)
                    onSelectProject(project.key)
                }
                .contextMenu { projectMenu(project) }
                if model.isExpanded(project: project) || isFocused {
                    ForEach(project.checkouts) { checkout in
                        checkoutBlock(project: project, checkout: checkout)
                    }
                }
            }
            if !tree.ungrouped.isEmpty {
                UngroupedRow(count: tree.ungrouped.count + tree.ungroupedHidden)
                unitRows(
                    tree.ungrouped,
                    id: Self.ungroupedID,
                    depth: 1,
                    finished: tree.ungroupedHidden
                )
            }
        }
    }

    /// The rows a branch draws: the first ``ProjectTree/listLimit`` of them,
    /// and one row offering the rest.
    ///
    /// The cap is the sidebar's whole performance story. Every row here is a
    /// view SwiftUI builds and compares on every graph update, whether or not
    /// it is scrolled into sight — a `LazyVStack` is lazy about *drawing* —
    /// and a machine with a dozen agents in one checkout used to put every one
    /// of them in this column permanently.
    ///
    /// - Parameters:
    ///   - id: what the fold is remembered under. A checkout's own id, so two
    ///     checkouts opened out do not share one switch.
    ///   - finished: how many sessions of this branch have ended. They are
    ///     never listed here; the row says where they went.
    @ViewBuilder
    private func unitRows(
        _ units: [TaskUnit],
        id: String,
        depth: Int,
        finished: Int
    ) -> some View {
        let fold = SidebarFold.make(
            rows: units.count,
            finished: finished,
            isOpen: openedInFull.contains(id)
        )
        ForEach(units.prefix(fold.shown)) { unit in
            unitRow(unit, depth: depth)
            // The sessions, for a task somebody opened — or for everybody,
            // when the wall's density switch is on. Never by default: a
            // delegation of four used to be four rows in a 180-point column,
            // and every one of them was a view SwiftUI compared on every graph
            // update whether or not it was scrolled into sight.
            if unit.memberCount > 1, board.isExpanded(unit) {
                ForEach(unit.members, id: \.key) { row in
                    sessionRow(row, depth: depth + 1)
                }
            }
        }
        if fold.needsRow {
            MoreRow(depth: depth, fold: fold) {
                if fold.isOpen {
                    openedInFull.remove(id)
                } else if fold.capped > 0 {
                    openedInFull.insert(id)
                }
            }
        }
    }

    /// One piece of work.
    private func unitRow(_ unit: TaskUnit, depth: Int) -> some View {
        UnitRow(
            unit: unit,
            depth: depth,
            isSelected: selectedKey == unit.lead.key,
            isExpanded: board.isExpanded(unit),
            onSelect: { onSelectSession(unit.lead.key) },
            onToggle: unit.memberCount > 1 ? { board.toggleExpanded(unit) } : nil
        )
        .equatable()
        .contextMenu { TaskCardMenu(unit: unit, model: board, environment: environment) }
    }

    private var board: LiveBoardModel { environment.board }

    /// What the fold under "No project" is remembered as. A fixed string
    /// rather than a checkout id, because that branch has no checkout.
    private static let ungroupedID = "auspex.sidebar.ungrouped"

    private func sessionRow(_ row: BoardRow, depth: Int) -> some View {
        SessionRow(
            row: row,
            depth: depth,
            isSelected: selectedKey == row.key,
            isIgnored: ignoredKeys.contains(row.key),
            onSelect: { onSelectSession(row.key) }
        )
        // `.equatable()` and not merely the conformance: SwiftUI only calls a
        // view's own `==` when it is asked to, and a struct carrying a closure
        // is one it otherwise treats as always changed. The column is rebuilt
        // whenever anything under any project moves — a token count is enough —
        // so without this every row on screen redraws for a change to one.
        .equatable()
        .contextMenu { sessionMenu(row) }
    }

    // MARK: - Menus

    /// What can be done to a project without opening a page: pin it, make it a
    /// real project, or stop looking at it.
    @ViewBuilder
    private func projectMenu(_ project: ProjectTree.Project) -> some View {
        let catalog = environment.catalog
        if let owned = catalog.claims.project(forKey: project.key) {
            Button(owned.isPinned ? "Unpin" : "Pin to the top") {
                catalog.togglePin(owned)
            }
        } else if !PseudoProject.isPseudo(project.key) {
            Button("Make this an Auspex project") {
                catalog.addProject(name: project.name, roots: [project.key])
            }
        }
        Divider()
        Button("Ignore project…") {
            environment.composeIgnore(.project, value: project.key)
        }
        if !PseudoProject.isPseudo(project.key) {
            Button("Ignore this folder…") {
                environment.composeIgnore(.pathPrefix, value: project.key)
            }
        }
    }

    /// The same offers a card makes, so a person who found the session in the
    /// tree does not have to go and find its card to act on it.
    private func sessionMenu(_ row: BoardRow) -> some View {
        SessionRowMenu(row: row, model: environment.board, environment: environment)
    }

    @ViewBuilder
    private func checkoutBlock(
        project: ProjectTree.Project,
        checkout: ProjectTree.Checkout
    ) -> some View {
        // A project with one plain checkout has nothing to disclose: the
        // checkout is the project, and a row saying so twice is a row that
        // costs a line and says nothing.
        let isImplied = project.checkouts.count == 1 && !checkout.isWorktree
            && checkout.agentWorktreeTask == nil

        if !isImplied {
            CheckoutRow(
                checkout: checkout,
                isExpanded: model.isExpanded(checkout: checkout),
                onToggle: { model.toggle(checkout: checkout) }
            )
        }
        if isImplied || model.isExpanded(checkout: checkout) {
            unitRows(
                checkout.units,
                id: checkout.id,
                depth: isImplied ? 1 : 2,
                finished: checkout.hiddenCount
            )
        }
    }

    private var emptyNote: some View {
        Text("Projects appear here as sessions report where they are working.")
            .font(.system(size: 10))
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

// MARK: - Rows

/// The shape every row in the tree has: 28 points tall, indented by level,
/// rounded to 7 when it is lit.
private struct TreeRow<Content: View>: View {
    let depth: Int
    var isLit = false
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let content: Content

    /// One step per level. Wide enough to read as a level, narrow enough that
    /// three of them still leave a title room in a 232 pt sidebar.
    static var step: CGFloat { 14 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.leading, 10 + Self.step * CGFloat(depth))
                .padding(.trailing, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isLit ? AuspexPalette.selection : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .disabled(!isEnabled)
    }
}

/// A project: name, which harnesses are in it, and how many of its sessions are
/// live.
///
/// The harness dots are the row's whole reason for existing at this size. They
/// are the same accents the cards' rails use, so "the coral one and the teal
/// one are both in auspex" is answerable from the sidebar without opening
/// anything — which is the question a person opens a sidebar to ask.
private struct ProjectRow: View {
    let project: ProjectTree.Project
    /// How much work is filed against this project on the task board.
    var tasks = TaskProjectCounts(total: 0, open: 0)
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        TreeRow(depth: 0, isLit: isFocused, action: action) {
            // The dots are the first thing to give way, the same bargain the
            // board header makes with its chips: at 180 points a long project
            // name and four accents cannot both be read, and the name is the
            // one a person is scanning for. The accents come back the moment
            // the column is dragged wider.
            //
            // The task count goes second, because *what is running here* is
            // what a live board is read for and *what is planned here* keeps.
            // Three candidates rather than two, and it costs nothing at the
            // widths anybody uses: `ViewThatFits` measures in order and stops
            // at the first that fits, so a column wide enough for the whole
            // row is one measurement exactly as it was.
            ViewThatFits(in: .horizontal) {
                content(showsDots: true, showsTasks: true)
                content(showsDots: false, showsTasks: true)
                content(showsDots: false, showsTasks: false)
            }
        }
        .help(
            isFocused
                ? "Show every project on the board again"
                : "Show only \(project.name) on the board"
        )
    }

    @ViewBuilder
    private func content(showsDots: Bool, showsTasks: Bool) -> some View {
        HStack(spacing: 8) {
            if project.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            if let colour = ProjectColour.color(project.colorHex) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colour)
                    .frame(width: 3, height: 14)
            }
            Text(project.name)
                .font(isFocused ? AuspexType.rowStrong : AuspexType.row)
                .foregroundStyle(isFocused ? AuspexPalette.text : AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsDots {
                HarnessDots(harnesses: project.harnesses)
            }
            Spacer(minLength: 4)
            // Red first, and it replaces the live count rather than sitting
            // beside it. At 180 points there is room for one number, and *how
            // many of these want me* is a different question from *how many are
            // running* — the first is the one somebody scans a sidebar for.
            if project.needsYouCount > 0 {
                AttentionPill(count: project.needsYouCount, attention: Self.calling)
            } else if project.doneReportedCount > 0 {
                AttentionPill(count: project.doneReportedCount, attention: Self.reported)
            } else if project.liveCount > 0 {
                LivePill(count: project.liveCount)
            }
            // After the live count, and quieter than it. A project with tasks
            // filed against it and nothing running is a project somebody meant
            // to come back to, which is worth saying in a column that
            // otherwise only says what is happening this second.
            if showsTasks { TaskPill(counts: tasks) }
        }
    }

    /// The two shapes a project row can wear, as values rather than as colours
    /// picked in a body — see ``AttentionStyle``.
    static let calling = AttentionState.needsYou(reason: "", source: .harness)
    static let reported = AttentionState.doneReported(summary: "", source: .agent)
}

/// A checkout: the agent worktree's task, or the branch, or the directory.
private struct CheckoutRow: View {
    let checkout: ProjectTree.Checkout
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        TreeRow(depth: 1, action: onToggle) {
            if checkout.isWorktree {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            Text(checkout.title)
                .font(AuspexType.row)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if checkout.needsYouCount > 0 {
                AttentionPill(count: checkout.needsYouCount, attention: ProjectRow.calling)
            } else if checkout.liveCount > 0 {
                LivePill(count: checkout.liveCount)
            } else if checkout.sessionCount > 0 {
                // Every session in the checkout, not only the ones the tree
                // lists: a checkout of finished work still says how much of it
                // there was.
                Text("\(checkout.sessionCount)")
                    .font(AuspexType.monoCount)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .help(isExpanded ? "Hide this checkout's tasks" : "Show this checkout's tasks")
    }
}

/// A task: where it stands, what it is called, how many sessions are inside
/// it, and whether any of them wants a person.
///
/// A status ring rather than a state dot, because a row in this column now
/// answers *where is this piece of work* rather than *what is that process
/// doing*. The `↳ N` is the fold: it is a control, and clicking it lists the
/// sessions rather than opening the card.
private struct UnitRow: View, Equatable {
    let unit: TaskUnit
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    /// `nil` for a task with one session in it, which has nothing to fold.
    var onToggle: (() -> Void)?

    nonisolated static func == (lhs: UnitRow, rhs: UnitRow) -> Bool {
        lhs.unit == rhs.unit && lhs.depth == rhs.depth && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        TreeRow(depth: depth, isLit: isSelected, action: onSelect) {
            TaskStatusIcon(status: unit.status, size: 12)
            Text(unit.title)
                .font(AuspexType.row)
                .foregroundStyle(isSelected ? AuspexPalette.text : AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 3) {
                        Text("↳ \(unit.subagents.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(AuspexPalette.stateDelegating)
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.auspex(cornerRadius: 4))
                .help(isExpanded ? "Fold these sessions away" : "List the sessions on this task")
            }
            if let colour = AttentionStyle.colour(unit.attention) {
                StateDot(color: colour, glows: unit.needsPerson)
            } else if unit.counts.working > 0 {
                StateDot(color: unit.lead.state.style.color, glows: true)
            }
        }
        .help(
            AttentionStyle.label(unit.attention).map { "\(unit.title) — \($0)" }
                ?? "\(unit.shortID) \(unit.title) — \(unit.status.label)"
        )
    }
}

/// A session: its harness, its title, and a dot in the colour of what it is
/// doing.
///
/// A dot rather than a pill. The pill is a card's device and needs 80 points;
/// at this width the colour alone carries the state, and the full name is one
/// hover or one VoiceOver stop away.
private struct SessionRow: View, Equatable {
    let row: BoardRow
    let depth: Int
    let isSelected: Bool
    /// A rule matches this session and the board is showing it anyway.
    var isIgnored = false
    let onSelect: () -> Void

    nonisolated static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.row == rhs.row && lhs.depth == rhs.depth && lhs.isSelected == rhs.isSelected
            && lhs.isIgnored == rhs.isIgnored
    }

    var body: some View {
        let style = row.state.style
        TreeRow(depth: depth, isLit: isSelected, action: onSelect) {
            HarnessBadge(harness: row.harness, size: 16, isMuted: row.isEnded)
            Text(row.depth > 0 ? "↳ \(row.title)" : row.title)
                .font(AuspexType.row)
                .foregroundStyle(isSelected ? AuspexPalette.text : AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // What is being *said* about this session outranks what it is
            // doing. A row that is asking for a person and a row that happens
            // to be thinking are the same colour otherwise, and only one of
            // them is somebody's errand.
            if let colour = AttentionStyle.colour(row.attention) {
                StateDot(color: colour, glows: row.needsPerson)
            } else {
                StateDot(color: style.color, glows: style.motion.isAnimated)
            }
        }
        .opacity(isIgnored ? 0.45 : 1)
        .help(
            isIgnored
                ? "\(row.title) — \(row.state.label) · ignored by a rule"
                : AttentionStyle.label(row.attention).map { "\(row.title) — \($0)" }
                    ?? "\(row.title) — \(row.state.label)"
        )
    }
}

/// A project's chosen colour, as the board draws it.
///
/// The palette a person picks from is the harness accents plus the state
/// colours — the colours this app already uses, so a project cannot be given a
/// hue that belongs to no part of the design.
enum ProjectColour {
    /// Every colour offered, as `#RRGGBB` with the name shown beside it.
    static let choices: [(name: String, hex: String)] = [
        ("Coral", "#E0785A"), ("Teal", "#2DD4BF"), ("Blue", "#4C8DFF"),
        ("Violet", "#B48CFF"), ("Green", "#4FD08A"), ("Amber", "#F2B544"),
        ("Magenta", "#F45FA0"), ("Lime", "#B4E048"), ("Sky", "#7DD3FC"),
    ]

    /// Parses `#RRGGBB`. `nil` for no colour and for anything unparseable —
    /// a project with a bad colour is a project drawn in the board's own.
    static func color(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// How much of one branch of the tree is drawn, and what is left over.
///
/// A value rather than three expressions in a `body`, because it is the rule
/// that keeps the sidebar's cost bounded and a rule worth a test is a rule
/// worth a name.
struct SidebarFold: Equatable {
    /// How many of the branch's rows to draw.
    var shown: Int
    /// How many running sessions are not drawn. `0` when the branch is open.
    var capped: Int
    /// How many of the branch's sessions have finished. Never drawn here — see
    /// ``ProjectTree/listable(_:)``.
    var finished: Int
    /// Whether the reader has asked for the whole of this branch.
    var isOpen: Bool

    /// Whether the branch draws the row at the end of it.
    ///
    /// Because something is missing, *or* because the branch is open and the
    /// way back has to be somewhere — a fold that could only be opened would
    /// be a one-way door on the one control that keeps this column short.
    var needsRow: Bool { capped > 0 || finished > 0 || isOpen }

    static func make(
        rows: Int,
        finished: Int,
        isOpen: Bool,
        limit: Int = ProjectTree.listLimit
    ) -> SidebarFold {
        let shown = isOpen ? rows : min(rows, limit)
        return SidebarFold(
            shown: shown,
            capped: max(0, rows - shown),
            finished: max(0, finished),
            isOpen: isOpen && rows > limit
        )
    }
}

/// The row at the end of a capped branch: what is not drawn, and where it is.
///
/// One row for two different absences, because they read as one question —
/// *is this everything?* — and two rows answering it would be two rows of
/// chrome under every busy checkout in the column:
///
/// - **running** sessions past ``ProjectTree/listLimit``, which this row opens
///   out and folds back;
/// - **finished** ones, which it never opens, because they are on the board in
///   the Ended section and a second copy of them in a 180-point column would
///   be the cheapest possible way to make the sidebar useless again.
///
/// Drawn as a tree row so it indents with the branch it belongs to, and in the
/// tertiary text colour so it never competes with a session for attention.
struct MoreRow: View {
    let depth: Int
    let fold: SidebarFold
    let action: () -> Void

    var body: some View {
        TreeRow(depth: depth, isEnabled: fold.capped > 0 || fold.isOpen, action: action) {
            Text(Self.title(fold))
                .font(AuspexType.row)
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
            Spacer(minLength: 4)
            if fold.isOpen {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .help(Self.help(fold))
    }

    /// What the row says. A function of the fold rather than three `if`s in a
    /// body, so the one row that admits the column is showing a summary can be
    /// asserted on without a window.
    static func title(_ fold: SidebarFold) -> String {
        if fold.isOpen { return "Show fewer" }
        if fold.capped > 0, fold.finished > 0 {
            return "+\(fold.capped) more · \(fold.finished) finished"
        }
        if fold.capped > 0 { return "+\(fold.capped) more" }
        return fold.finished == 1 ? "1 finished" : "\(fold.finished) finished"
    }

    static func help(_ fold: SidebarFold) -> String {
        if fold.isOpen { return "List only the first \(ProjectTree.listLimit) again" }
        var parts: [String] = []
        if fold.capped > 0 { parts.append("List every running session here") }
        if fold.finished > 0 {
            parts.append(
                fold.finished == 1
                    ? "1 finished session is in the board's Ended section"
                    : "\(fold.finished) finished sessions are in the board's Ended section"
            )
        }
        return parts.joined(separator: ". ")
    }
}

/// The header over sessions that could be placed under no project.
private struct UngroupedRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(BoardGrouping.noProjectTitle).auspexLabel(AuspexType.labelSmall)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
        }
        .foregroundStyle(AuspexPalette.text3)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .help("These sessions reported no working directory, and no ancestor did either.")
    }
}

// MARK: - Parts

/// One dot per harness at work in a project, in its own accent.
///
/// A dot rather than the harness's mark, and deliberately: at six points a
/// vendor logo is a smudge, while the accent is exactly as legible at 6 pt as
/// it is at 28. The accent is the identity channel the mark shares, so the row
/// still agrees with every other surface — and the full names are one hover or
/// one VoiceOver stop away.
private struct HarnessDots: View {
    let harnesses: [Harness]

    /// Four fits; a fifth would push the live badge off a narrow sidebar, and
    /// the count says what the fifth dot would have.
    private static let limit = 4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(harnesses.prefix(Self.limit), id: \.self) { harness in
                Circle()
                    .fill(harness.style.accent)
                    .frame(width: 6, height: 6)
            }
            if harnesses.count > Self.limit {
                Text("+\(harnesses.count - Self.limit)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .fixedSize()
        .accessibilityLabel(names)
        .help(names)
    }

    /// Full names, never abbreviations.
    private var names: String {
        harnesses.map(\.displayName).joined(separator: ", ")
    }
}

/// How many sessions are running here.
///
/// Green, because on this board green means *something is being made* — and a
/// project with nothing running shows nothing at all rather than a grey zero,
/// which would make a quiet repository look like a broken one.
/// A count in an attention colour, in place of the live count.
///
/// The same two colours and the same two marks the header's chips and the
/// scene's bubbles use, at the one size a 180-point column has room for.
private struct AttentionPill: View {
    let count: Int
    let attention: AttentionState

    var body: some View {
        let colour = AttentionStyle.colour(attention) ?? AuspexPalette.text3
        HStack(spacing: 3) {
            Text(AttentionStyle.mark(attention) ?? "")
                .font(.system(size: 9, weight: .black))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .auspexTabularDigits()
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colour.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(colour.opacity(0.3), lineWidth: 1)
        )
        .fixedSize()
        .accessibilityLabel(
            attention.wantsPerson ? "\(count) need you" : "\(count) finished"
        )
    }
}

/// How much work is filed against a project and not finished.
///
/// The task board's number in the sidebar, so a person who filed three things
/// against `auspex` last week sees that from the column they navigate by rather
/// than only from the Tasks page. Drawn in the tertiary colour with no fill:
/// it is a standing fact, and the pills beside it are about right now.
///
/// Nothing at all when the project carries nothing — which is most projects,
/// most of the time. ``TaskProjectCounts/openDescription`` owns that rule, so
/// the sidebar and the Projects page cannot disagree about when to draw one.
private struct TaskPill: View {
    let counts: TaskProjectCounts

    var body: some View {
        if let description = counts.openDescription {
            Text(description)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AuspexPalette.bg3)
                )
                .fixedSize()
                .accessibilityLabel(description)
                .help("\(description) on the task board · \(counts.total) filed in all")
        }
    }
}

private struct LivePill: View {
    let count: Int

    var body: some View {
        Text("\(count) live")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AuspexPalette.stateWriting)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AuspexPalette.stateWriting.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AuspexPalette.stateWriting.opacity(0.25), lineWidth: 1)
            )
            .fixedSize()
            .accessibilityLabel("\(count) live")
    }
}
