import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// The Now screen's lists: which bucket a session lands in, how a family is
/// folded, and what is counted rather than listed.
@Suite("NowFrame")
struct NowFrameTests {
    // MARK: Fixtures

    private func key(_ id: String, _ harness: Harness = .claudeCode) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    private func row(
        _ id: String,
        harness: Harness = .claudeCode,
        state: SessionState = .thinking,
        project: String = "widget",
        directory: String? = nil,
        parent: String? = nil,
        attention: AttentionState = .none,
        notice: BoardRow.RowNotice? = nil,
        elapsed: TimeInterval = 10,
        lastEvent: TimeInterval = 50,
        stale: Bool = false,
        toolTarget: String? = nil,
        context: ContextGauge? = nil
    ) -> BoardRow {
        BoardRow(
            key: key(id, harness),
            harness: harness,
            title: "Session \(id)",
            shortID: id,
            pid: nil,
            modelName: nil,
            state: state,
            isStale: stale,
            project: project,
            branch: nil,
            // Each session in a checkout of its own unless a test says
            // otherwise: two units in one directory is a collision signal.
            directory: directory ?? "/Users/example/Code/\(project)/\(id)",
            activity: BoardRowFixture.activity(state),
            turnCount: 1,
            toolCallCount: 1,
            tokensIn: 1,
            tokensOut: 1,
            elapsedSince: Fixtures.date(elapsed),
            endedAt: state.isEnded ? Fixtures.date(lastEvent) : nil,
            lastEventAt: Fixtures.date(lastEvent),
            descendantCount: 0,
            parent: parent.map { BoardRow.Parent(key: key($0, harness), title: "Session \($0)") },
            depth: 0,
            attention: attention,
            notice: notice,
            context: context,
            toolTarget: toolTarget
        )
    }

    private func unit(
        _ id: String,
        _ members: [BoardRow],
        task: Int64? = nil,
        status: AuspexTaskStatus = .doing,
        updatedAt: TimeInterval? = nil
    ) -> TaskUnit {
        let lead = members[0]
        return TaskUnit(
            id: task.map { "task:\($0)" } ?? "implicit:\(id)",
            shortID: id,
            origin: task.map { .task($0) } ?? .implicit(lead.key),
            promotionKey: "root:\(id)",
            projectKey: "/Users/example/Code/\(lead.project ?? "widget")",
            title: "Unit \(id)",
            status: status,
            lead: lead,
            members: members,
            counts: .init(
                working: members.count { $0.state.isActive },
                idle: members.count { !$0.state.isActive && !$0.isEnded },
                ended: members.count { $0.isEnded }
            ),
            lastEventAt: lead.lastEventAt,
            updatedAt: updatedAt.map(Fixtures.date)
        )
    }

    // MARK: Buckets

    @Test("each live root lands in exactly one bucket, by precedence")
    func fourBuckets() {
        let waiting = row(
            "wait", state: .waitingPermission(tool: "Bash"),
            attention: .needsYou(reason: "Waiting for permission: Bash", source: .harness),
            toolTarget: "gh pr merge"
        )
        let asking = row(
            "ask", state: .idle,
            attention: .needsYou(reason: "Which migration should stay?", source: .agent),
            notice: .init(kind: .needsInput, message: "Which migration should stay?",
                          urgency: .normal, at: Fixtures.date(20))
        )
        let stale = row("stale", state: .thinking, stale: true)
        let running = row("run", state: .toolCalling(name: "WebSearch"), toolTarget: "OpenAI Dots")
        let finished = row(
            "fin", state: .idle,
            attention: .doneReported(summary: "Spec landed", source: .agent),
            notice: .init(kind: .done, message: "Spec landed", urgency: .normal,
                          at: Fixtures.date(30))
        )
        let resting = row("rest", state: .idle)
        let gone = row("gone", state: .ended(reason: .exited))

        let units = [waiting, asking, stale, running, finished, resting, gone]
            .map { unit($0.shortID, [$0]) }
        let signals = CollaborationSignals.derive(units: units, now: Fixtures.date(100))
        let now = NowFrame.derive(units: units, signals: signals)

        #expect(now.needsYou.map(\.row.shortID) == ["wait", "ask"])
        #expect(now.needsYou.first?.reason == .permission(tool: "Bash", target: "gh pr merge"))
        #expect(now.needsYou.last?.reason == .notice(message: "Which migration should stay?"))
        // An agent's call is timed from when it was made, not from its state.
        #expect(now.needsYou.last?.since == Fixtures.date(20))

        #expect(now.mayNeedYou.map(\.row.shortID) == ["stale"])
        if case .watch(let kind, _) = now.mayNeedYou.first?.reason {
            #expect(kind == .staleSession)
        } else {
            Issue.record("the stale session should be a watch line")
        }
        #expect(now.mayNeedYou.first?.score == nil)

        #expect(now.working.map(\.row.shortID) == ["run"])
        #expect(now.working.first?.activity == .init(tool: "WebSearch", detail: "OpenAI Dots"))

        #expect(now.done.map(\.row.shortID) == ["fin"])
        #expect(now.done.first?.since == Fixtures.date(30))

        #expect(now.idleCount == 1)
        #expect(now.idle.map(\.row.shortID) == ["rest"])
        // Six live roots; the ended one is in none of the lists and not live.
        #expect(now.liveCount == 6)
        let listed = (now.needsYou + now.mayNeedYou + now.working + now.done + now.idle)
            .map(\.row.shortID)
        #expect(!listed.contains("gone"))
        #expect(Set(listed).count == listed.count)
    }

