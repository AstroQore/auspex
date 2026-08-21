import AgentSessionKit
import AgentSessionLive
import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// How big the map is allowed to get.
///
/// The office's other rules are about *stability* — a desk that does not move,
/// a gap that gets reused. These are about *bounds*, and they exist because a
/// machine that had been running agents for a week handed the layout 1,176
/// finished sessions: the camera had to sit at 6 % zoom to frame the result,
/// which is a picture of nothing.
@Suite("Scene bounds")
struct SceneBoundsTests {
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    private static func session(
        _ id: String,
        project: String? = "/Users/example/Code/auspex",
        state: SessionState = .thinking,
        endedAt: Date? = nil,
        lastEventAt: Date? = nil
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/.claude/projects/demo/\(id).jsonl",
                cwd: project,
                gitRoot: project
            ),
            state: state,
            isAlive: !state.isEnded
        )
        snapshot.endedAt = endedAt
        snapshot.lastEventAt = lastEventAt ?? endedAt
        return snapshot
    }

    private static func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: epoch, sessions: sessions)
    }

    /// The viewport the scene actually gets: the board's column in the default
    /// window, minus its chrome.
    private static let viewport = CGSize(width: 788, height: 800)

    /// What "fit all" would land on for a frame.
    private static func fitZoom(_ frame: SceneFrame) -> CGFloat {
        SceneViewport(
            content: SceneGeometry.scene(from: frame.contentRect),
            size: viewport,
            center: .zero,
            zoom: 1
        )
        .fitted()
        .zoom
    }

    // MARK: The gate

    @Test("a thousand finished sessions leave a queue, not a car park")
    func theGateDoesNotAccumulate() {
        var layout = SceneLayout()
        let ended = (0..<1_000).map { index in
            Self.session(
                "done-\(index)",
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        let frame = layout.update(with: Self.board(ended))

        let queue = frame.seats.filter { $0.kind == .gate && $0.session != nil }
        #expect(queue.count <= SceneMetrics.standard.gateQueueLimit)
        // And they are the ones that just left, not the ones that left first.
        let leaving = Set(queue.compactMap { $0.session?.sessionID })
        #expect(leaving.contains("done-0"))
        #expect(!leaving.contains("done-999"))
    }

    @Test("a session that has left leaves no desk behind either")
    func theGoneKeepNoDesk() {
        // The desk-is-held rule is for somebody who is coming back. Nothing
        // ended is, and a thousand held desks is the office this bounds.
        var layout = SceneLayout()
        let ended = (0..<400).map { index in
            Self.session(
                "done-\(index)",
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        let frame = layout.update(with: Self.board(ended))
        #expect(frame.slots.filter { !$0.isVacant }.count
            <= SceneMetrics.standard.gateQueueLimit)
    }

    // MARK: The garden

    @Test("the garden seats a bounded number per project and counts the rest")
    func theGardenOverflows() {
        var layout = SceneLayout()
        let limit = SceneMetrics.standard.breakSeatsPerProject
        let idle = (0..<(limit + 28)).map { index in
            Self.session(
                "idle-\(index)",
                state: .idle,
                lastEventAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        // Idle sessions with no process are the ones that rest on a bench.
        let frame = layout.update(with: Self.board(idle.map { snapshot in
            var copy = snapshot
            copy.isAlive = false
            return copy
        }))

        let benches = frame.seats.filter { $0.kind.isBreakRest && $0.session != nil }
        #expect(benches.count == limit)
        let garden = frame.zones.first { $0.zone == .breakArea }
        #expect(garden?.overflow == 28)
        #expect(garden?.occupancy == limit)
    }

    @Test("a busy project cannot push a quiet one's bench off the map")
    func theCapIsPerProject() {
        var layout = SceneLayout()
        let limit = SceneMetrics.standard.breakSeatsPerProject
        var sessions = (0..<(limit * 3)).map { index in
            Self.session(
                "busy-\(index)",
                project: "/Users/example/Code/auspex",
                state: .idle,
                lastEventAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        sessions.append(
            Self.session(
                "quiet-0",
                project: "/Users/example/Code/ops-runbook",
                state: .idle,
                // The oldest session on the board, and still seated: the cap
                // is per room, not a global race.
                lastEventAt: Self.epoch.addingTimeInterval(-99_999)
            )
        )
        let frame = layout.update(with: Self.board(sessions.map { snapshot in
            var copy = snapshot
            copy.isAlive = false
            return copy
        }))

        let seated = Set(
            frame.seats.compactMap { $0.kind.isBreakRest ? $0.session?.sessionID : nil }
        )
        #expect(seated.contains("quiet-0"))
        #expect(seated.count == limit + 1)
    }

    @Test("an unread note keeps its bench when a plain one gives it up")
    func notesOutrankBenches() {
        var layout = SceneLayout()
        let limit = SceneMetrics.standard.breakSeatsPerProject
        // Enough idle sessions to fill the garden twice over, plus one that
        // finished something nobody has read — the errand the whole app is
        // about, and the last thing a cap may drop.
        var sessions = (0..<(limit * 2)).map { index in
            var snapshot = Self.session(
                "idle-\(index)",
                state: .idle,
                lastEventAt: Self.epoch.addingTimeInterval(-TimeInterval(index))
            )
            snapshot.isAlive = false
            return snapshot
        }
        let note = Self.session(
            "unread",
            state: .ended(reason: .exited),
            endedAt: Self.epoch.addingTimeInterval(-999_999)
        )
        sessions.append(note)

        let frame = layout.update(
            with: Self.board(sessions),
            attention: [note.key: .doneReported(summary: "shipped", source: .agent)]
        )
        let seated = Set(
            frame.seats.compactMap { $0.kind.isWaitingBench ? $0.session?.sessionID : nil }
        )
        // Oldest on the board by a mile, and still seated.
        #expect(seated.contains("unread"))
    }

    // MARK: The world

    @Test("a week's worth of finished sessions still fits at half zoom")
    func theWorldStaysFramable() {
        var layout = SceneLayout()
        let projects = [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
            "/Users/example/Code/ingest-pipeline",
            "/Users/example/Code/mobile-client"
        ]
        var sessions = (0..<1_000).map { index in
            Self.session(
                "done-\(index)",
                project: projects[index % projects.count],
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        // A normal day's live work on top of the history.
        sessions += (0..<12).map { index in
            Self.session("live-\(index)", project: projects[index % projects.count])
        }
        let frame = layout.update(with: Self.board(sessions))

        // The whole point: the camera does not have to retreat to read it.
        #expect(Self.fitZoom(frame) >= 0.5)
        // And the map is the day's work rather than the week's history.
        #expect(frame.slots.filter { !$0.isVacant }.count < 40)
    }

    @Test("a project whose sessions have all walked out gets no suite")
    func emptyRoomsAreNotDrawn() {
        var layout = SceneLayout()
        let live = Self.session("live-0", project: "/Users/example/Code/auspex")
        var gone = (0..<40).map { index in
            Self.session(
                "gone-\(index)",
                project: "/Users/example/Code/retired",
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index + 100) * 60)
            )
        }
        // Something newer, so the retired project's sessions are the ones the
        // queue drops rather than the ones it keeps.
        gone += (0..<20).map { index in
            Self.session(
                "recent-\(index)",
                project: "/Users/example/Code/auspex",
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index))
            )
        }
        let board = Self.board([live] + gone)
        let frame = layout.update(with: board)

        // While they are leaving, the retired project still has premises: a
        // bounded queue at its own door, and the desks those few are holding.
        let queue = frame.seats.filter { $0.kind == .gate && $0.session != nil }
        #expect(queue.count <= SceneMetrics.standard.gateQueueLimit * 2)
        #expect(frame.floors.contains { $0.projectKey == "/Users/example/Code/retired" })

        // Once they have all walked out, it does not. This is the whole
        // difference between a door and a car park: whoever is at the door
        // leaves, the next few take their place, and the company that has
        // nobody left in it stops being drawn. It terminates, which is the
        // property worth asserting — an unbounded queue never drains.
        var departed: Set<SessionKey> = []
        var frames = 0
        var after = frame
        while after.seats.contains(where: { $0.kind == .gate && $0.session != nil }), frames < 100 {
            departed.formUnion(after.seats.compactMap { $0.kind == .gate ? $0.session : nil })
            after = layout.update(with: board, departed: departed)
            frames += 1
        }
        #expect(frames < 100)
        #expect(departed.count == 60)
        #expect(after.floors.map(\.projectKey) == ["/Users/example/Code/auspex"])
    }

    @Test("the day a person actually had: 1,200 sessions, windowed, then drawn")
    func theWholeWayThrough() {
        // The acceptance case, end to end: a week of bootstrapped sessions
        // goes through the recency window and then through the layout, and
        // what comes out is a map a camera can frame and a header whose
        // numbers are about the day rather than about the week.
        let projects = [
            "/Users/example/Code/auspex",
            "/Users/example/Code/storefront-web",
            "/Users/example/Code/ingest-pipeline",
            "/Users/example/Code/mobile-client"
        ]
        let week: TimeInterval = 7 * 24 * 3_600
        var sessions = (0..<1_200).map { index in
            Self.session(
                "done-\(index)",
                project: projects[index % projects.count],
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-week * TimeInterval(index) / 1_200)
            )
        }
        sessions += (0..<12).map { index in
            Self.session(
                "live-\(index)",
                project: projects[index % projects.count],
                lastEventAt: Self.epoch
            )
        }
        let raw = Self.board(sessions)

        let frame = BoardFrameAssembler.frame(
            board: raw, inputs: BoardFrameInputs(window: .twelveHours)
        )
        // The chips are about the day. Roughly a seventh of a seventh of the
        // week's finished sessions survive twelve hours.
        #expect(frame.summary.working == 12)
        #expect(frame.summary.ended < 120)
        #expect(frame.olderHidden > 1_000)
        #expect(frame.summary.ended + frame.olderHidden + 12 == 1_212)

        var layout = SceneLayout()
        let scene = layout.update(with: frame.board)
        #expect(Self.fitZoom(scene) >= 0.5)
    }

    @Test("bounding a board twice gives the same map")
    func theBoundIsTotal() {
        // The cap has to break ties the same way every frame, or the map would
        // reshuffle under the reader whenever two sessions ended in the same
        // second.
        let sessions = (0..<60).map { index in
            Self.session(
                "done-\(index)",
                state: .ended(reason: .exited),
                // Every one of them at the same instant: nothing to sort by
                // except the tiebreak.
                endedAt: Self.epoch
            )
        }
        var first = SceneLayout()
        var second = SceneLayout()
        let one = first.update(with: Self.board(sessions))
        let two = second.update(with: Self.board(sessions))
        #expect(one == two)
    }

    // MARK: One busy company

    /// A company of sixty-four, which is what a monorepo with a fleet on it
    /// looks like on a Tuesday.
    private static func crowd(_ count: Int, project: String) -> [SessionSnapshot] {
        (0..<count).map { index in
            var snapshot = session(
                "busy-\(index)",
                project: project,
                state: index.isMultiple(of: 8) ? .idle : .thinking
            )
            snapshot.lastEventAt = epoch
            snapshot.isAlive = !index.isMultiple(of: 8)
            return snapshot
        }
    }

    @Test("a sixty-four session company is a block, not a ribbon")
    func aBigSuiteIsABlock() {
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board(Self.crowd(64, project: "/Users/example/Code/monorepo"))
        )
        let suite = try? #require(frame.floors.first)
        guard let suite else { return }

        // Eight desks to a row is the wrap rule, so sixty-four desks are eight
        // rows — and the meeting room and the break room are *beside* them
        // rather than under, which is what keeps the company as wide as it is
        // tall. Under them it was 832 × 1200: a ribbon that "fit all" can only
        // frame by retreating.
        #expect(suite.rowCount == 8)
        #expect(suite.suite.width > suite.suite.height)
        // The rooms cost the suite no height at all: they stand in the space
        // eight rows of desks already occupy.
        #expect(suite.suite.height == suite.frame.height)

        let rooms = frame.zones.filter { $0.floorIndex == suite.index }
        #expect(rooms.count == 2)
        for room in rooms {
            // Beside the desks, inside the suite, and touching neither.
            #expect(room.frame.minX >= suite.frame.maxX)
            #expect(suite.suite.contains(room.frame))
        }
        // The break room is the one on the corridor, because the door is in
        // it and a door opens onto a corridor.
        let breakRoom = rooms.first { $0.zone == .breakArea }
        #expect(breakRoom.map { abs($0.frame.maxY - suite.suite.maxY) < 1 } == true)
    }

    @Test("a small company keeps the rooms under its desks")
    func aSmallSuiteIsUnchanged() {
        // The side-by-side layout is for suites whose desks are the taller
        // half. A company of four is one row of desks and a room column twice
        // its height, and putting the rooms beside it would move the empty
        // corner rather than remove it.
        var layout = SceneLayout()
        let frame = layout.update(
            with: Self.board(Self.crowd(4, project: "/Users/example/Code/small"))
        )
        let suite = try? #require(frame.floors.first)
        guard let suite else { return }
        #expect(suite.rowCount == 1)
        for room in frame.zones where room.floorIndex == suite.index {
            #expect(room.frame.minY >= suite.frame.maxY)
            #expect(abs(room.frame.minX - suite.frame.minX) < 1)
        }
    }

    @Test("a floor of busy companies is still framable")
    func aBusyCampusStaysFramable() {
        var layout = SceneLayout()
        var sessions: [SessionSnapshot] = []
        for project in ["monorepo", "storefront-web", "ingest-pipeline", "mobile-client"] {
            sessions += Self.crowd(64, project: "/Users/example/Code/\(project)")
                .map { snapshot in
                    var copy = snapshot
                    copy.identity = SessionIdentity(
                        key: SessionKey(
                            harness: snapshot.key.harness,
                            sessionID: "\(project)-\(snapshot.key.sessionID)"
                        ),
                        sourcePath: snapshot.identity.sourcePath,
                        cwd: snapshot.identity.cwd,
                        gitRoot: snapshot.identity.gitRoot
                    )
                    return copy
                }
        }
        let frame = layout.update(with: Self.board(sessions))
        #expect(frame.floors.count == 4)
        // Four blocks of 1,100 × 862 shelve two by two into 2,278 × 1,802.
        // The same board under the old layout was four ribbons of 832 × 1,200
        // and 1,742 × 2,478 — a world a third taller than it was wide, in a
        // viewport that is wider than it is tall.
        #expect(frame.contentRect.width > frame.contentRect.height)
        // 256 live sessions across four repositories is past anything this
        // app has to draw well, and the camera still frames it a little
        // closer than it used to.
        #expect(Self.fitZoom(frame) >= 0.24)
    }

    @Test("switching the annexes off is still the office it always was")
    func officeOnlyIsUntouched() {
        // `officeOnly` means "everybody stays at their desk", which is a
        // promise about the picture rather than about the bound — so nothing
        // here may quietly start removing desks in that mode.
        var layout = SceneLayout()
        let sessions = (0..<30).map { index in
            Self.session(
                "done-\(index)",
                state: .ended(reason: .exited),
                endedAt: Self.epoch.addingTimeInterval(-TimeInterval(index) * 60)
            )
        }
        let frame = layout.update(with: Self.board(sessions), zones: .officeOnly)
        #expect(frame.slots.filter { !$0.isVacant }.count == 30)
        #expect(frame.zones.isEmpty)
    }
}
