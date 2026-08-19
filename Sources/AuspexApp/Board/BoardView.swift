import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The wall.
///
/// A scrolling grid of session cards, divided into sections by whatever the
/// toolbar's group-by control says, with each section's header pinned so the
/// counts stay on screen while its cards scroll under them.
///
/// The grid is adaptive rather than a fixed column count: a card is legible
/// somewhere between 270 and 400 points wide, and letting the window decide
/// how many fit is what makes the same view work on a laptop and on the
/// second display it will actually live on.
struct BoardView: View {
    @Bindable var model: LiveBoardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.adaptive(minimum: 272, maximum: 400), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.projectFilterName {
                ProjectFilterBar(name: name, path: model.projectFilter ?? "") {
                    model.projectFilter = nil
                }
            }
            if model.groups.isEmpty {
                BoardEmptyState(model: model)
            } else {
                grid
            }
        }
        .background(BoardSurfaceBackground())
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        body(of: group)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                    } header: {
                        BoardSectionHeader(group: group)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// A section is a grid of cards, unless it is a delegation tree — in which
    /// case it is a column, because a tree drawn across an adaptive grid is a
    /// tree whose shape depends on the window width.
    @ViewBuilder
    private func body(of group: BoardGroup) -> some View {
        if let roots = group.roots, roots.contains(where: { !$0.children.isEmpty }) {
            BoardTreeColumn(roots: roots) { card(for: $0) }
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(group.sessions, id: \.key) { session in
                    card(for: session)
                }
            }
        }
    }

    private func card(for session: SessionSnapshot) -> some View {
        SessionCard(
            session: session,
            isSelected: model.selectedKey == session.key,
            reduceMotion: reduceMotion,
            descendantCount: model.descendantCount(of: session.key),
            parentTitle: parentTitle(of: session),
            onSelectParent: { key in model.selectedKey = key }
        )
            .equatable()
            .onTapGesture { model.selectedKey = session.key }
            .accessibilityAddTraits(.isButton)
    }

    /// The parent's headline, for the card's "spawned by" chip. `nil` when the
    /// session has no parent, or when the board no longer holds it — a chip
    /// naming a card that is not there would be a dead link.
    private func parentTitle(of session: SessionSnapshot) -> (key: SessionKey, title: String)? {
        guard let parent = session.identity.parent,
              let snapshot = model.board.session(for: parent)
        else { return nil }
        if let title = snapshot.identity.title, !title.isEmpty { return (parent, title) }
        return (parent, String(parent.sessionID.prefix(10)))
    }
}

/// A section drawn as a delegation tree rather than as a grid.
///
/// Its own type so that anything which has to draw this shape — the board, and
/// the renderer that produces the documentation screenshots — draws it with one
/// set of measurements rather than two that drift.
struct BoardTreeColumn<Card: View>: View {
    let roots: [BoardTreeNode]
    @ViewBuilder let card: (SessionSnapshot) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(roots) { root in
                TreeBranch(node: root, card: card)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One node of a delegation tree and everything under it.
///
/// Children are inset behind a rail rather than drawn in a grid: the whole
/// content of this view is *who spawned whom*, and a layout that reflowed with
/// the window would lose it. The rail is the same hairline device the sidebar's
/// tree uses, so one idiom means one thing across the window.
fileprivate struct TreeBranch<Card: View>: View {
    let node: BoardTreeNode
    /// How to draw one session. A closure rather than a stored `BoardView`,
    /// because a view held as a value keeps whatever environment it was built
    /// with — and a card that stopped noticing "reduce motion" would be a card
    /// that animates at someone who asked it not to.
    @ViewBuilder let card: (SessionSnapshot) -> Card

    /// A card is legible from about 270 points and stops gaining anything past
    /// 400. Fixing the width here keeps a root and a grandchild the same size,
    /// which is what makes the inset read as depth rather than as importance.
    private static var cardWidth: CGFloat { 380 }
    private static var inset: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            card(node.session)
                .frame(maxWidth: Self.cardWidth, alignment: .leading)

            if !node.children.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(AuspexPalette.stateDelegating.opacity(0.35))
                        .frame(width: 1)
                        .frame(width: Self.inset, alignment: .center)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(node.children) { child in
                            TreeBranch(node: child, card: card)
                        }
                    }
                }
            }
        }
    }
}

/// The bar over the wall while one project is being shown.
///
/// A filter that is not visible is a bug report: a person who filtered ten
/// minutes ago and came back to a half-empty board should be able to see why
/// without going looking. It sits above the scroll view rather than inside it
/// so it cannot be scrolled away from.
struct ProjectFilterBar: View {
    let name: String
    let path: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuspexPalette.stateThinking)
            Text("Showing").auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text(name)
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.textPrimary)
            Text(PathDisplay.abbreviate(path))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Button(action: onClear) {
                Text("Show all").auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Show every project on the board")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AuspexPalette.canvasDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.stateThinking.opacity(0.5)).frame(height: 1)
        }
    }
}

/// A section header: what this group is, and how its sessions are doing.
///
/// Pinned, so on a long wall the counts are always the thing at the top of the
/// viewport. Deliberately a full-width bar rather than a floating label — it
/// is a rule across the board, and the cards hang from it.
struct BoardSectionHeader: View {
    let group: BoardGroup

    var body: some View {
        HStack(spacing: 8) {
            if let harness = group.harness {
                Rectangle()
                    .fill(harness.style.accent)
                    .frame(width: 3, height: 13)
            }

            Text(group.title)
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.textPrimary)

            if let subtitle = group.subtitle {
                Text(PathDisplay.abbreviate(subtitle))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Text("\(group.sessions.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(AuspexPalette.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(AuspexPalette.hairline))

            Spacer(minLength: 8)

            counts
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AuspexPalette.canvasDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairlineStrong).frame(height: 1)
        }
    }

    /// Only the tallies worth acting on, and only when they are non-zero. A
    /// header that always shows seven numbers teaches a reader to ignore all
    /// seven.
    private var counts: some View {
        HStack(spacing: 10) {
            if group.counts.waitingPermission > 0 {
                CountBadge(
                    value: group.counts.waitingPermission,
                    label: "blocked",
                    tint: AuspexPalette.statePermission
                )
            }
            if group.counts.delegating > 0 {
                CountBadge(
                    value: group.counts.delegating,
                    label: "delegating",
                    tint: AuspexPalette.stateDelegating
                )
            }
            if group.counts.tooling > 0 {
                CountBadge(
                    value: group.counts.tooling,
                    label: "tooling",
                    tint: AuspexPalette.stateTool
                )
            }
            if group.counts.thinking > 0 {
                CountBadge(
                    value: group.counts.thinking,
                    label: "thinking",
                    tint: AuspexPalette.stateThinking
                )
            }
            CountBadge(
                value: group.counts.live,
                label: "live",
                tint: AuspexPalette.textSecondary
            )
        }
    }
}
