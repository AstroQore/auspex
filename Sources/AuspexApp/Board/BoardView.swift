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
/// ## Why it renders rows and not snapshots
///
/// Every value a view holds is a value SwiftUI compares to decide what to
/// re-render, and a `SessionSnapshot` is expensive to compare: a dictionary of
/// open tool calls, a set of open children, fifteen optionals of identity. So
/// this view holds ``BoardRow``s, derived once per frame by the model — see
/// ``LiveBoardModel/rowGroups``.
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

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.focusedProjectName {
                ProjectFilterBar(name: name, path: model.focusedProjectKey ?? "") {
                    model.focusedProjectKey = nil
                }
            }
            if model.rowGroups.isEmpty, model.endedRows.isEmpty {
                BoardEmptyState(model: model)
            } else {
                grid
            }
        }
        .background(BoardSurfaceBackground())
    }

    private var grid: some View {
        BoardScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(model.rowGroups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        BoardSectionHeader(
                            title: group.title,
                            liveCount: group.liveCount,
                            harness: group.harness
                        )
                        body(of: group)
                    }
                }
                if !model.endedRows.isEmpty { endedSection }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section is a grid of cards, unless it is a delegation tree — in which
    /// case it is a column, because a tree drawn across an adaptive grid is a
    /// tree whose shape depends on the window width.
    @ViewBuilder
    private func body(of group: BoardRowGroup) -> some View {
        if group.rows.contains(where: { $0.depth > 0 }) {
            BoardTreeColumn(rows: group.rows) { card(for: $0) }
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(group.rows) { row in
                    card(for: row)
                }
            }
        }
    }

    private func card(for row: BoardRow) -> some View {
        let isIgnored = model.ignoredKeys.contains(row.key)
        return SessionCard(
            row: row,
            isSelected: model.selectedKey == row.key,
            onSelectParent: { key in model.selectedKey = key }
        )
        .equatable()
        // Dimmed rather than removed while "show ignored" is on: the point of
        // revealing them is to see which rows a rule is catching, and a row
        // that looks exactly like the others would not answer that.
        .opacity(isIgnored ? 0.4 : 1)
        .onTapGesture { model.selectedKey = row.key }
        .contextMenu {
            // What to do *with* this session, then what to do about seeing
            // it: the handoff is about the agent, the rules are about the
            // board, and one divider is cheaper than two menus.
            actions(for: row)
            Divider()
            SessionRowMenu(row: row, model: model, environment: environment)
        }
        .accessibilityAddTraits(.isButton)
    }

    /// The handoff menu, built from the live identity rather than from the
    /// row: a resume command needs the session id, the variant, and the
    /// working directory, and putting three more strings on every row of a
    /// four-hundred-card board to save one dictionary lookup on right-click is
    /// the wrong way round.
    @ViewBuilder
    private func actions(for row: BoardRow) -> some View {
        if let session = model.session(for: row.key) {
            SessionActionsMenu(identity: session.identity, control: environment.control)
        }
    }

    /// The finished sessions, as one-line rows under one header.
    private var endedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoardSectionHeader(
                title: "Ended",
                subtitle: "\(model.endedRows.count)",
                harness: nil
            )
            LazyVStack(spacing: 0) {
                ForEach(model.visibleEndedRows) { row in
                    EndedSessionRow(row: row, isSelected: model.selectedKey == row.key)
                        .equatable()
                        .opacity(model.ignoredKeys.contains(row.key) ? 0.4 : 1)
                        .onTapGesture(count: 2) {
                            model.selectedKey = row.key
                            model.openTrajectory()
                        }
                        .onTapGesture { model.selectedKey = row.key }
                        .contextMenu {
                            actions(for: row)
                            Divider()
                            SessionRowMenu(row: row, model: model, environment: environment)
                        }
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
                    : "Show all \(model.endedRows.count)"
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
}

/// One finished session, as a row rather than as a card.
///
/// Everything a card says about *activity* is gone, because there is none.
/// What is left is what a person looks for in history: whose session it was,
/// what it was called, where it ran, and when it stopped.
///
/// One exception, and it is the reason this section is worth scrolling to: a
/// row nobody has read since it finished keeps its mark bright, gains a green
/// dot, and says `unseen` where the others say how they ended. A finished
/// session is history; a finished session nobody has read is an errand.
struct EndedSessionRow: View, Equatable {
    let row: BoardRow
    let isSelected: Bool

    nonisolated static func == (lhs: EndedSessionRow, rhs: EndedSessionRow) -> Bool {
        lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: row.harness, size: 16, isMuted: !row.isUnseenDone)
            if row.isUnseenDone { UnseenDot() }
            Text(row.title)
                .font(AuspexType.caption)
                .foregroundStyle(row.isUnseenDone ? AuspexPalette.text : AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            if let project = row.project {
                Text(project)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Text(row.isUnseenDone ? "unseen" : reason)
                .font(AuspexType.monoSmall)
                .foregroundStyle(
                    row.isUnseenDone
                        ? AuspexPalette.stateWriting.opacity(0.8)
                        : AuspexPalette.text3
                )
                .fixedSize()
            Text(RelativeTimeText.since(row.endedAt ?? row.lastEventAt))
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

    private var reason: String {
        if case .ended(let reason) = row.state { return reason.rawValue }
        return "ended"
    }
}

/// A section drawn as a delegation tree rather than as a grid.
///
/// The rows arrive flat, each carrying the depth the model worked out, and the
/// inset is drawn from that. Flat rather than recursive because a `LazyVStack`
/// can only be lazy about a flat collection — and because a recursive view over
/// nested snapshots is exactly the shape that made the old board compare arrays
/// of them on every graph update.
struct BoardTreeColumn<Card: View>: View {
    let rows: [BoardRow]
    @ViewBuilder let card: (BoardRow) -> Card

    /// One step per level. A card is legible from about 300 points, so the
    /// inset has to be small enough that three levels still leave one room.
    private static var step: CGFloat { 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                card(row)
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.leading, Self.step * CGFloat(row.depth))
                    .overlay(alignment: .leading) {
                        // A rail per level, the same hairline device the
                        // sidebar's tree uses, so one idiom means one thing
                        // across the window.
                        HStack(spacing: 0) {
                            ForEach(0..<row.depth, id: \.self) { _ in
                                Rectangle()
                                    .fill(AuspexPalette.stateDelegating.opacity(0.35))
                                    .frame(width: 1)
                                    .frame(width: Self.step, alignment: .center)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // A crumb rather than a label: the way out of a project is the
            // first thing on the bar, in the place a person already looks for
            // it, and it is the same gesture as clicking "Live" in the sidebar
            // or pressing Escape.
            Button(action: onClear) {
                Text("All projects")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show every project on the board again — or press Escape")
            Text("›")
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
                Text("Esc")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Escape shows every project again")
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

    init(title: String, subtitle: String? = nil, liveCount: Int? = nil, harness: Harness?) {
        self.title = title
        self.subtitle = subtitle
        self.liveCount = liveCount
        self.harness = harness
    }

    /// The header for a section the grouping produced.
    ///
    /// A convenience so a caller that already holds a ``BoardGroup`` — the
    /// crew wall does — does not have to unpack the same four fields.
    init(group: BoardGroup) {
        self.init(
            title: group.title,
            subtitle: group.subtitle,
            liveCount: group.counts.live,
            harness: group.harness
        )
    }

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
