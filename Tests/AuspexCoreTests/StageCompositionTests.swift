import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What Now's stage draws: the rooms with people in them, one desk per person,
/// urgent rooms first, packed into the strip and framed to fit it.
@Suite("Stage composition")
struct StageCompositionTests {
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    /// The design's stage: a window's content column, 380 points tall.
    private static let strip = CGSize(width: 1_020, height: 380)

    private static func session(
        _ id: String,
        project: String? = "/Users/example/Code/atlas",
        parent: SessionKey? = nil,
        state: SessionState = .idle,
        isAlive: Bool = true
    ) -> SessionSnapshot {
        SessionSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                parent: parent,
                cwd: project,
                gitRoot: project
            ),
            state: state,
            isAlive: isAlive && !state.isEnded
        )
    }

    private static func key(_ id: String) -> SessionKey {
        SessionKey(harness: .claudeCode, sessionID: id)
    }

    private static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: epoch, sessions: sessions)
    }

    @Test("Only rooms with people in them are drawn, with one desk per person and none empty")
    func onlyLiveRoomsAndOccupiedDesks() {
        let board = Self.board([
            Self.session("a1", project: "/Users/example/Code/atlas"),
            Self.session("a2", project: "/Users/example/Code/atlas", state: .thinking),
            Self.session("a3", project: "/Users/example/Code/atlas", state: .ended(reason: .exited)),
            Self.session("b1", project: "/Users/example/Code/harbor", state: .ended(reason: .exited)),
            Self.session("c1", project: "/Users/example/Code/orchard", isAlive: false),
        ])
        let stage = StageComposer.compose(board: board, viewSize: Self.strip)

        #expect(stage.frame.floors.map(\.title) == ["atlas"])
        #expect(stage.frame.slots.count == 2)
        #expect(stage.frame.slots.allSatisfy { $0.isOccupied })
        #expect(Set(stage.frame.slots.compactMap(\.session)) == [Self.key("a1"), Self.key("a2")])
        // No annexes: nobody can walk anywhere, and nothing waits at a door.
        #expect(stage.frame.seats.isEmpty)
        #expect(stage.frame.zones.isEmpty)
        #expect(stage.frame.tables.isEmpty)
    }

    @Test("A session asking for a person is on the stage even once its process is gone")
    func askingIsAlwaysOnStage() {
        let board = Self.board([Self.session("gone", state: .ended(reason: .exited))])
        let attention: [SessionKey: AttentionState] = [
            Self.key("gone"): .needsYou(reason: "Ship it?", source: .agent)
        ]
        let stage = StageComposer.compose(board: board, attention: attention, viewSize: Self.strip)
        #expect(stage.frame.slots.compactMap(\.session) == [Self.key("gone")])
    }

    @Test("Rooms run needs you, may need you, working, idle — from the top left")
    func roomsAreOrderedByUrgency() throws {
        let board = Self.board([
            Self.session("idle", project: "/Users/example/Code/aardvark"),
            Self.session("busy", project: "/Users/example/Code/beacon", state: .toolCalling(name: "Bash")),
            Self.session("watched", project: "/Users/example/Code/cobalt"),
            Self.session("blocked", project: "/Users/example/Code/dune", state: .waitingPermission(tool: "Bash")),
        ])
        let stage = StageComposer.compose(
            board: board, watched: [Self.key("watched")], viewSize: Self.strip
        )
        #expect(stage.frame.floors.map(\.title) == ["dune", "cobalt", "beacon", "aardvark"])

        // Reading order is the drawing order: each room starts to the right
        // of, or below, the one before it.
        let frames = stage.frame.floors.map(\.frame)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.minY > earlier.minY || (later.minY == earlier.minY && later.minX > earlier.minX))
        }
        let first = try #require(frames.first)
        #expect(first.minX == StageComposer.Insets.stage.left / stage.zoom)
        #expect(first.minY == StageComposer.Insets.stage.top / stage.zoom)
    }

    @Test("Inside a room the people who want the reader sit first")
    func peopleAreOrderedByUrgencyInsideARoom() {
        let board = Self.board([
            Self.session("a-idle"),
            Self.session("b-working", state: .thinking),
            Self.session("c-blocked", state: .waitingPermission(tool: nil)),
        ])
        let stage = StageComposer.compose(board: board, viewSize: Self.strip)
        let order = stage.frame.slots.sorted { $0.anchor.x < $1.anchor.x }.compactMap(\.session)
        #expect(order == [Self.key("c-blocked"), Self.key("b-working"), Self.key("a-idle")])
    }

    @Test("A subagent is its parent's ↳N, not a second person, and its balloon hangs over the parent")
    func subagentsFoldIntoTheirParent() throws {
        let parent = Self.key("parent")
        let board = Self.board([
            Self.session("parent", state: .delegating(children: 2)),
            Self.session("child-1", parent: parent, state: .toolCalling(name: "Grep")),
            Self.session("child-2", parent: parent, state: .thinking),
            Self.session("grandchild", parent: Self.key("child-1"), state: .thinking),
        ])
        let stage = StageComposer.compose(board: board, viewSize: Self.strip)
        let slot = try #require(stage.frame.slots.first)
        #expect(stage.frame.slots.count == 1)
        #expect(slot.session == parent)
        #expect(slot.childCount == 3)
        #expect(stage.deskFor[Self.key("child-1")] == parent)
        #expect(stage.deskFor[Self.key("grandchild")] == parent)
        #expect(stage.frame.tethers.isEmpty)
    }

    @Test("A subagent whose parent has left the stage is a person of its own")
    func orphanStandsAlone() {
        let board = Self.board([
            Self.session("parent", state: .ended(reason: .exited)),
            Self.session("orphan", parent: Self.key("parent"), state: .thinking),
        ])
        let stage = StageComposer.compose(board: board, viewSize: Self.strip)
        #expect(stage.frame.slots.compactMap(\.session) == [Self.key("orphan")])
        #expect(stage.deskFor.isEmpty)
    }

    @Test("A small board is framed at 1×, and the frame is the strip itself")
    func smallBoardFitsAtFullSize() {
        let board = Self.board((0..<4).map { Self.session("s\($0)", state: .thinking) })
        let stage = StageComposer.compose(board: board, viewSize: Self.strip)
        #expect(stage.zoom == 1)
        #expect(stage.hiddenRooms == 0)
        #expect(stage.overflowTile == nil)
        #expect(stage.frame.contentRect == CGRect(origin: .zero, size: Self.strip))
    }

    @Test("A board too big for 1× is framed at ½×, never further out")
    func biggerBoardsPullBackToHalf() {
        // Eight rooms of three: three shelves, one more than 1× holds.
        let projects = (0..<8).map { "/Users/example/Code/p\($0)" }
        let sessions = projects.enumerated().flatMap { index, project in
            (0..<3).map { Self.session("p\(index)-\($0)", project: project) }
        }
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)
        #expect(stage.zoom == 0.5)
        #expect(stage.hiddenRooms == 0)
        #expect(stage.frame.slots.count == sessions.count)
        #expect(stage.frame.contentRect.size == CGSize(width: Self.strip.width * 2, height: Self.strip.height * 2))
    }

    @Test("What does not fit folds into a +N rooms tile, and the urgent rooms are the ones kept")
    func overflowFoldsTheQuietRooms() throws {
        // Forty rooms of three: far more than a strip holds at ½×.
        var sessions: [SessionSnapshot] = []
        for index in 0..<40 {
            let project = String(format: "/Users/example/Code/room%02d", index)
            for seat in 0..<3 { sessions.append(Self.session("r\(index)-\(seat)", project: project)) }
        }
        // The last room alphabetically is the one asking for somebody.
        sessions.append(Self.session("asking", project: "/Users/example/Code/room39", state: .waitingPermission(tool: "Bash")))
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)

        #expect(stage.zoom == 0.5)
        #expect(stage.hiddenRooms > 0)
        #expect(stage.frame.floors.count + stage.hiddenRooms == 40)
        #expect(stage.frame.floors.first?.title == "room39")
        #expect(stage.frame.slots.contains { $0.session == Self.key("asking") })

        let tile = try #require(stage.overflowTile)
        #expect(stage.frame.contentRect.contains(tile))
        for floor in stage.frame.floors {
            #expect(!floor.frame.intersects(tile))
        }
    }

    @Test("Nothing is laid out under the strip's own chrome")
    func roomsStayClearOfTheChrome() {
        let projects = (0..<9).map { "/Users/example/Code/p\($0)" }
        let sessions = projects.enumerated().flatMap { index, project in
            (0..<4).map { Self.session("p\(index)-\($0)", project: project) }
        }
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)
        let insets = StageComposer.Insets.stage
        let zoom = stage.zoom
        let usable = CGRect(
            x: insets.left / zoom,
            y: insets.top / zoom,
            width: (Self.strip.width - insets.left - insets.right) / zoom,
            height: (Self.strip.height - insets.top - insets.bottom) / zoom
        )
        for floor in stage.frame.floors {
            #expect(usable.insetBy(dx: -0.5, dy: -0.5).contains(floor.frame))
        }
        // And no two rooms overlap.
        let frames = stage.frame.floors.map(\.frame)
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] { #expect(!frame.intersects(other)) }
        }
    }

    @Test("A room too big for the strip keeps the rows that fit, urgent people first")
    func oversizedRoomIsCutShortFromTheQuietEnd() {
        var sessions = (0..<200).map { Self.session(String(format: "idle-%03d", $0)) }
        sessions.append(Self.session("zz-working", state: .thinking))
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)
        #expect(stage.frame.floors.count == 1)
        #expect(stage.zoom == 0.5)
        #expect(stage.hiddenRooms == 0)
        #expect(stage.overflowTile == nil)
        #expect(stage.frame.slots.count < sessions.count)
        #expect(stage.frame.slots.first?.session == Self.key("zz-working"))
    }

    @Test("Desks are keyed by their session, so a person whose room moves keeps the same desk")
    func desksAreKeyedBySession() {
        let quiet = Self.board([
            Self.session("a", project: "/Users/example/Code/atlas"),
            Self.session("h", project: "/Users/example/Code/harbor"),
        ])
        let loud = Self.board([
            Self.session("a", project: "/Users/example/Code/atlas"),
            Self.session("h", project: "/Users/example/Code/harbor", state: .waitingPermission(tool: nil)),
        ])
        let before = StageComposer.compose(board: quiet, viewSize: Self.strip)
        let after = StageComposer.compose(board: loud, viewSize: Self.strip)
        #expect(Set(before.frame.slots.map(\.id)) == Set(after.frame.slots.map(\.id)))
        #expect(before.frame.floors.first?.title == "atlas")
        #expect(after.frame.floors.first?.title == "harbor")
    }

    @Test("Nine one-person rooms — the demo's tour — still fit at 1×")
    func onePersonRoomsFitAtFullSize() {
        let names = ["grok-bot", "ingest-pipeline", "mobile-client", "auspex", "codex-scratch",
                     "infra-terraform", "ops-runbook", "storefront-web", "design-tokens"]
        let sessions = names.map { Self.session($0, project: "/Users/example/Code/\($0)", state: .thinking) }
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)
        #expect(stage.zoom == 1)
        #expect(stage.frame.floors.count == 9)
        // And a person in a room wider than their desk sits in its middle.
        for floor in stage.frame.floors {
            let slot = stage.frame.slots.first { $0.floorIndex == floor.index }
            #expect(slot.map { abs($0.anchor.x - floor.frame.midX) < 0.5 } == true)
        }
    }

    @Test("A room is wide enough for its name at the zoom it is drawn at")
    func roomsCarryTheirNames() throws {
        // Enough one-person rooms that the stage is laid out at ½×, where a
        // nameplate is drawn at twice its size on the map.
        let names = (0..<20).map { String(format: "storefront-web-%02d", $0) }
        let sessions = names.map { Self.session($0, project: "/Users/example/Code/\($0)") }
        let stage = StageComposer.compose(board: Self.board(sessions), viewSize: Self.strip)
        #expect(stage.zoom == 0.5)
        for floor in stage.frame.floors {
            // Condensed capitals are well under 8.5 points a character at
            // twelve points; doubled, plus the plate's insets.
            #expect(floor.frame.width >= (CGFloat(floor.title.count) * 8.5 + 24) * 2)
        }
    }

    @Test("Nobody on the stage is an empty composition")
    func emptyBoardIsEmpty() {
        let board = Self.board([Self.session("done", state: .ended(reason: .exited))])
        #expect(StageComposer.compose(board: board, viewSize: Self.strip) == .empty)
        #expect(StageComposer.compose(board: Self.board([]), viewSize: .zero) == .empty)
    }
}
