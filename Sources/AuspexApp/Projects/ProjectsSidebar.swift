import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The sidebar's project tree: every repository on the board, the checkouts
/// inside it, and the sessions inside those.
///
/// ## Why it is drawn rather than outlined
///
/// `OutlineGroup` would build the same shape in a third of the lines, and its
/// selection would fight the sidebar's. A `List(selection:)` binds one type,
/// and this tree has three kinds of row that mean three different things when
/// clicked — a project *filters the wall*, a checkout only opens, a session
/// *selects a card*. Drawing the rows makes those three behaviours explicit,
/// and it lets the tree carry the board's own chrome instead of the system's
/// blue capsule.
///
/// ## The rail
///
/// Depth is carried by a hairline dropped down the left of each nested block,
/// not by indentation alone. It is the same device the board uses to say
/// "these things belong together" — a rule, not a rounded container — and at
/// 200 points wide it is the only way three levels stay readable.
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
                ProjectRow(
                    project: project,
                    isExpanded: model.isExpanded(project: project),
                    isFiltering: projectFilter == project.key,
                    onToggle: { model.toggle(project: project) },
                    onSelect: { onSelectProject(project.key) }
                )
                if model.isExpanded(project: project) {
                    ForEach(project.checkouts) { checkout in
                        checkoutBlock(project: project, checkout: checkout)
                    }
                }
            }
            if !tree.ungrouped.isEmpty {
                UngroupedRow(count: tree.ungrouped.count)
                ForEach(tree.ungrouped, id: \.key) { session in
                    SessionRow(
                        session: session,
                        depth: 1,
                        isSelected: selectedKey == session.key,
                        onSelect: { onSelectSession(session.key) }
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
            ForEach(checkout.sessions, id: \.key) { session in
                SessionRow(
                    session: session,
                    depth: isImplied ? 1 : 2,
                    isSelected: selectedKey == session.key,
                    onSelect: { onSelectSession(session.key) }
                )
            }
        }
    }

    private var emptyNote: some View {
        Text("Projects appear here as sessions report where they are working.")
            .font(.system(size: 10))
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
    }
}

// MARK: - Rows

/// A project: name, how many of its sessions are live, and which harnesses are
/// in it.
///
/// The harness dots are the row's whole reason for existing at this size. They
/// are the same accents the cards' rails use, so "the coral one and the teal
/// one are both in auspex" is answerable from the sidebar without opening
/// anything — which is the question a person opens a sidebar to ask.
private struct ProjectRow: View {
    let project: ProjectTree.Project
    let isExpanded: Bool
    let isFiltering: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            DisclosureChevron(isExpanded: isExpanded, action: onToggle)

            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.system(size: 11.5, weight: isFiltering ? .bold : .semibold))
                        .foregroundStyle(
                            isFiltering ? AuspexPalette.textPrimary : AuspexPalette.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !project.isRepository {
                        Text("no git")
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.textTertiary)
                    }
                    Spacer(minLength: 3)
                    HarnessDots(harnesses: project.harnesses)
                    LiveBadge(live: project.liveCount, total: project.sessionCount)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isFiltering
                    ? "Show every project on the board again"
                    : "Show only \(project.name) on the board"
            )
        }
        .padding(.vertical, 2)
        .listRowBackground(
            isFiltering
                ? AuspexPalette.stateThinking.opacity(0.14)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            if isFiltering {
                Rectangle()
                    .fill(AuspexPalette.stateThinking)
                    .frame(width: 2)
                    .offset(x: -8)
            }
        }
    }
}

/// A checkout: the agent worktree's task, or the branch, or the directory.
private struct CheckoutRow: View {
    let checkout: ProjectTree.Checkout
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        TreeIndent(depth: 1) {
            HStack(spacing: 4) {
                DisclosureChevron(isExpanded: isExpanded, action: onToggle)
                Image(systemName: checkout.isWorktree ? "arrow.triangle.branch" : "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AuspexPalette.textTertiary)
                Text(checkout.title)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = checkout.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 3)
                LiveBadge(live: checkout.liveCount, total: checkout.sessions.count)
            }
        }
        .padding(.vertical, 1)
    }
}

/// A session: its harness, its title, and what it is doing.
private struct SessionRow: View {
    let session: SessionSnapshot
    let depth: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        TreeIndent(depth: depth + 1) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    HarnessBadge(
                        harness: session.key.harness,
                        size: 13,
                        isMuted: session.state.isEnded
                    )
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isSelected ? AuspexPalette.textPrimary : AuspexPalette.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 3)
                    StatePill(state: session.state, isStale: session.isStale)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this session's trace")
        }
        .padding(.vertical, 1)
        .background(
            isSelected ? AuspexPalette.panelRaised : Color.clear
        )
    }

    /// The same ladder a card climbs — title, project, id — so a session is
    /// never called one thing in the sidebar and another on the wall.
    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let project = BoardGrouping.projectName(for: session) { return project }
        return String(session.key.sessionID.prefix(10))
    }
}

/// The header over sessions that could be placed under no project.
private struct UngroupedRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 9))
            Text(BoardGrouping.noProjectTitle).auspexLabel(AuspexType.labelSmall)
            Spacer(minLength: 3)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(AuspexPalette.textTertiary)
        .padding(.vertical, 2)
        .help("These sessions reported no working directory, and no ancestor did either.")
    }
}

// MARK: - Parts

/// Nests a row behind a hairline rail, one step per level.
///
/// The rails are an *overlay* rather than a leading stack, so their height is
/// the row's height. A flexible rectangle in the row's own layout would take
/// whatever slack the container had going spare, which turns a list of short
/// rows into a ladder of tall ones the moment it is not inside a `List`.
private struct TreeIndent<Content: View>: View {
    let depth: Int
    @ViewBuilder let content: Content

    /// Wide enough to read as a level, narrow enough that three of them still
    /// leave a title room in a 200 pt sidebar.
    private static var step: CGFloat { 11 }

    var body: some View {
        content
            .padding(.leading, Self.step * CGFloat(depth))
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle()
                            .fill(AuspexPalette.hairline)
                            .frame(width: 1)
                            .frame(width: Self.step, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
    }
}

/// The triangle that opens a row. A button of its own, so clicking the row's
/// label can mean something else.
private struct DisclosureChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(AuspexPalette.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }
}

/// One dot per harness at work in a project, in its own accent.
private struct HarnessDots: View {
    let harnesses: [Harness]

    /// Four fits; a fifth would push the live badge off a narrow sidebar, and
    /// the count says what the fifth dot would have.
    private static let limit = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(harnesses.prefix(Self.limit), id: \.self) { harness in
                Circle()
                    .fill(harness.style.accent)
                    .frame(width: 5, height: 5)
            }
            if harnesses.count > Self.limit {
                Text("+\(harnesses.count - Self.limit)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(AuspexPalette.textTertiary)
            }
        }
        .accessibilityLabel(
            harnesses.map(\.displayName).joined(separator: ", ")
        )
    }
}

/// How many sessions are running here, or how many there have been.
///
/// Two appearances rather than one: a live count is lit, and a project with
/// nothing running shows its total in tertiary text. A badge that looked the
/// same either way would make a finished repository look busy.
private struct LiveBadge: View {
    let live: Int
    let total: Int

    var body: some View {
        if live > 0 {
            Text("\(live)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(AuspexPalette.textPrimary)
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(AuspexPalette.stateThinking.opacity(0.38)))
                .accessibilityLabel("\(live) live")
        } else if total > 0 {
            Text("\(total)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(AuspexPalette.textTertiary)
                .accessibilityLabel("\(total) sessions, none running")
        }
    }
}
