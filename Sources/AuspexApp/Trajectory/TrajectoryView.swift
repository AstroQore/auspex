import AgentSessionLive
import AuspexCore
import SwiftUI

/// One session, opened out.
///
/// The board answers *what is running*; the trace column answers *what is this
/// one doing now*. Neither answers *how did it get here*, which is the question
/// a person has when something went wrong four turns ago — and that question is
/// spatial, not chronological: it wants the shape of the session, then one step
/// out of it.
///
/// So the mode is a waterfall over a list over an inspector, in that order,
/// which is the shape browser dev tools settled on for exactly the same
/// problem. Dragging a range on the waterfall filters the list; clicking a row
/// fills the inspector; the inspector's Raw tab goes all the way back to the
/// line in the harness's own transcript.
///
/// The live trace column stays where it is. The two are not alternatives: one
/// is a feed you watch, the other is a record you take apart, and a session
/// being examined is usually one that is still running.
struct TrajectoryView: View {
    @Bindable var model: LiveBoardModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                content(for: session)
            } else {
                noSelection
            }
        }
        .background(AuspexPalette.canvas)
    }

    private func content(for session: SessionSnapshot) -> some View {
        let attention = model.attention[session.key] ?? .none
        return VStack(spacing: 0) {
            TrajectoryBar(board: model, trajectory: model.trajectory, session: session)
            // Above the waterfall, because the reason a session is in front of
            // somebody is more urgent than the shape of how it got here.
            if attention.isSignalling {
                AttentionBanner(
                    attention: attention,
                    onDismiss: { model.dismissNotice(session.key) }
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            TrajectoryTimelineView(
                model: model.trajectory,
                attention: attention,
                attentionAt: model.notices[session.key]?.createdAt ?? session.lastEventAt
            )
            TrajectoryFactsBar(model: model.trajectory)
            HStack(spacing: 0) {
                // The rows keep a floor of 200 points, and the inspector gives
                // way from 340 down to 260 rather than pushing them off the
                // end: the board's column can be dragged to 460, and 460 minus
                // a fixed 340 is a column of step rows nobody can read.
                TrajectoryStepList(model: model.trajectory)
                    .frame(minWidth: 200, maxWidth: .infinity)
                if model.trajectory.showsInspector {
                    Rectangle().fill(AuspexPalette.line).frame(width: 1)
                    TrajectoryInspector(
                        model: model.trajectory,
                        brief: session.brief
                    )
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 340)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var noSelection: some View {
        EmptyStateView(
            symbol: BoardViewMode.trajectory.systemImage,
            title: "Select a session",
            detail: "A flight is one session opened out. Pick a card to see its turns."
        )
        .centredInPane()
    }
}

// MARK: - The bar

/// Identity on the left, controls on the right — the same division the board's
/// own header makes, one row down.
private struct TrajectoryBar: View {
    @Bindable var board: LiveBoardModel
    @Bindable var trajectory: TrajectoryModel
    let session: SessionSnapshot

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// The bar, in as much of itself as the column has room for.
    ///
    /// Laid out at full width the row wants about 720 points, and the board's
    /// column is 626 at a 1280 pt window and can be dragged to 460 — so the
    /// controls used to run off the end of it, taking the back button and the
    /// session's name with them. The ladder spends the width in reverse order
    /// of what a person came here to do: the filter field narrows and then
    /// goes, the Follow toggle keeps its light but loses its word, and the
    /// back button loses "Board" before anything a person operates disappears.
    /// The scale picker and the inspector toggle never go: one says what the
    /// waterfall's width means, and the other is the only way to get the
    /// inspector back.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(searchWidth: 140, showsFollowLabel: true, showsBackLabel: true)
            bar(searchWidth: 110, showsFollowLabel: true, showsBackLabel: true)
            bar(searchWidth: 110, showsFollowLabel: false, showsBackLabel: true)
            bar(searchWidth: nil, showsFollowLabel: false, showsBackLabel: true)
            bar(searchWidth: nil, showsFollowLabel: false, showsBackLabel: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(AuspexPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    private func bar(
        searchWidth: CGFloat?,
        showsFollowLabel: Bool,
        showsBackLabel: Bool
    ) -> some View {
        HStack(spacing: 10) {
            backButton(showsLabel: showsBackLabel)
            HarnessBadge(harness: session.key.harness, size: 20, isMuted: session.state.isEnded)
            Text(title)
                .font(AuspexType.cardTitle)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                // An ideal of 60, rather than "as wide as this session's title
                // happens to be". The rung is meant to be chosen by how much
                // room the controls need, not by the length of somebody's
                // prompt — and the title truncates either way.
                .frame(idealWidth: 60, maxWidth: .infinity, alignment: .leading)
            StatePill(state: session.state, isStale: session.isStale, showsChildCount: false)
                .fixedSize()
            Spacer(minLength: 8)
            SegmentedPicker(
                selection: $trajectory.scale,
                options: TrajectoryScale.allCases.map { ($0, $0.title) }
            )
            .fixedSize()
            .help("What the timeline's width measures")
            if let searchWidth {
                searchField(width: searchWidth)
            }
            followToggle(showsLabel: showsFollowLabel)
            inspectorToggle
        }
    }

    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return session.key.sessionID
    }

    private func backButton(showsLabel: Bool) -> some View {
        Button { board.closeTrajectory() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                if showsLabel {
                    Text("Board")
                        .font(AuspexType.pill)
                }
            }
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .help("Back to the board (⌘T)")
    }

    private func searchField(width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AuspexPalette.text3)
            // `ImageRenderer` cannot draw an `NSTextField`, and a screenshot
            // with a system placeholder box where the field should be says
            // nothing true about the app.
            if isSnapshotRender {
                Text(trajectory.query.isEmpty ? "Filter steps" : trajectory.query)
                    .font(AuspexType.body)
                    .foregroundStyle(
                        trajectory.query.isEmpty ? AuspexPalette.text3 : AuspexPalette.text
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField("Filter steps", text: $trajectory.query)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AuspexPalette.bg1)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
        )
        .help("Show only the steps whose text matches")
    }

    private func followToggle(showsLabel: Bool) -> some View {
        Button { trajectory.followsTail.toggle() } label: {
            HStack(spacing: 5) {
                StateDot(
                    color: trajectory.followsTail
                        ? AuspexPalette.stateWriting
                        : AuspexPalette.text3,
                    glows: trajectory.followsTail
                )
                if showsLabel {
                    Text("Follow")
                        .font(AuspexType.pill)
                        .foregroundStyle(
                            trajectory.followsTail
                                ? AuspexPalette.stateWriting
                                : AuspexPalette.text3
                        )
                }
            }
            .fixedSize()
            .frame(minWidth: showsLabel ? nil : 22)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Follow the newest step")
        .buttonStyle(.auspex)
        .help(
            trajectory.followsTail
                ? "Stop scrolling to the newest step"
                : "Scroll to the newest step as it arrives"
        )
    }

    private var inspectorToggle: some View {
        Button { trajectory.showsInspector.toggle() } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    trajectory.showsInspector ? AuspexPalette.text : AuspexPalette.text3
                )
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .help(trajectory.showsInspector ? "Hide the inspector" : "Show the inspector")
    }
}

// MARK: - The facts strip

/// How much of the session there is, and how much of it the reader is
/// currently looking at.
private struct TrajectoryFactsBar: View {
    let model: TrajectoryModel

    var body: some View {
        HStack(spacing: 14) {
            MetaField(key: "steps", value: "\(model.steps.count)")
            MetaField(key: "turns", value: "\(model.turns.count)")
            MetaField(key: "requests", value: "\(model.requests.count)")
            if model.errorCount > 0 {
                MetaField(
                    key: "failed",
                    value: "\(model.errorCount)",
                    tint: AuspexPalette.statePermission
                )
            }
            if let tokens = model.tokens {
                MetaField(
                    key: "tokens",
                    value: "\(TokenFormat.compact(tokens.input)) / "
                        + "\(TokenFormat.compact(tokens.output))"
                )
            }
            if let elapsed = model.elapsed {
                MetaField(key: "elapsed", value: DurationFormat.short(elapsed))
            }
            Spacer(minLength: 6)
            if model.isTruncated {
                Text("first \(TrajectoryModel.eventWindow) events")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
            if model.isFiltered {
                Text("showing \(model.rows.count) of \(model.steps.count)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                Button("Clear") {
                    model.brush = nil
                    model.query = ""
                }
                .buttonStyle(.link)
                .font(AuspexType.caption)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }
}

// MARK: - The list

/// The steps, as rows.
///
/// A `ScrollView` over a `LazyVStack` rather than a `List`, for the reason the
/// trace column gives: a `List` brings its own insets, separators, selection
/// tint, and background, and after arguing all four out of it there is still no
/// way to draw a row with a red outline. The laziness that matters is the
/// stack's, and that is kept.
private struct TrajectoryStepList: View {
    @Bindable var model: TrajectoryModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.rows) { step in
                        TrajectoryRowView(
                            step: step,
                            marker: model.markers[step.id] ?? .none,
                            isSelected: model.selectedID == step.id,
                            isDimmed: false,
                            onSelect: {
                                model.selectedID = step.id
                                model.showsInspector = true
                                isFocused = true
                            }
                        )
                        .equatable()
                        .id(step.id)
                    }
                    if model.rows.isEmpty { emptyList }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.tailID) { _, tail in
                guard model.followsTail, let tail else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(tail, anchor: .bottom)
                }
            }
            .onChange(of: model.selectedID) { _, selected in
                guard let selected, isFocused else { return }
                proxy.scrollTo(selected, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { model.selectPrevious(); return .handled }
        .onKeyPress(.downArrow) { model.selectNext(); return .handled }
        .onKeyPress(.escape) {
            guard model.showsInspector else { return .ignored }
            model.showsInspector = false
            return .handled
        }
    }

    @ViewBuilder
    private var emptyList: some View {
        EmptyStateView(
            title: model.isLoading ? "Reading the event log…" : "Nothing in this range."
        ) {
            if !model.isLoading, model.isFiltered {
                Button("Show the whole session") {
                    model.brush = nil
                    model.query = ""
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
