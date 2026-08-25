import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

@Suite("Map canvas virtualization")
@MainActor
struct MapCanvasTests {
    @Test("a large map hosts only cards near the viewport")
    func visibleCardsOnly() {
        let view = MapCanvasNSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let cards = (0..<600).map { index in
            card(
                index,
                at: CGPoint(x: CGFloat(index % 20) * 360, y: CGFloat(index / 20) * 180)
            )
        }
        view.update(
            cards: cards,
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: MapViewport(boardID: MapBoard.allID, centerX: 400, centerY: 300)
        )
        view.layoutSubtreeIfNeeded()
        view.document.refreshVisibleCards(force: true)
        #expect(view.document.hostedCardCount > 0)
        #expect(view.document.hostedCardCount < 100)
    }

    @Test("history keeps drag writes disabled at the canvas seam")
    func readOnlyStateReachesCards() {
        let view = MapCanvasNSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.update(
            cards: [card(1, at: .zero)],
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: true,
            viewport: MapViewport(boardID: MapBoard.allID)
        )
        #expect(view.document.hostedCardCount <= 1)
    }

    @Test("a card update only refreshes the changed visible host")
    func changedVisibleHostOnly() {
        let view = MapCanvasNSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let viewport = MapViewport(boardID: MapBoard.allID, centerX: 400, centerY: 300)
        var cards = (0..<80).map { index in
            card(index, at: CGPoint(x: CGFloat(index % 10) * 360, y: CGFloat(index / 10) * 180))
        }
        view.update(
            cards: cards,
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: viewport
        )
        view.layoutSubtreeIfNeeded()
        view.document.refreshVisibleCards(force: true)
        let baseline = view.document.hostedSurfaceUpdateCount

        cards[79] = card(79, at: cards[79].position, state: .idle)
        view.update(
            cards: cards,
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: viewport
        )
        #expect(view.document.hostedSurfaceUpdateCount == baseline)

        cards[0] = card(0, at: cards[0].position, state: .idle)
        view.update(
            cards: cards,
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: viewport
        )
        #expect(view.document.hostedSurfaceUpdateCount == baseline + 1)
    }

    @Test("Tab-style focus and arrow navigation select spatial neighbours")
    func keyboardNavigation() {
        let view = MapCanvasNSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let cards = [
            card(1, at: CGPoint(x: 0, y: 0)),
            card(2, at: CGPoint(x: 360, y: 0)),
            card(3, at: CGPoint(x: 0, y: 180)),
        ]
        var selected: [SessionKey] = []
        view.onSelect = { selected.append($0) }
        view.update(
            cards: cards,
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: MapViewport(boardID: MapBoard.allID)
        )

        view.selectForKeyboard()
        view.moveKeyboardSelection(horizontal: 1, vertical: 0)
        view.moveKeyboardSelection(horizontal: 0, vertical: 1)

        #expect(selected == [cards[0].leadKey, cards[1].leadKey, cards[2].leadKey])
    }

    @Test("history archive rebuild retains the selected event identity")
    func historyRetainsPlayhead() {
        let first = MapPlaybackEvent.board(history(1, at: 1))
        let selected = MapPlaybackEvent.board(history(2, at: 2))
        let appended = MapPlaybackEvent.board(history(3, at: 3))
        #expect(
            MapModel.restoredHistoryIndex(
                explicit: nil,
                retainedEvent: selected,
                retainedIndex: 1,
                events: [first, selected, appended]
            ) == 1
        )
    }

    @Test("canvas-origin viewport changes are not replayed into the native scroll view")
    func viewportDoesNotFeedBack() {
        let view = MapCanvasNSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let stamp = Date(timeIntervalSince1970: 10)
        let first = MapViewport(
            boardID: MapBoard.allID,
            centerX: 200,
            centerY: 200,
            updatedAt: stamp
        )
        view.update(
            cards: [card(1, at: .zero)],
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: first
        )
        let applied = view.viewportApplyCount
        var moved = first
        moved.centerX = 480
        moved.centerY = 360
        view.update(
            cards: [card(1, at: .zero)],
            frames: [],
            dependencies: [],
            selectedNodeID: nil,
            expandedNodeIDs: [],
            isReadOnly: false,
            viewport: moved
        )
        #expect(view.viewportApplyCount == applied)
    }

    private func history(_ id: Int64, at timestamp: TimeInterval) -> MapHistoryEntry {
        MapHistoryEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: .boardUpdated,
            boardID: "board",
            payloadJSON: "{}"
        )
    }

    private func card(
        _ index: Int,
        at point: CGPoint,
        state: SessionState = .thinking
    ) -> MapCardValue {
        let key = SessionKey(harness: .codex, sessionID: "map-\(index)")
        return MapCardValue(
            id: "node-\(index)",
            unitID: "implicit:\(index)",
            taskID: nil,
            taskVersion: nil,
            dependencyIDs: [],
            leadKey: key,
            title: "Map task \(index)",
            shortID: "map-\(index)",
            harness: .codex,
            state: state,
            isStale: false,
            attention: .none,
            status: .doing,
            focus: "Testing the virtualized Map",
            projectKey: "/Users/example/Code/auspex",
            projectName: "auspex",
            memberCount: 1,
            subagents: [],
            turnCount: 1,
            toolCount: 0,
            lastEventAt: Date(timeIntervalSince1970: Double(index)),
            position: point,
            zIndex: Int64(index),
            isImplicit: true
        )
    }
}
