import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The wall.
///
/// A scrolling grid of **task** cards — one per piece of work, with the
/// sessions doing it folded inside — divided into sections by whatever the
/// header's grouping menu says, with the finished ones collected into one
/// collapsed section at the bottom.
///
/// ## Why the unit is a task
///
/// A session is a process. Half the processes on a busy machine are subagents:
/// a step inside somebody else's job, spawned and finished inside one turn.
/// Drawing each as a peer of the thing that spawned it produced a wall where a
/// delegation of four read as four independent pieces of work, and the reader
/// had to reassemble the family in their head every time they looked at it.
/// See ``TaskUnit``.
///
/// It is also the board's largest performance property after the ended fold:
/// folding subagents roughly halves the number of cards a real machine draws,
/// and it does it by removing exactly the cards with the least to say.
///
/// ## Why the finished ones are not cards
///
/// A machine that has run agents for a week has a few dozen live sessions and
/// several hundred finished ones. A finished unit has no state to watch,
/// nothing to animate, and nothing anybody has to act on — so it leaves the
/// grid entirely and the board's cost scales with what is *running*. Work
/// waiting to be reviewed is not finished and stays on the wall, however dead
/// its processes.
///
/// ## Why only some sections are laid out
///
/// A `LazyVGrid` inside a `LazyVStack` is not lazy: the outer stack has to
/// know how tall each section is before it can place the next one, so every
/// section's grid is laid out on the first pass whether or not it is anywhere
/// near the viewport. On a machine with sixty projects that pass was the
/// largest thing on the main thread — `LazyStack.initialPlacement →
/// boundingRect → applyNodes`. So a section past the first handful draws as a
/// one-line header until it is scrolled to, at which point it opens and stays
/// open. See ``eagerSections``.
struct BoardView: View {
    @Bindable var model: LiveBoardModel

