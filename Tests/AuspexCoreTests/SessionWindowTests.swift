import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// How far back the board reaches, and what it is never allowed to leave out.
///
/// The window exists because the registry bootstraps a week and the picture
/// cannot draw one: a machine that has been running agents all week had 1,176
/// finished sessions on the map. What matters is not that it hides things —
/// any cut-off would — but *which* things it refuses to hide.
@Suite("Session window")
struct SessionWindowTests {
    /// `now` for every case below. Sessions are placed at negative offsets
    /// from it, so "six hours old" reads as `-6 * hour`.
    private static let now = Fixtures.date(0)
    private static let hour: TimeInterval = 3_600

    private func session(
        _ id: String,
        state: SessionState = .ended(reason: .exited),
        isAlive: Bool = false,
        lastEventAt: Date?,
        startedAt: Date? = nil
    ) -> SessionSnapshot {
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: SessionKey(harness: .claudeCode, sessionID: id),
                sourcePath: "/Users/example/store/\(id).jsonl",
                cwd: "/Users/example/Code/widget",
                gitRoot: "/Users/example/Code/widget"
            )
        )
        snapshot.state = state
        snapshot.isAlive = isAlive
        snapshot.lastEventAt = lastEventAt
        snapshot.startedAt = startedAt
        return snapshot
    }

    // MARK: The scale

    @Test("the default is twelve hours, and every step is longer than the last")
    func theScaleIsOrdered() {
        #expect(SessionWindow.standard == .twelveHours)
        let finite = SessionWindow.allCases.compactMap(\.duration)
        #expect(finite == finite.sorted())
        // Exactly one has no limit, and it is the last one offered.
        #expect(SessionWindow.allCases.filter { $0.duration == nil } == [.all])
        #expect(SessionWindow.allCases.last == .all)
    }

    @Test("every step has a menu label and a short one, and no two share either")
    func everyStepIsNameable() {
        let titles = SessionWindow.allCases.map(\.title)
        let short = SessionWindow.allCases.map(\.shortTitle)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(Set(short).count == short.count)
    }

    @Test("a window round-trips through JSON")
    func windowRoundTripsThroughSettings() throws {
        // It lives in `~/.auspex/settings.json`, so a renamed case is a
        // migration rather than a silent reset to the default.
        for window in SessionWindow.allCases {
            var settings = AuspexSettings()
            settings.sessionWindow = window
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(AuspexSettings.self, from: data).sessionWindow == window)
        }
    }

    @Test("a settings file written before the window existed opens on the default")
    func absentKeyIsTheDefault() throws {
        let data = Data(#"{"ignoreRules":[],"showsIgnored":false}"#.utf8)
        let settings = try JSONDecoder().decode(AuspexSettings.self, from: data)
        // Not `.all`: opening the week of history that made the window
        // necessary is exactly the picture this fixes.
        #expect(settings.sessionWindow == .standard)
        #expect(settings.isEmpty)
    }

    // MARK: What it keeps

    @Test("inside the window is kept, outside it is not")
    func theBoundary() {
        let window = SessionWindow.twelveHours
        let inside = session("in", lastEventAt: Self.now.addingTimeInterval(-11 * Self.hour))
        let outside = session("out", lastEventAt: Self.now.addingTimeInterval(-13 * Self.hour))
        #expect(SessionRecency.isVisible(inside, in: window, now: Self.now))
        #expect(!SessionRecency.isVisible(outside, in: window, now: Self.now))
    }

    @Test("the boundary itself is inside — a session exactly 12 h old is drawn")
    func theBoundaryIsInclusive() {
        // Inclusive rather than exclusive so that "12 hours" means the last
        // twelve hours and not the last twelve hours minus an instant. The
        // case it actually protects is a session whose only timestamp is the
        // window's own edge.
        let edge = session("edge", lastEventAt: Self.now.addingTimeInterval(-12 * Self.hour))
        #expect(SessionRecency.isVisible(edge, in: .twelveHours, now: Self.now))
    }

    @Test("alive, working and needs-you are drawn however old they are")
    func theExemptions() {
        let ancient = Self.now.addingTimeInterval(-30 * 24 * Self.hour)
        // A live process that happens to be between turns.
        let alive = session("alive", state: .idle, isAlive: true, lastEventAt: ancient)
        // Something still working — the process may be gone and the session
        // wrong about it, which is a thing to show rather than to hide.
        let working = session("work", state: .thinking, lastEventAt: ancient)
        // The one card that must never be hidden by a clock that has been
        // running *because* nobody answered it.
        let blocked = session(
            "blocked", state: .waitingPermission(tool: "Bash"), lastEventAt: ancient
        )
        for candidate in [alive, working, blocked] {
            #expect(SessionRecency.isExempt(candidate))
            #expect(SessionRecency.isVisible(candidate, in: .hour, now: Self.now))
        }

        // The one that is not exempt, and the reason the window exists.
        let finished = session("done", lastEventAt: ancient)
        #expect(!SessionRecency.isExempt(finished))
        #expect(!SessionRecency.isVisible(finished, in: .hour, now: Self.now))
    }

    @Test("a session with no last event falls back to when it started")
    func startedAtIsTheFallback() {
        let old = session(
            "old", lastEventAt: nil, startedAt: Self.now.addingTimeInterval(-20 * Self.hour)
        )
        let recent = session(
            "recent", lastEventAt: nil, startedAt: Self.now.addingTimeInterval(-1 * Self.hour)
        )
        #expect(!SessionRecency.isVisible(old, in: .twelveHours, now: Self.now))
        #expect(SessionRecency.isVisible(recent, in: .twelveHours, now: Self.now))
    }

    @Test("a session with no timestamps at all is kept")
    func unknownAgeIsNotOldAge() {
        // Hiding it would be the window claiming knowledge it does not have.
        let unknown = session("unknown", lastEventAt: nil, startedAt: nil)
        #expect(SessionRecency.isVisible(unknown, in: .hour, now: Self.now))
    }

    @Test("`all` keeps everything and hides nothing")
    func allIsTheOldBehaviour() {
        let ancient = session(
            "ancient", lastEventAt: Self.now.addingTimeInterval(-365 * 24 * Self.hour)
        )
        let board = BoardSnapshot(generatedAt: Self.now, sessions: [ancient])
        let windowed = SessionRecency.apply(to: board, window: .all, now: Self.now)
        #expect(windowed.board.sessions.count == 1)
        #expect(windowed.hidden == 0)
        #expect(SessionRecency.hint(hidden: 0, window: .all) == nil)
    }

    // MARK: A day's worth

    @Test("a week of finished sessions collapses to the day's, and says how many it left")
    func aWeekOfSessions() {
        // The shape of the machine that produced the bug: one live session and
        // twelve hundred finished ones spread over the registry's bootstrap
        // week.
        var sessions = [session("live", state: .thinking, isAlive: true, lastEventAt: Self.now)]
        for index in 0..<1_200 {
            let age = TimeInterval(index) * (7 * 24 * Self.hour / 1_200)
            sessions.append(
                session("done-\(index)", lastEventAt: Self.now.addingTimeInterval(-age))
            )
        }
        let board = BoardSnapshot(generatedAt: Self.now, sessions: sessions)

        let windowed = SessionRecency.apply(to: board, window: .twelveHours, now: Self.now)
        // 12 h of a week, evenly spread over 1,200: about 86 of them, plus the
        // live one. The exact count is arithmetic; what matters is the order
        // of magnitude and that everything else is accounted for.
        #expect(windowed.board.sessions.count < 120)
        #expect(windowed.board.sessions.count + windowed.hidden == board.sessions.count)
        #expect(windowed.board.sessions.contains { $0.key.sessionID == "live" })
        #expect(SessionRecency.hint(hidden: windowed.hidden, window: .twelveHours)
            == "\(windowed.hidden) older than 12 h, hidden")

        // Widening puts them all back, which is what makes the window a view
        // rather than a deletion.
        #expect(SessionRecency.apply(to: board, window: .all, now: Self.now).board.sessions.count
            == board.sessions.count)
    }

    @Test("the frame's counts follow the window, and the hidden number travels with it")
    func theBoardAgreesWithItself() {
        var sessions = [session("live", state: .thinking, isAlive: true, lastEventAt: Self.now)]
        for index in 0..<40 {
            sessions.append(
                session(
                    "done-\(index)",
                    lastEventAt: Self.now.addingTimeInterval(-TimeInterval(index + 1) * Self.hour)
                )
            )
        }
        let board = BoardSnapshot(generatedAt: Self.now, sessions: sessions)

        let frame = BoardFrameAssembler.frame(
            board: board,
            inputs: BoardFrameInputs(window: .twelveHours)
        )
        // Twelve of the forty are inside twelve hours, plus the live one.
        #expect(frame.summary.done == 12)
        #expect(frame.endedRows.count == 12)
        #expect(frame.olderHidden == 28)
        #expect(frame.sessionCount == 13)

        let whole = BoardFrameAssembler.frame(
            board: board,
            inputs: BoardFrameInputs(window: .all)
        )
        #expect(whole.summary.done == 40)
        #expect(whole.olderHidden == 0)
    }

    @Test("the hint counts in the singular too, and says nothing when nothing is hidden")
    func theHintReads() {
        #expect(SessionRecency.hint(hidden: 1, window: .twelveHours) == "1 older than 12 h, hidden")
        #expect(SessionRecency.hint(hidden: 0, window: .twelveHours) == nil)
    }
}
