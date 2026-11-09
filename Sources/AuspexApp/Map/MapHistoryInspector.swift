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
                    title: L10n.Perch.History.building,
                    detail: L10n.Perch.History.buildingDetail
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
                        Text(L10n.Perch.History.momentBoard.uppercased())
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.stateStale)
                    }
                    Spacer()
                    Text(L10n.Perch.history.uppercased())
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.stateStale)
                }

                Text(AppLocale.time(moment.event.timestamp))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(AuspexPalette.text)
                Text(
                    L10n.Perch.History.since(
                        index: moment.index + 1,
                        count: moment.count,
                        behind: moment.eventsAhead
                    )
                )
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    fact(L10n.Perch.History.liveSessions, "\(liveCount)")
                    fact(L10n.Now.needsYou, "\(needsYou)")
                    fact(L10n.Perch.History.toolsOpen, "\(openTools)")
                    fact(L10n.Board.Ended.title, "\(ended)")
                }

                if !map.eventsSincePlayhead.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.Perch.History.sinceMoment.uppercased()).auspexLabel(AuspexType.labelSmall)
                        ForEach(Array(map.eventsSincePlayhead.enumerated()), id: \.offset) {
                            _, event in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(AppLocale.time(event.timestamp))
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
                        Text(L10n.Perch.History.selected.uppercased()).auspexLabel(AuspexType.labelSmall)
                        HStack(spacing: 8) {
                            HarnessBadge(
                                harness: card.harness, size: 22, isMuted: card.state.isEnded)
                            Text(card.title).font(AuspexType.cardTitle).lineLimit(1)
                            Spacer()
                            StatePill(
                                state: card.state, isStale: card.isStale, showsChildCount: false)
                        }
                        MetaField(key: L10n.Perch.History.board, value: map.selectedBoard?.name ?? L10n.Perch.allBoards)
                        MetaField(
                            key: L10n.Perch.History.position,
                            value: "\(Int(card.position.x)), \(Int(card.position.y))")
                    }
                }

                Text(
                    L10n.Perch.History.note
                )
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AuspexPalette.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Button(L10n.Perch.fork) { map.forkAtPlayhead() }
                        .font(AuspexType.pill)
                        .buttonStyle(.auspex(cornerRadius: 8))
                    Spacer()
                    Button(L10n.Perch.jumpToLive) { map.jumpToLive() }
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
