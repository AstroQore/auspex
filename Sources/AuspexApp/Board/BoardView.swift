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
        Group {
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
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group.sessions, id: \.key) { session in
                                card(for: session)
                            }
                        }
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

    private func card(for session: SessionSnapshot) -> some View {
        SessionCard(
            session: session,
            isSelected: model.selectedKey == session.key,
            reduceMotion: reduceMotion
        )
            .equatable()
            .onTapGesture { model.selectedKey = session.key }
            .accessibilityAddTraits(.isButton)
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