    @Test("subagents fold into their root's working row as ↳N")
    func subagentsFold() {
        let root = row("root", state: .delegating(children: 3))
        let kids = [
            row("kid-1", state: .toolCalling(name: "Read"), parent: "root"),
            row("kid-2", state: .thinking, parent: "root"),
            // A grandchild still folds into the topmost live ancestor.
            row("kid-3", state: .idle, parent: "kid-1"),
            // An ended child is not counted.
            row("kid-4", state: .ended(reason: .exited), parent: "root")
        ]
        let now = NowFrame.derive(units: [unit("family", [root] + kids)], signals: [])

        #expect(now.working.count == 1)
        #expect(now.working.first?.row.shortID == "root")
        #expect(now.working.first?.subagents == 3)
        #expect(now.idleCount == 0)
        #expect(now.liveCount == 1)
    }

    @Test("a quiet root with a busy subagent is working, and shows the subagent's activity")
    func quietRootBusyChild() {
        let root = row("root", state: .idle)
        let child = row(
            "child", state: .toolCalling(name: "exec"), parent: "root",
            elapsed: 40, toolTarget: "python render.py"
        )
        let now = NowFrame.derive(units: [unit("family", [root, child])], signals: [])

        #expect(now.working.map(\.row.shortID) == ["root"])
        #expect(now.working.first?.activity == .init(tool: "exec", detail: "python render.py"))
        #expect(now.working.first?.since == Fixtures.date(40))
    }

    @Test("an orphaned subagent's caption hangs over its own desk, not its exited orchestrator's")
    func orphanedChildCaptionIsItsOwn() {
        let gone = row("gone", state: .ended(reason: .exited))
        let orphan = row("orphan", state: .toolCalling(name: "exec"), parent: "gone", toolTarget: "pytest")
        let now = NowFrame.derive(units: [unit("family", [gone, orphan])], signals: [])

        #expect(now.working.map(\.row.shortID) == ["orphan"])
        #expect(now.captions.count == 1)
        #expect(now.captions.first?.sessionKey == key("orphan"))
        #expect(now.captions.first?.deskKey == key("orphan"))
    }

    @Test("a subagent whose orchestrator exited becomes a root of its own")
    func orphanedChildIsARoot() {
        let root = row("root", state: .ended(reason: .exited))
        let child = row("child", state: .thinking, parent: "root")
        let now = NowFrame.derive(units: [unit("family", [root, child])], signals: [])

        #expect(now.working.map(\.row.shortID) == ["child"])
        #expect(now.working.first?.subagents == 0)
        #expect(now.liveCount == 1)
    }

    @Test("a subagent's own call is listed on its own, and its root keeps working")
    func childCallIsListedSeparately() {
        let root = row("root", state: .delegating(children: 1))
        let child = row(
            "child", state: .waitingPermission(tool: "Edit"), parent: "root",
            attention: .needsYou(reason: "Waiting for permission: Edit", source: .harness)
        )
        let now = NowFrame.derive(units: [unit("family", [root, child])], signals: [])

        #expect(now.needsYou.map(\.row.shortID) == ["child"])
        #expect(now.working.map(\.row.shortID) == ["root"])
        #expect(now.working.first?.subagents == 1)
    }