    private let columns = [
        GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14, alignment: .top)
    ]

    /// How many sections are laid out before the reader has scrolled anywhere.
    ///
    /// Six is comfortably more than fits on a laptop screen at this card
    /// width, so the wall a person opens onto is complete; everything past it
    /// costs one line until they reach it. The number is a bound on the
    /// *initial placement* pass, which is the one that was measured.
    private static let eagerSections = 6

    /// The sections whose cards are drawn: the first few, plus everything the
    /// reader has scrolled past.
    ///
    /// Grows and never shrinks within a launch. Collapsing a section again on
    /// its way off screen would halve the steady-state cost and buy a wall
    /// that reflows under the reader's cursor every time they scroll back —
    /// a bad trade for a board somebody watches all day.
    @State private var revealed: Set<String> = []

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.focusedProjectName {
                ProjectFilterBar(name: name, path: model.focusedProjectKey ?? "") {
                    model.focusedProjectKey = nil
                }
            }
            if !model.filters.isEmpty { TaskFilterBar(model: model) }
            if model.unitGroups.isEmpty, model.endedUnits.isEmpty {
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
                ForEach(Array(model.unitGroups.enumerated()), id: \.element.id) { index, group in
                    section(group, isEager: index < Self.eagerSections)
                }
                if !model.endedUnits.isEmpty { endedSection }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One section: its header, then its milestones, then their cards — unless
    /// it is past the fold and has not been reached yet, in which case the
    /// header is the whole of it.
    @ViewBuilder
    private func section(_ group: TaskUnitGroup, isEager: Bool) -> some View {
        let isOpen = isEager || revealed.contains(group.id)
        VStack(alignment: .leading, spacing: 12) {
            BoardSectionHeader(
                title: group.title,
                subtitle: isOpen ? group.subtitle : "\(group.unitCount)",
                liveCount: isOpen ? group.liveCount : nil,
                harness: group.harness
            )
            if isOpen {
                ForEach(group.milestones) { milestone in
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = milestone.title { MilestoneHeader(title: title) }
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(milestone.units) { unit in
                                card(for: unit)
                            }
                        }
                    }
                }
            }
        }
        // The signal that this section has been scrolled to. A lazy stack
        // builds a subview when it comes into range and this is the cheapest
        // thing that can be hung off that; the collapsed header is one line,
        // so the wall's scroll extent is right before anything opens.
        .onAppear {
            guard !isEager, !revealed.contains(group.id) else { return }
            revealed.insert(group.id)
        }
    }

    private func card(for unit: TaskUnit) -> some View {
        TaskCard(
            unit: unit,
            isSelected: model.selectedUnit?.id == unit.id,
            isExpanded: model.isExpanded(unit),
            onToggleExpanded: { model.toggleExpanded(unit) },
            onOpenDetail: { model.openUnitID = unit.id },
            onSelectMember: { model.selectedKey = $0 },
            // Only when there is something to clear, so the closure stays out
            // of `==` for the ordinary card.
            onDismissNotice: unit.attentionKey.map { key in
                { model.dismissNotice(key) }
            }
        )
        .equatable()
        .opacity(model.ignoredKeys.contains(unit.lead.key) ? 0.4 : 1)
        .onTapGesture(count: 2) { model.openUnitID = unit.id }
        .onTapGesture { model.selectedKey = unit.lead.key }
        // A card is what a person drags onto a task to say "this work is that
        // task". The lead's key, because that is the session a claim records.
        .draggable(TaskDragPayload.session(unit.lead.key))
        .contextMenu { TaskCardMenu(unit: unit, model: model, environment: environment) }
        .accessibilityAddTraits(.isButton)
    }

    /// The finished units, as one-line rows under one header.
    private var endedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoardSectionHeader(
                title: "Ended",
                subtitle: "\(model.endedUnits.count)",
                harness: nil
            )
            LazyVStack(spacing: 0) {
                ForEach(model.visibleEndedUnits) { unit in
                    EndedTaskRow(unit: unit, isSelected: model.selectedUnit?.id == unit.id)
                        .equatable()
                        .onTapGesture(count: 2) { model.openUnitID = unit.id }
                        .onTapGesture { model.selectedKey = unit.lead.key }
                        .contextMenu {
                            TaskCardMenu(unit: unit, model: model, environment: environment)
                        }
                }
            }
            .panelChrome()
            HStack(spacing: 10) {
                if model.hiddenEndedUnitCount > 0 || model.showsAllEnded {
                    showAllToggle
                }
                if let hint = model.olderHiddenHint {
                    olderHiddenToggle(hint)
                }
            }
        }
    }

    /// The window's own hint, and the menu that widens it.
    private func olderHiddenToggle(_ hint: String) -> some View {
        SessionWindowMenu(
            window: model.sessionWindow,
            hint: nil,
            onSelect: { environment.catalog.setSessionWindow($0) }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text(hint).font(AuspexType.caption)
            }
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AuspexPalette.line, lineWidth: 1)
        )
        .help("Older sessions are in the store, not on the board. Widen to draw them.")
    }

    private var showAllToggle: some View {
        Button {
            model.showsAllEnded.toggle()
        } label: {
            Text(
                model.showsAllEnded
                    ? "Show the most recent \(EndedSessions.collapsedLimit)"
                    : "Show all \(model.endedUnits.count)"
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
        .buttonStyle(.auspex)
        .help("Finished work is collapsed so the board's cost tracks what is running")
    }
}

/// A milestone's sub-heading inside a project's section.
///
/// A rule with a word on it rather than a second section header: a milestone
/// is a *label inside* a project, not a container beside it, and giving it the
/// same weight as the project would be saying the containment runs the other
/// way.
struct MilestoneHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AuspexPalette.text3)
            Text(title)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
            Rectangle()
                .fill(AuspexPalette.line.opacity(0.6))
                .frame(height: 1)
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One finished piece of work, as a row rather than as a card.
///
/// Everything about *activity* is gone, because there is none. What is left is
/// what a person looks for in history: what it was called, whose it was, where
/// it ran, and when it stopped.
struct EndedTaskRow: View, Equatable {
    let unit: TaskUnit
    let isSelected: Bool

    nonisolated static func == (lhs: EndedTaskRow, rhs: EndedTaskRow) -> Bool {
        lhs.unit == rhs.unit && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            TaskStatusIcon(status: unit.status, size: 12, isMuted: true)
            HarnessBadge(harness: unit.lead.harness, size: 14, isMuted: true)
            Text(unit.title)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            if unit.memberCount > 1 {
                Text("↳ \(unit.subagents.count)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
            }
            if let project = unit.lead.project {
                Text(project)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Text(unit.shortID)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3.opacity(0.7))
                .fixedSize()
            Text(RelativeTimeText.since(unit.endedAt ?? unit.lastEventAt))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(isSelected ? AuspexPalette.selection : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
            .buttonStyle(.auspex)
            .help("Show every project on the board again — or press Escape")
            Text("›")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Text(name)
                .font(AuspexType.rowStrong)
                .foregroundStyle(AuspexPalette.text)
            // A pseudo project's key is a tag, not a place; the title has
            // already said everything there is to say about it.
            if !PseudoProject.isPseudo(path) {
                Text(PathDisplay.abbreviate(path))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
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
            .buttonStyle(.auspex)
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
