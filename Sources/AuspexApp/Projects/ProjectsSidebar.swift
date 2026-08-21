import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The sidebar's project tree: every repository on the board, the checkouts
/// inside it, and the sessions inside those.
///
/// ## Three rows, three meanings
///
/// A project row *focuses* the wall on that project and opens it; a checkout
/// row only opens; a session row *selects a card* and fills the trace. Drawing
/// the rows rather than reaching for `OutlineGroup` is what makes those three
/// behaviours explicit — a `List(selection:)` binds one type, and this column
/// has three — and it lets the tree carry the board's own chrome instead of
/// the system's blue capsule.
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

    var body: some View {
        if tree.isEmpty {
            emptyNote
        } else {
            ForEach(tree.projects) { project in
                let isFocused = focusedProjectKey == project.key
                ProjectRow(project: project, isFocused: isFocused) {
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
                UngroupedRow(count: tree.ungrouped.count)
                ForEach(tree.ungrouped) { row in
                    sessionRow(row, depth: 1 + row.depth)
                }
            }
        }
    }

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
            ForEach(checkout.sessions) { row in
                sessionRow(row, depth: (isImplied ? 1 : 2) + row.depth)
            }
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
                        .fill(isLit ? AuspexPalette.bg3 : .clear)
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
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        TreeRow(depth: 0, isLit: isFocused, action: action) {
            // The dots are the first thing to give way, the same bargain the
            // board header makes with its chips: at 180 points a long project
            // name and four accents cannot both be read, and the name is the
            // one a person is scanning for. The accents come back the moment
            // the column is dragged wider.
            ViewThatFits(in: .horizontal) {
                content(showsDots: true)
                content(showsDots: false)
            }
        }
        .help(
            isFocused
                ? "Show every project on the board again"
                : "Show only \(project.name) on the board"
        )
    }

    @ViewBuilder
    private func content(showsDots: Bool) -> some View {
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
            } else if !checkout.sessions.isEmpty {
                Text("\(checkout.sessions.count)")
                    .font(AuspexType.monoCount)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .help(isExpanded ? "Hide these sessions" : "Show these sessions")
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