    @Test("idle roots are counted, and only alive ones")
    func idleCount() {
        let units = (0..<4).map { index in
            unit("i\(index)", [row("idle-\(index)", state: .idle, project: "p\(index)")])
        } + [unit("e", [row("ended", state: .ended(reason: .exited))])]
        let now = NowFrame.derive(units: units, signals: [])

        #expect(now.idleCount == 4)
        #expect(now.idle.map(\.row.project) == ["p0", "p1", "p2", "p3"])
        #expect(now.working.isEmpty)
        #expect(now.liveCount == 4)
    }

    @Test("a filed task marked blocked needs a person even with nobody asking")
    func blockedTask() {
        let quiet = row("quiet", state: .idle)
        let now = NowFrame.derive(
            units: [unit("t", [quiet], task: 7, status: .blocked, updatedAt: 5)],
            signals: []
        )

        #expect(now.needsYou.map(\.reason) == [.blockedTask])
        #expect(now.needsYou.first?.unitID == "task:7")
        #expect(now.needsYou.first?.since == Fixtures.date(5))
        // Claimed by the blocked line, so not idle as well.
        #expect(now.idleCount == 0)
    }

    @Test("a watch signal about a session that already asked is not repeated")
    func watchDefersToNeedsYou() {
        let asking = row(
            "ask", state: .toolCalling(name: "Bash"),
            attention: .needsYou(reason: "Stuck", source: .agent),
            notice: .init(kind: .needsInput, message: "Stuck", urgency: .normal,
                          at: Fixtures.date(1)),
            elapsed: 0
        )
        let units = [unit("a", [asking])]
        let signals = CollaborationSignals.derive(units: units, now: Fixtures.date(1_000))
        #expect(signals.contains { $0.kind == WatchSignal.Kind.longTool })

        let now = NowFrame.derive(units: units, signals: signals)
        #expect(now.needsYou.count == 1)
        #expect(now.mayNeedYou.isEmpty)
    }

    @Test("a session a watch line is about is not listed as done as well")
    func doneDefersToMayNeedYou() {
        let finishing = row(
            "fin", state: .toolCalling(name: "Bash"),
            attention: .doneReported(summary: "Spec landed", source: .agent),
            notice: .init(kind: .done, message: "Spec landed", urgency: .normal,
                          at: Fixtures.date(1)),
            elapsed: 0
        )
        let units = [unit("f", [finishing])]
        let signals = CollaborationSignals.derive(units: units, now: Fixtures.date(1_000))
        #expect(signals.contains { $0.kind == WatchSignal.Kind.longTool })

        let now = NowFrame.derive(units: units, signals: signals)
        #expect(now.mayNeedYou.map(\.row.shortID) == ["fin"])
        #expect(now.done.isEmpty)
        #expect(now.counts.done == 0)

        // A collision claims nobody, so two finished sessions in one checkout
        // are still each listed as done under the line about them both.
        let shared = "/Users/example/Code/auspex"
        let one = row(
            "one", state: .thinking, project: "auspex", directory: shared,
            attention: .doneReported(summary: "One", source: .agent)
        )
        let two = row(
            "two", state: .thinking, project: "auspex", directory: shared,
            attention: .doneReported(summary: "Two", source: .agent)
        )
        let pair = [unit("one", [one], task: 1), unit("two", [two], task: 2)]
        let collided = NowFrame.derive(
            units: pair,
            signals: CollaborationSignals.derive(units: pair, now: Fixtures.date(100))
        )
        #expect(collided.mayNeedYou.map(\.sessionCount) == [2])
        #expect(Set(collided.done.map(\.row.shortID)) == ["one", "two"])
    }

    @Test("a collision is listed once and claims none of the sessions it names")
    func collisionClaimsNothing() {
        let shared = "/Users/example/Code/auspex"
        let one = row("one", state: .thinking, project: "auspex", directory: shared)
        let two = row("two", state: .thinking, project: "auspex", directory: shared)
        let units = [unit("one", [one], task: 1), unit("two", [two], task: 2)]
        let signals = CollaborationSignals.derive(units: units, now: Fixtures.date(100))
        let now = NowFrame.derive(units: units, signals: signals)

        #expect(now.mayNeedYou.count == 1)
        #expect(now.mayNeedYou.first?.sessionCount == 2)
        #expect(now.working.count == 2)
    }

