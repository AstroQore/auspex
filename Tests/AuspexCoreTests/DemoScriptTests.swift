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
        // All seven, including the two that share a vendor mark with a
        // sibling: a demo board without them would never show whether the
        // accent and the full name are enough to tell the pair apart.
        let featured: [Harness] = [
            .claudeCode, .claudeCowork, .codex, .chatgptWork, .cursor, .grokBuild, .antigravity
        ]
        for harness in featured {
            #expect(harnesses.contains(harness), "\(harness.rawValue) is missing from the demo")
        }
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
