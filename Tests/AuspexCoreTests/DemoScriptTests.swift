import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("DemoScript")
struct DemoScriptTests {
    private let epoch = Fixtures.date(0)

    // MARK: - Determinism

    @Test("the same seed and generation produce byte-identical scripts")
    func sameSeedProducesIdenticalScript() {
        let first = DemoScript.make(seed: 99, startedAt: epoch, generation: 0)
        let second = DemoScript.make(seed: 99, startedAt: epoch, generation: 0)

        // Event ids come from the seeded generator too, so this is value
        // equality over the whole script rather than a comparison of the
        // interesting fields only.
        #expect(first.steps == second.steps)
        #expect(first.duration == second.duration)
    }

    @Test("a different seed produces a different script")
    func differentSeedProducesDifferentScript() {
        let a = DemoScript.make(seed: 1, startedAt: epoch, generation: 0)
        let b = DemoScript.make(seed: 2, startedAt: epoch, generation: 0)
        #expect(a.steps != b.steps)
    }

    @Test("each generation differs, but keeps the same sessions")
    func generationsDifferButKeepTheirSessions() {
        let first = DemoScript.make(startedAt: epoch, generation: 0)
        let second = DemoScript.make(startedAt: epoch, generation: 1)

        #expect(first.steps != second.steps)
        // A loop restarts the same board rather than piling up new cards.
        #expect(Set(first.steps.map(\.event.session)) == Set(second.steps.map(\.event.session)))
    }

    // MARK: - Shape

    @Test("steps are ordered and start immediately")
    func stepsAreOrderedAndPrompt() {
        let script = DemoScript.make(startedAt: epoch)

        #expect(!script.steps.isEmpty)
        #expect(script.steps.map(\.offset) == script.steps.map(\.offset).sorted())
        #expect(script.steps.first?.offset == 0)
        // The compressed prologue must land before a person can read the
        // window, or the board opens empty and fills in.
        let prologue = script.steps.filter { $0.offset < 1 }
        #expect(prologue.count > 40, "the board should be populated within a second")
    }

    @Test("the loop is long enough to watch and short enough to see repeat")
    func loopDurationIsReasonable() {
        let script = DemoScript.make(startedAt: epoch)
        #expect(script.duration > 60)
        #expect(script.duration < 300)
    }

    @Test("every featured harness is on the demo board")
    func allFeaturedHarnessesAppear() {
        let script = DemoScript.make(startedAt: epoch)
        let harnesses = Set(script.steps.map(\.event.session.harness))
        // All eight, including the three that share a vendor mark with a
        // sibling: a demo board without them would never show whether the
        // accent and the full name are enough to tell a pair apart.
        let featured: [Harness] = [
            .claudeCode, .claudeCowork, .codex, .chatgptWork, .cursor,
            .grokBuild, .grokBot, .antigravity
        ]
        for harness in featured {
            #expect(harnesses.contains(harness), "\(harness.rawValue) is missing from the demo")
        }
    }

    @Test("the cloud bot demonstrates a session with no project of its own")
    func grokBotSessionHasNoDirectory() {
        let script = DemoScript.make(startedAt: epoch)
        let identities: [SessionIdentity] = script.steps.compactMap { step in
            guard case .sessionStarted(let identity) = step.event.kind,
                  identity.key.harness == .grokBot
            else { return nil }
            return identity
        }
        let bot = try? #require(identities.first)
        #expect(identities.count == 1)
        // Everything the store genuinely cannot answer stays empty. A demo
        // that filled any of these in would be demonstrating a board the real
        // adapter can never produce.
        #expect(bot?.cwd == nil)
        #expect(bot?.gitRoot == nil)
        #expect(bot?.gitBranch == nil)
        #expect(bot?.model == nil)
        #expect(bot?.pid == nil)
        #expect(bot?.title?.isEmpty == false)

        // No tool call is ever attributed to it: the run happened on xAI's
        // servers and the local cache records none.
        let botSteps = script.steps.filter { $0.event.session.harness == .grokBot }
        #expect(!botSteps.isEmpty)
        #expect(!botSteps.contains { if case .toolCallStarted = $0.event.kind { true } else { false } })
        #expect(!botSteps.contains { if case .usage = $0.event.kind { true } else { false } })

        // And it blocks on a person without naming a tool, which is the only
        // shape its roster's needs-you flag can take.
        let tools: [String?] = botSteps.compactMap { step in
            if case .permissionRequested(_, let tool) = step.event.kind { return .some(tool) }
            return nil
        }
        #expect(tools == [String?.none])
    }