    // MARK: Stage

    @Test("captions go to the most urgent, one per desk, six at most")
    func captionsArePrioritised() {
        let asking = row(
            "ask", state: .idle,
            attention: .needsYou(reason: "Help", source: .agent),
            notice: .init(kind: .needsInput, message: "Help", urgency: .normal,
                          at: Fixtures.date(1))
        )
        let runners = (0..<8).map { index in
            unit("r\(index)", [row("run-\(index)", lastEvent: TimeInterval(index))])
        }
        let root = row("root", state: .delegating(children: 1))
        let child = row(
            "child", state: .waitingPermission(tool: "Bash"), parent: "root",
            attention: .needsYou(reason: "Waiting for permission: Bash", source: .harness)
        )
        let units = [unit("a", [asking]), unit("fam", [root, child])] + runners
        let now = NowFrame.derive(units: units, signals: [])

        #expect(now.captions.count == NowFrame.captionLimit)
        // The child asked; the balloon hangs over its family's desk.
        #expect(now.captions[0].deskKey == key("root"))
        #expect(now.captions[0].sessionKey == key("child"))
        #expect(now.captions[1].deskKey == key("ask"))
        // Then the most recently active of what is running.
        #expect(now.captions[2].deskKey == key("run-7"))
        #expect(now.captions.map(\.tone).filter { $0 == .needsYou }.count == 2)
        #expect(Set(now.captions.map(\.deskKey)).count == now.captions.count)
    }

    @Test("derivation is a pure function of its inputs")
    func deterministic() {
        let units = (0..<5).map { index in
            unit("u\(index)", [row("s\(index)", state: index.isMultiple(of: 2) ? .thinking : .idle)])
        }
        #expect(
            NowFrame.derive(units: units, signals: [])
                == NowFrame.derive(units: units.reversed(), signals: [])
        )
    }

    // MARK: Durations

    @Test("a stopwatch keeps its seconds only while they matter")
    func compactDuration() {
        #expect(NowFrame.compactDuration(-3) == "0s")
        #expect(NowFrame.compactDuration(40) == "40s")
        #expect(NowFrame.compactDuration(252) == "4m12s")
        #expect(NowFrame.compactDuration(130) == "2m10s")
        #expect(NowFrame.compactDuration(18 * 60 + 37) == "18m")
        #expect(NowFrame.compactDuration(3_840) == "1h04m")
        #expect(NowFrame.compactDuration(3 * 86_400 + 5) == "3d")
    }

    @Test("a stopwatch says how long its reading holds, so nothing redraws an equal one")
    func compactDurationHold() {
        // Seconds are printed under ten minutes, so the reading turns over at
        // the next whole second.
        #expect(abs(NowFrame.compactDurationHold(40.25) - 0.75) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(-3) - 1) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(599.5) - 0.5) < 0.0001)
        // Past ten minutes it is minutes, up to a day.
        #expect(abs(NowFrame.compactDurationHold(600) - 60) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(18 * 60 + 37) - 23) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(3_599) - 1) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(3_840) - 60) < 0.0001)
        #expect(abs(NowFrame.compactDurationHold(86_399.5) - 0.5) < 0.0001)
        // And past a day, days.
        #expect(abs(NowFrame.compactDurationHold(3 * 86_400 + 5) - (86_400 - 5)) < 0.0001)

        // Whatever the reading, it really is the same until the hold is up and
        // different straight after.
        for elapsed in stride(from: 0.0, to: 90_000, by: 37.3) {
            let hold = NowFrame.compactDurationHold(elapsed)
            #expect(hold > 0)
            #expect(
                NowFrame.compactDuration(elapsed + hold * 0.999)
                    == NowFrame.compactDuration(elapsed)
            )
            #expect(
                NowFrame.compactDuration(elapsed + hold + 0.001)
                    != NowFrame.compactDuration(elapsed)
            )
        }
    }
}

/// The activity line a real builder would write, for rows built by hand.
enum BoardRowFixture {
    static func activity(_ state: SessionState) -> String {
        switch state {
        case .toolCalling(let name): name
        case .writingFile(let path): path ?? "file"
        case .delegating(let children): "\(children) child sessions"
        case .waitingPermission(let tool): tool ?? "an answer"
        case .ended(let reason): "exited · \(reason.rawValue)"
        case .idle: "quiet"
        case .thinking: "reasoning"
        }
    }
}
