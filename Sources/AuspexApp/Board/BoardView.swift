import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The wall.
///
/// A scrolling grid of session cards, divided into sections by whatever the
/// header's grouping menu says, with the finished sessions collected into one
/// collapsed section at the bottom.
///
/// ## Why the finished ones are not cards
///
/// A machine that has run agents for a week has a few dozen live sessions and
/// several hundred finished ones. Drawing all of them as cards is the single
/// most expensive thing this view could do, and it would spend that cost on
/// the rows with the least to say: a finished session has no state to watch,
/// nothing to animate, and nothing anybody has to act on. So they leave the
/// grid entirely — see ``EndedSessions`` — and the board's cost scales with
/// what is *running*.
///
/// The grid is adaptive rather than a fixed column count: a card is legible
/// somewhere between 300 and 520 points wide, and letting the window decide
/// how many fit is what makes the same view work on a laptop and on the second
/// display it will actually live on.
struct BoardView: View {
    @Bindable var model: LiveBoardModel

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.projectFilterName {
                ProjectFilterBar(name: name, path: model.projectFilter ?? "") {
                    model.projectFilter = nil
                }
            }
            if model.groups.isEmpty, model.endedSessions.isEmpty {
                BoardEmptyState(model: model)
            } else {
                grid
            }
        }
        .background(BoardSurfaceBackground())
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        BoardSectionHeader(
                            title: group.title,
                            liveCount: group.counts.live,
                            harness: group.harness
                        )
                        body(of: group)
                    }
                }
                if !model.endedSessions.isEmpty { endedSection }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            LazyVGrid(columns: columns, spacing: 14) {
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
            descendantCount: model.descendantCount(of: session.key),
            parentTitle: parentTitle(of: session),
            onSelectParent: { key in model.selectedKey = key }
        )
        .equatable()
        .onTapGesture { model.selectedKey = session.key }
        .accessibilityAddTraits(.isButton)
    }

    /// The finished sessions, as one-line rows under one header.
    private var endedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoardSectionHeader(
                title: "Ended",
                subtitle: "\(model.endedSessions.count)",
                harness: nil
            )
            LazyVStack(spacing: 0) {
                ForEach(model.visibleEndedSessions, id: \.key) { session in
                    EndedSessionRow(
                        session: session,
                        isSelected: model.selectedKey == session.key
                    )
                    .equatable()
                    .onTapGesture { model.selectedKey = session.key }
                }
            }
            .panelChrome()
            if model.hiddenEndedCount > 0 || model.showsAllEnded {
                showAllToggle
            }
        }
    }

    private var showAllToggle: some View {
        Button {
            model.showsAllEnded.toggle()
        } label: {
            Text(
                model.showsAllEnded
                    ? "Show the most recent \(EndedSessions.collapsedLimit)"
                    : "Show all \(model.endedSessions.count)"
            )
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.text2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Finished sessions are collapsed so the board's cost tracks what is running")
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

/// One finished session, as a row rather than a card.
///
/// Everything a card says about *activity* is gone, because there is none.
/// What is left is what a person looks for in history: whose session it was,
/// what it was called, where it ran, and when it stopped.
struct EndedSessionRow: View, Equatable {
    let session: SessionSnapshot
    let isSelected: Bool

    nonisolated static func == (lhs: EndedSessionRow, rhs: EndedSessionRow) -> Bool {
        lhs.session == rhs.session && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: session.key.harness, size: 16, isMuted: true)
            Text(title)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            if let project = BoardGrouping.projectName(for: session) {
                Text(project)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Text(reason)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize()
            Text(RelativeTimeText.since(session.endedAt ?? session.lastEventAt))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(isSelected ? AuspexPalette.bg3 : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return String(session.key.sessionID.prefix(12))
    }

    private var reason: String {
        if case .ended(let reason) = session.state { return reason.rawValue }
        return "ended"
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
        VStack(alignment: .leading, spacing: 10) {
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
private struct TreeBranch<Card: View>: View {
    let node: BoardTreeNode
    /// How to draw one session. A closure rather than a stored `BoardView`,
    /// because a view held as a value keeps whatever environment it was built
    /// with — and a card that stopped noticing "reduce motion" would be a card
    /// that animates at someone who asked it not to.
    @ViewBuilder let card: (SessionSnapshot) -> Card

    /// A card is legible from about 300 points and stops gaining anything past
    /// 520. Fixing the width here keeps a root and a grandchild the same size,
    /// which is what makes the inset read as depth rather than as importance.
    private static var cardWidth: CGFloat { 440 }
    private static var inset: CGFloat { 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card(node.session)
                .frame(maxWidth: Self.cardWidth, alignment: .leading)

            if !node.children.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(AuspexPalette.stateDelegating.opacity(0.35))
                        .frame(width: 1)
                        .frame(width: Self.inset, alignment: .center)
                    VStack(alignment: .leading, spacing: 10) {
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
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuspexPalette.stateThinking)
            Text("Showing")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Text(name)
                .font(AuspexType.rowStrong)
                .foregroundStyle(AuspexPalette.text)
            Text(PathDisplay.abbreviate(path))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Button(action: onClear) {
                Text("Show all")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Show every project on the board")
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(AuspexPalette.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.stateThinking.opacity(0.5)).frame(height: 1)
        }
    }
}

/// A section's header: what this group is, how much of it is running, and a
/// rule out to the edge of the board.
///
/// A rule rather than a filled bar. The cards hang from it, and a header with
/// its own background would read as a container the cards are inside — which
/// is the wrong idea, because the grouping changes with a menu and the cards
/// do not.
struct BoardSectionHeader: View {
    let title: String
    var subtitle: String?
    var liveCount: Int?
    let harness: Harness?

    var body: some View {
        HStack(spacing: 10) {
            if let harness {
                Rectangle()
                    .fill(harness.style.accent)
                    .frame(width: 3, height: 12)
            }
            Text(title)
                .font(AuspexType.rowStrong)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(1)
            if let liveCount, liveCount > 0 {
                Text("\(liveCount) live")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AuspexPalette.stateWriting)
                    .fixedSize()
            } else if let subtitle {
                Text(subtitle)
                    .font(AuspexType.monoCount)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
            }
            Rectangle()
                .fill(AuspexPalette.line)
                .frame(height: 1)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}