    @Test("the demo board puts the cloud bot under a section of its own")
    func grokBotGroupsUnderAPseudoProject() {
        let script = DemoScript.make(startedAt: epoch)
        let reducer = SessionStateReducer()
        var snapshots: [SessionKey: SessionSnapshot] = [:]
        for step in script.steps {
            let key = step.event.session
            let previous = snapshots[key] ?? {
                if case .sessionStarted(let identity) = step.event.kind {
                    return SessionStateReducer.initialSnapshot(identity: identity)
                }
                return SessionStateReducer.initialSnapshot(
                    identity: SessionIdentity(key: key, sourcePath: "")
                )
            }()
            snapshots[key] = reducer.reduce(previous, event: step.event)
        }
        let board = BoardSnapshot(
            generatedAt: epoch, sessions: Array(snapshots.values).sorted { $0.key.sessionID < $1.key.sessionID })

        let titles = BoardGrouping.groups(for: board, groupBy: .project).map(\.title)
        #expect(titles.contains("Grok Bot"))
        #expect(!titles.contains(BoardGrouping.noProjectTitle))
    }

    // MARK: - The ledger

    /// Every session the script produces, folded exactly as the registry
    /// would fold it.
    private func demoSnapshots(upTo offset: TimeInterval = .infinity) -> [SessionSnapshot] {
        let script = DemoScript.make(startedAt: epoch)
        let reducer = SessionStateReducer()
        var snapshots: [SessionKey: SessionSnapshot] = [:]
        for step in script.steps where step.offset <= offset {
            let key = step.event.session
            let previous = snapshots[key] ?? {
                if case .sessionStarted(let identity) = step.event.kind {
                    return SessionStateReducer.initialSnapshot(identity: identity)
                }
                return SessionStateReducer.initialSnapshot(
                    identity: SessionIdentity(key: key, sourcePath: "")
                )
            }()
            snapshots[key] = reducer.reduce(previous, event: step.event)
        }
        return Array(snapshots.values).sorted { $0.key.sessionID < $1.key.sessionID }
    }

    @Test("every demo session was asked for something and answered in prose")
    func everySessionCarriesABrief() {
        // The board's ledger lines draw these. A demo whose prompts were
        // placeholders would screenshot as a wall of cards with two empty
        // rows on each.
        let sessions = demoSnapshots()
        #expect(sessions.allSatisfy { $0.brief.firstPrompt?.isEmpty == false })
        #expect(sessions.count { $0.brief.latestAssistant?.isEmpty == false } >= 6)
        #expect(sessions.count { $0.brief.followUpPrompt != nil } >= 6)
    }

    @Test("the demo board has something finished that nobody has read")
    func theBoardHasADoneUnseenSession() {
        let sessions = demoSnapshots()
        let unseen = sessions.filter {
            TaskLedger.isUnseenDone(
                state: $0.state,
                lastTurnEndedAt: $0.brief.lastTurnEndedAt,
                lastSeenAt: nil
            ,
            isChild: false,
            hasAssignment: true)
        }
        #expect(!unseen.isEmpty, "the board's own feature should be visible in a screenshot")
        // Both shapes: one that exited, and one still sitting open in its
        // editor. They read very differently on a card and both have to work.
        #expect(unseen.contains { $0.state.isEnded })
        #expect(unseen.contains { !$0.state.isEnded })
    }

