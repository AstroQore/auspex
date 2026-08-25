import AgentSessionLive
import AuspexCore
import SwiftUI

private enum FlightDetailTab: String, CaseIterable, Identifiable {
    case moment
    case step
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The window's detail column while Flight is open. Moment reconstructs the
/// selected event; Step preserves the existing Summary / Preview / Raw
/// inspector without making the centre column a fourth pane.
struct FlightDetailView: View {
    @Bindable var board: LiveBoardModel
    @Bindable var trajectory: TrajectoryModel
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @State private var tab: FlightDetailTab

    init(board: LiveBoardModel, trajectory: TrajectoryModel) {
        self.board = board
        self.trajectory = trajectory
        _tab = State(
            initialValue: trajectory.isHistory || trajectory.presentation == .graph
                ? .moment : .step)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch tab {
                case .moment: moment
                case .step:
                    TrajectoryInspector(
                        model: trajectory,
                        brief: board.selectedSession?.brief ?? SessionBrief()
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AuspexPalette.canvas)
        .auspexControlFocus()
        .onAppear {
            if trajectory.isHistory { tab = .moment }
        }
        .onChange(of: trajectory.isHistory) { _, history in
            if history { tab = .moment }
        }
        .onChange(of: trajectory.selectedID) { _, selected in
            if selected != nil, !trajectory.isHistory { tab = .step }
        }
        .onChange(of: trajectory.presentation) { _, presentation in
            tab =
                presentation == .graph ? .moment : (trajectory.selectedID == nil ? .moment : .step)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(trajectory.presentation == .graph ? [.moment] : FlightDetailTab.allCases) {
                option in
                Button {
                    tab = option
                } label: {
                    Text(option.title)
                        .font(AuspexType.pill)
                        .foregroundStyle(tab == option ? AuspexPalette.text : AuspexPalette.text3)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == option ? AuspexPalette.selection : .clear)
                        )
                }
                .buttonStyle(.auspex)
            }
            Spacer()
            if trajectory.isHistory {
                Text("HISTORY")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var moment: some View {
        if trajectory.presentation == .graph, let frame = trajectory.graphFrame {
            if isSnapshotRender {
                graphMomentContent(frame)
            } else {
                ScrollView { graphMomentContent(frame) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let playback = trajectory.playbackMoment {
            if isSnapshotRender {
                momentContent(playback)
            } else {
                ScrollView {
                    momentContent(playback)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: trajectory.isHistory ? "Rebuilding this event…" : "Live",
                detail: "Pause or scrub the event ruler to inspect a historical moment."
            )
            .centredInPane()
        }
    }

    private func graphMomentContent(_ frame: FlightGraphFrame) -> some View {
        let selected = trajectory.selectedAgentKey.flatMap { key in
            frame.nodes.first { $0.key == key }
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MOMENT").auspexLabel(AuspexType.labelSmall)
                    Text(frame.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(AuspexPalette.text)
                }
                Spacer()
                Text(trajectory.isHistory ? "HISTORY" : "LIVE")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(
                        trajectory.isHistory ? AuspexPalette.stateStale : AuspexPalette.stateWriting
                    )
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                fact("Agents", "\(frame.nodes.count)")
                fact("Tools open", "\(frame.openToolCount)")
                fact("Tokens", TokenFormat.compact(frame.nodes.reduce(0) { $0 + $1.tokensIn }))
                fact("Files touched", "\(filesTouched(through: frame.index))")
            }

            section("IN FLIGHT") {
                if frame.chips.isEmpty {
                    Text("Nothing is in flight at this moment.")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                } else {
                    ForEach(frame.chips) { chip in
                        HStack(spacing: 8) {
                            Image(systemName: "progress.indicator")
                                .foregroundStyle(AuspexPalette.stateTool)
                            Text(chip.name + (chip.count > 1 ? " ×\(chip.count)" : ""))
                                .font(AuspexType.mono)
                            Spacer()
                            Text(chip.session.sessionID.prefix(8))
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text3)
                        }
                    }
                }
            }

            section("SELECTED AGENT") {
                if let selected {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            HarnessBadge(
                                harness: selected.key.harness, size: 24,
                                isMuted: selected.state.isEnded)
                            Text(selected.title)
                                .font(AuspexType.cardTitle)
                                .foregroundStyle(AuspexPalette.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        StatePill(
                            state: selected.state, isStale: selected.isStale, showsChildCount: false
                        )
                        .fixedSize()
                        MetaField(key: "session", value: String(selected.key.sessionID.prefix(12)))
                        MetaField(key: "turns", value: "\(selected.turnCount)")
                        MetaField(key: "tools", value: "\(selected.toolCount)")
                        MetaField(
                            key: "tokens",
                            value:
                                "\(TokenFormat.compact(selected.tokensIn)) / \(TokenFormat.compact(selected.tokensOut))"
                        )
                    }
                    .padding(10)
                    .background(AuspexPalette.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(
                        "Click a graph node to pin its details here. Follow glides to current activity; pan or zoom enters Manual."
                    )
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                }
            }

            if trajectory.isHistory {
                HStack {
                    Text("Live is \(trajectory.eventsAhead) events ahead")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                    Spacer()
                    Button("Jump to Live") { trajectory.jumpToLive() }
                        .font(AuspexType.pill)
                        .buttonStyle(.auspex(cornerRadius: 7))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func momentContent(_ playback: MapPlaybackMoment) -> some View {
        let snapshots = momentSnapshots(playback)
        let tools = snapshots.flatMap { $0.pending.openToolCalls.values }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AT PLAYHEAD").auspexLabel(AuspexType.labelSmall)
                    Text(playback.event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(AuspexPalette.text)
                }
                Spacer()
                Text("event \(playback.index + 1) / \(playback.count)")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                fact("Agents", "\(snapshots.count)")
                fact("Tools open", "\(tools.count)")
                fact("Tokens", TokenFormat.compact(snapshots.reduce(0) { $0 + $1.tokensIn }))
                fact("Files touched", "\(filesTouched(through: playback.index))")
            }

            section("AGENTS AT THIS MOMENT") {
                ForEach(snapshots, id: \.identity.key) { snapshot in
                    HStack(spacing: 8) {
                        HarnessBadge(
                            harness: snapshot.identity.key.harness,
                            size: 20,
                            isMuted: snapshot.state.isEnded
                        )
                        Text(snapshot.identity.title ?? snapshot.identity.key.sessionID)
                            .font(AuspexType.caption)
                            .foregroundStyle(AuspexPalette.text2)
                            .lineLimit(1)
                        Spacer()
                        StatePill(
                            state: snapshot.state,
                            isStale: snapshot.isStale,
                            showsChildCount: false
                        )
                    }
                    .padding(8)
                    .background(AuspexPalette.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            section("IN FLIGHT") {
                if tools.isEmpty {
                    Text("No tool was open at this event.")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                } else {
                    ForEach(tools, id: \.id) { tool in
                        HStack(spacing: 8) {
                            Image(systemName: "progress.indicator")
                                .foregroundStyle(AuspexPalette.stateTool)
                            Text(tool.name)
                                .font(AuspexType.mono)
                                .foregroundStyle(AuspexPalette.text)
                            Text(tool.target.map(PathDisplay.abbreviate) ?? tool.kind.rawValue)
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text3)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }

            HStack {
                Text("Live is \(playback.eventsAhead) events ahead")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                Spacer()
                Button("Jump to Live") { trajectory.jumpToLive() }
                    .font(AuspexType.pill)
                    .buttonStyle(.auspex(cornerRadius: 7))
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func momentSnapshots(_ playback: MapPlaybackMoment) -> [SessionSnapshot] {
        let keys = trajectory.scope == .task ? trajectory.lanes : trajectory.key.map { [$0] } ?? []
        return keys.compactMap { playback.state.sessions[$0] }
    }

    private func filesTouched(through index: Int) -> Int {
        guard !trajectory.events.isEmpty else { return 0 }
        let end = min(index, trajectory.events.count - 1)
        var paths: Set<String> = []
        for event in trajectory.events[0...end] {
            guard case .toolCallStarted(_, _, let kind, let target) = event.kind,
                kind == .fileRead || kind == .fileWrite,
                let target
            else { continue }
            paths.insert(target)
        }
        return paths.count
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).auspexLabel(AuspexType.labelSmall)
            Text(value)
                .font(AuspexType.monoCount)
                .foregroundStyle(AuspexPalette.text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuspexPalette.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            content()
        }
    }
}
