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
        let limit = SceneMetrics.standard.gardenSeatsPerProject
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

        let benches = frame.seats.filter { $0.kind.isGardenRest && $0.session != nil }
        #expect(benches.count == limit)
        let garden = frame.zones.first { $0.zone == .garden }
        #expect(garden?.overflow == 28)
        #expect(garden?.occupancy == limit)
    }

    @Test("a busy project cannot push a quiet one's bench off the map")
    func theCapIsPerProject() {
        var layout = SceneLayout()
        let limit = SceneMetrics.standard.gardenSeatsPerProject
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
            frame.seats.compactMap { $0.kind.isGardenRest ? $0.session?.sessionID : nil }
        )
        #expect(seated.contains("quiet-0"))
        #expect(seated.count == limit + 1)
    }

    @Test("an unread note keeps its bench when a plain one gives it up")
    func notesOutrankBenches() {
        var layout = SceneLayout()
        let limit = SceneMetrics.standard.gardenSeatsPerProject
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
            with: Self.board(sessions), unseenDone: [note.key]
        )
        let seated = Set(
            frame.seats.compactMap { $0.kind.isGardenRest ? $0.session?.sessionID : nil }
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

    @Test("a project whose sessions have all gone gets no room")
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
        let frame = layout.update(with: Self.board([live] + gone))

        #expect(frame.floors.map(\.projectKey) == ["/Users/example/Code/auspex"])
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