    @Test("a session opened stops being unseen")
    func openingClearsTheFlag() throws {
        let sessions = demoSnapshots()
        let session = try #require(
            sessions.first { $0.brief.lastTurnEndedAt != nil && !$0.state.isActive }
        )
        let after = try #require(session.brief.lastTurnEndedAt).addingTimeInterval(1)
        #expect(TaskLedger.isUnseenDone(
            state: session.state, lastTurnEndedAt: session.brief.lastTurnEndedAt, lastSeenAt: after
        ,
            isChild: false,
            hasAssignment: true) == false)
    }

    @Test("the two harnesses that share a store are still separate sessions")
    func sharedStoresStaySeparateSessions() {
        let script = DemoScript.make(startedAt: epoch)
        let keys = Set(script.steps.map(\.event.session))
        let codex = keys.filter { $0.harness == .codex }
        let work = keys.filter { $0.harness == .chatgptWork }
        #expect(!codex.isEmpty)
        #expect(!work.isEmpty)
        // Session ids are only unique within a harness; the pair must not
        // collide into one card.
        #expect(codex.intersection(work).isEmpty)
    }

    @Test("the demo shows every state a card can be in")
    func everyStateIsReachable() {
        let script = DemoScript.make(startedAt: epoch)
        let kinds = script.steps.map(\.event.kind)

        #expect(kinds.contains { if case .userPrompt = $0 { true } else { false } })
        #expect(kinds.contains { if case .thinking = $0 { true } else { false } })
        #expect(kinds.contains { if case .toolCallStarted(_, _, .fileWrite, _) = $0 { true } else { false } })
        #expect(kinds.contains { if case .subagentStarted = $0 { true } else { false } })
        #expect(kinds.contains { if case .permissionRequested = $0 { true } else { false } })
        #expect(kinds.contains { if case .permissionResolved = $0 { true } else { false } })
        #expect(kinds.contains { if case .sessionEnded = $0 { true } else { false } })
        #expect(kinds.contains { if case .usage = $0 { true } else { false } })
    }

    @Test("every permission prompt and tool call is eventually resolved")
    func openWorkIsAlwaysClosed() {
        let script = DemoScript.make(startedAt: epoch)
        var openCalls: Set<String> = []
        var openPermissions: Set<String> = []

        for step in script.steps {
            switch step.event.kind {
            case .toolCallStarted(let id, _, _, _): openCalls.insert(id)
            case .toolCallFinished(let id, _): openCalls.remove(id)
            case .permissionRequested(let id, _): openPermissions.insert(id)
            case .permissionResolved(let id, _): openPermissions.remove(id)
            default: break
            }
        }

        #expect(openCalls.isEmpty, "a demo tool call never finishes: \(openCalls)")
        #expect(openPermissions.isEmpty, "a demo permission prompt is never answered")
    }

    @Test("the delegating session spawns a child that names it as parent")
    func delegationProducesALinkedChild() {
        let script = DemoScript.make(startedAt: epoch)

        let spawned: [SessionKey] = script.steps.compactMap { step in
            if case .subagentStarted(let child, _, _) = step.event.kind { return child }
            return nil
        }
        #expect(!spawned.isEmpty)

        let childIdentities: [SessionIdentity] = script.steps.compactMap { step in
            if case .sessionStarted(let identity) = step.event.kind, identity.parent != nil {
                return identity
            }
            return nil
        }
        #expect(childIdentities.count == spawned.count)
        for identity in childIdentities {
            #expect(spawned.contains(identity.key))
            #expect(identity.parentLink != nil)
        }
    }

    @Test("a script folds through the reducer without producing a stuck session")
    func scriptReducesToASensibleBoard() {
        let script = DemoScript.make(startedAt: epoch)
        let reducer = SessionStateReducer()
        var snapshots: [SessionKey: SessionSnapshot] = [:]

        for step in script.steps {
            let key = step.event.session
            let previous = snapshots[key] ?? {
                if case .sessionStarted(let identity) = step.event.kind {
                    return SessionStateReducer.initialSnapshot(identity: identity)
                }
                return SessionStateReducer.initialSnapshot(
                    identity: SessionIdentity(key: key, sourcePath: "")
                )
            }()
            snapshots[key] = reducer.reduce(previous, event: step.event)
        }

        #expect(snapshots.count >= 8)
        for (key, snapshot) in snapshots {
            #expect(snapshot.pending.openToolCalls.isEmpty, "\(key) ends with an open tool call")
            #expect(snapshot.pending.openPermission == nil, "\(key) ends blocked on a prompt")
            #expect(snapshot.turnCount > 0, "\(key) never opened a turn")
        }
    }

    // MARK: - Source content

    /// The demo is what gets screenshotted for a public repository, so every
    /// path in it has to be synthetic — and the machine's own home directory
    /// must not appear anywhere, however it is spelled on the machine running
    /// the suite.
    @Test("every path in the demo is synthetic, and the real home never appears")
    func demoUsesOnlySyntheticPaths() throws {
        let script = DemoScript.make(startedAt: epoch)
        let encoder = JSONEncoder()
        let realHome = AuspexPaths.realHomeDirectory().path

        for step in script.steps {
            let json = String(decoding: try encoder.encode(step.event.kind), as: UTF8.self)
            for range in json.ranges(of: "/Users/") {
                let tail = json[range.lowerBound...].prefix(14)
                #expect(
                    tail.hasPrefix("/Users/example"),
                    "the demo leaked a non-synthetic home: \(tail)"
                )
            }
            #expect(!realHome.isEmpty && !json.contains(realHome))
            #expect(step.event.raw?.path.hasPrefix("/Users/example") == true)
        }
    }
}

@Suite("SeededRandom")
struct SeededRandomTests {
    @Test("the same seed replays the same sequence")
    func sameSeedReplays() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        let first = (0..<32).map { _ in a.next() }
        let second = (0..<32).map { _ in b.next() }
        #expect(first == second)
    }

    @Test("different seeds diverge, and one seed does not repeat itself immediately")
    func seedsDiverge() {
        var a = SeededRandom(seed: 1)
        var b = SeededRandom(seed: 2)
        #expect(a.next() != b.next())

        var c = SeededRandom(seed: 7)
        let values = (0..<64).map { _ in c.next() }
        #expect(Set(values).count == values.count)
    }

    @Test("UUIDs are drawn from the same sequence, so a script's ids are stable")
    func uuidsAreDeterministic() {
        var a = SeededRandom(seed: 5)
        var b = SeededRandom(seed: 5)
        #expect(a.nextUUID() == b.nextUUID())
        // Both generators advanced by the same amount, so they stay in step.
        #expect(a.nextUUID() == b.nextUUID())

        var c = SeededRandom(seed: 5)
        let ids = (0..<16).map { _ in c.nextUUID() }
        #expect(Set(ids).count == ids.count)
    }
}
