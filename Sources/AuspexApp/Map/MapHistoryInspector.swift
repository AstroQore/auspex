import AgentSessionLive
import AuspexCore
import SwiftUI

struct MapHistoryInspector: View {
    @Bindable var board: LiveBoardModel
    @Bindable var map: MapModel

    var body: some View {
        Group {
            if let moment = map.playbackMoment {
                content(card: selectedCard, moment: moment)
            } else {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "Building this Perch moment…",
                    detail:
                        "The board state at the playhead will appear here. History is read-only."
                )
                .centredInPane()
            }
        }
        .background(AuspexPalette.canvas)
        .auspexControlFocus()
    }

    private var selectedCard: MapCardValue? {
        guard let key = board.selectedKey else { return nil }
        return map.cards.first { $0.leadKey == key }
    }

    private func content(card: MapCardValue?, moment: MapPlaybackMoment) -> some View {
        let liveCount = map.cards.count { !$0.state.isEnded }
        let needsYou = map.cards.count { $0.attention.wantsPerson }
        let ended = map.cards.count { $0.state.isEnded }
        let openTools = map.cards.reduce(0) { total, card in
            total + (moment.state.sessions[card.leadKey]?.pending.openToolCalls.count ?? 0)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MOMENT · BOARD")
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.stateStale)
                    }
                    Spacer()
                    Text("HISTORY")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.stateStale)
                }

                Text(moment.event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(AuspexPalette.text)
                Text(
                    "event \(moment.index + 1) / \(moment.count) · \(moment.eventsAhead) events behind Live"
                )
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    fact("Live sessions", "\(liveCount)")
                    fact("Needs you", "\(needsYou)")
                    fact("Tools open", "\(openTools)")
                    fact("Ended", "\(ended)")
                }

                if !map.eventsSincePlayhead.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("SINCE THIS MOMENT").auspexLabel(AuspexType.labelSmall)
                        ForEach(Array(map.eventsSincePlayhead.enumerated()), id: \.offset) {
                            _, event in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(AuspexType.monoSmall)
                                    .foregroundStyle(AuspexPalette.text3)
                                Text(event.label)
                                    .font(AuspexType.caption)
                                    .foregroundStyle(AuspexPalette.text2)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if let card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECTED · CURRENT SPATIAL MEMORY").auspexLabel(AuspexType.labelSmall)
                        HStack(spacing: 8) {
                            HarnessBadge(
                                harness: card.harness, size: 22, isMuted: card.state.isEnded)
                            Text(card.title).font(AuspexType.cardTitle).lineLimit(1)
                            Spacer()
                            StatePill(
                                state: card.state, isStale: card.isStale, showsChildCount: false)
                        }
                        MetaField(key: "board", value: map.selectedBoard?.name ?? "All boards")
                        MetaField(
                            key: "position",
                            value: "\(Int(card.position.x)), \(Int(card.position.y))")
                    }
                }

                Text(
                    "Membership, state, tasks, and rules are historical. Card positions and camera stay current. History cannot Resume or edit dependencies."
                )
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AuspexPalette.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Button("Fork board here") { map.forkAtPlayhead() }
                        .font(AuspexType.pill)
                        .buttonStyle(.auspex(cornerRadius: 8))
                    Spacer()
                    Button("Jump to Live") { map.jumpToLive() }
                        .font(AuspexType.pill)
                        .buttonStyle(.auspex(cornerRadius: 8))
                }
            }
            .padding(18)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            Text(value)
                .font(AuspexType.monoCount)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuspexPalette.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
