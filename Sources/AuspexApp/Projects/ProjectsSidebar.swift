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
    /// The project whose sessions the wall is currently showing.
    let projectFilter: String?
    let selectedKey: SessionKey?
    let onSelectProject: (String) -> Void
    let onSelectSession: (SessionKey) -> Void

    var body: some View {
        if tree.isEmpty {
            emptyNote
        } else {
            ForEach(tree.projects) { project in
                let isFocused = projectFilter == project.key
                ProjectRow(project: project, isFocused: isFocused) {
                    // One meaning per click: *show me this project*. It opens
                    // the row and focuses the wall together, because a sidebar
                    // that expanded without focusing would make the same
                    // gesture mean two things depending on where in the row it
                    // landed.
                    model.toggle(project: project)
                    onSelectProject(project.key)
                }
                if model.isExpanded(project: project) || isFocused {
                    ForEach(project.checkouts) { checkout in
                        checkoutBlock(project: project, checkout: checkout)
                    }
                }
            }
            if !tree.ungrouped.isEmpty {
                UngroupedRow(count: tree.ungrouped.count)
                ForEach(tree.ungrouped) { row in
                    SessionRow(
                        row: row,
                        depth: 1 + row.depth,
                        isSelected: selectedKey == row.key,
                        onSelect: { onSelectSession(row.key) }
                    )
                }
            }
        }
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
                SessionRow(
                    row: row,
                    depth: (isImplied ? 1 : 2) + row.depth,
                    isSelected: selectedKey == row.key,
                    onSelect: { onSelectSession(row.key) }
                )
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
        .buttonStyle(.plain)
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
            Text(project.name)
                .font(isFocused ? AuspexType.rowStrong : AuspexType.row)
                .foregroundStyle(isFocused ? AuspexPalette.text : AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            HarnessDots(harnesses: project.harnesses)
            Spacer(minLength: 4)
            if project.liveCount > 0 {
                LivePill(count: project.liveCount)
            }
        }
        .help(
            isFocused
                ? "Show every project on the board again"
                : "Show only \(project.name) on the board"
        )
    }
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
            if checkout.liveCount > 0 {
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
    let onSelect: () -> Void

    nonisolated static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.row == rhs.row && lhs.depth == rhs.depth && lhs.isSelected == rhs.isSelected
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
            StateDot(color: style.color, glows: style.motion.isAnimated)
        }
        .help("\(row.title) — \(row.state.label)")
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
