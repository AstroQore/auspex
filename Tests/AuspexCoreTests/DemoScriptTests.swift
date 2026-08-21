import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("DemoScript")
struct DemoScriptTests {
    private let epoch = Fixtures.date(0)

    // MARK: - What the cast is for

    @Test("the demo board carries a desktop thread that is not a project")
    func theCastHasAScratchThread() async throws {
        let resolver = ProjectResolver(homeDirectory: DemoScript.homeDirectory)
        var scratch: [DemoScript.Blueprint] = []
        for blueprint in DemoScript.Blueprint.all {
            guard let cwd = blueprint.cwd else { continue }
            if await resolver.resolve(cwd: cwd).isProjectless { scratch.append(blueprint) }
        }

        // One, and it is a Codex desktop thread. More than one would be a wall
        // whose scratch section is the demo rather than a corner of it.
        #expect(scratch.count == 1)
        let thread = try #require(scratch.first)
        #expect(thread.harness == .codex)
        #expect(thread.gitRoot == nil)
        #expect(HarnessSandbox.thread(
            forPath: try #require(thread.cwd), home: DemoScript.homeDirectory)?.name == "zhe")
    }

    @Test("the demo board carries an AntiGravity command line with a workspace and a model")
    func theCastHasAnAntigravityCLI() throws {
        // The case the conversation database cannot answer on its own: both
        // facts come from the side files the CLI writes beside it, and both
        // used to be blank.
        let cli = try #require(
            DemoScript.Blueprint.all.first { $0.harness == .antigravity && $0.variant == "cli" })
        #expect(cli.cwd != nil)
        #expect(cli.model != nil)
        #expect(cli.gitRoot != nil)
    }

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

    @Test("the demo board says both loud things out loud")
    func theBoardHasBothAttentionBuckets() {
        // The two buckets a header counts are made of explicit signals, so a
        // demo that only *implied* them would screenshot as a board with the
        // chips missing — which is the half of the app the demo is for.
        let now = epoch.addingTimeInterval(60)
        let notices = DemoScript.notices(now: now)
        #expect(notices.values.contains { $0.kind.wantsPerson })
        #expect(notices.values.contains { $0.kind == .done })
        // And each is about a session that is actually on the board.
        let keys = Set(DemoScript.sessionKeys)
        #expect(notices.keys.allSatisfy(keys.contains))
    }

    @Test("the demo board has a quiet reply for the faint dot")
    func theBoardHasAQuietReply() {
        let sessions = demoSnapshots()
        let quiet = sessions.filter {
            TaskLedger.isQuietReply(
                state: $0.state,
                lastTurnEndedAt: $0.brief.lastTurnEndedAt,
                lastSeenAt: nil,
                isChild: false,
                hasAssignment: true
            )
        }
        #expect(!quiet.isEmpty, "the card's faint dot should be visible in a screenshot")
        // Idle, not ended: an ended session is in the collapsed fold, where a
        // dot would be decoration.
        #expect(quiet.allSatisfy { !$0.state.isEnded })
    }

    @Test("a session opened stops showing the dot")
    func openingClearsTheFlag() throws {
        let sessions = demoSnapshots()
        let session = try #require(
            sessions.first { $0.brief.lastTurnEndedAt != nil && $0.state == .idle }
        )
        let after = try #require(session.brief.lastTurnEndedAt).addingTimeInterval(1)
        #expect(TaskLedger.isQuietReply(
            state: session.state,
            lastTurnEndedAt: session.brief.lastTurnEndedAt,
            lastSeenAt: after,
            isChild: false,
            hasAssignment: true
        ) == false)
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

    @Test("the delegating session fans out, so a family of three is on the board at once")
    func delegationFansOut() throws {
        // Two `delegate` beats in a row would be two delegations: the second
        // child would start after the first had finished, and the scene's
        // meeting room — one table, a parent at the head, children down the
        // sides — would never once be drawn with more than one child at it.
        let script = DemoScript.make(startedAt: epoch)
        var spawned: [SessionKey: (start: TimeInterval, end: TimeInterval)] = [:]
        for step in script.steps {
            switch step.event.kind {
            case .sessionStarted(let identity) where identity.parent != nil:
                spawned[identity.key] = (step.offset, .infinity)
            case .sessionEnded where spawned[step.event.session] != nil:
                spawned[step.event.session]?.end = step.offset
            default: break
            }
        }
        #expect(spawned.count >= 2)

        // Some instant at which two children of one parent are both alive.
        let lives = Array(spawned.values)
        let overlap = lives.contains { first in
            lives.contains { other in
                first.start != other.start
                    && first.start < other.end && other.start < first.end
            }
        }
        #expect(overlap, "the demo has to hold a family of three for the scene to seat one")
    }

    @Test("the demo says which of its sessions nobody has looked at")
    func theDemoDeclaresWhatIsUnread() throws {
        // Whether a person has *read* a session is the one thing about a board
        // that no harness store holds, so a fabricated board has to state it
        // rather than derive it — otherwise every finished session in a
        // screenshot is unread, which is a board nobody has ever had.
        let unread = DemoScript.unreadSessionKeys
        #expect(!unread.isEmpty)
        for key in unread { #expect(DemoScript.sessionKeys.contains(key)) }

        // "Seen at `now`" is what a still of the board means by it: everything
        // the reader has been through, as of the instant being drawn.
        let instant: TimeInterval = 16
        let now = epoch.addingTimeInterval(instant)
        let seen = DemoScript.seenAt(now: now)
        for key in unread { #expect(seen[key] == nil) }
        for key in DemoScript.sessionKeys where !unread.contains(key) {
            #expect(seen[key] == now)
        }

        // And the ledger agrees: exactly the declared one reads as a quiet
        // reply.
        let sessions = demoSnapshots(upTo: instant)
        let flagged = sessions.filter {
            TaskLedger.isQuietReply($0, lastSeenAt: seen[$0.key])
        }
        #expect(Set(flagged.map(\.key)) == Set(unread))
    }

    @Test("a session that goes quiet reads as stale against the demo's own clock")
    func somethingGoesStale() {
        // The demo compresses a working day into two minutes, so the
        // reducer's ninety seconds can never fire inside one loop and a still
        // of the demo could never show a state the scene draws.
        let script = DemoScript.make(startedAt: epoch)
        let reducer = SessionStateReducer(staleAfter: DemoScript.staleAfter)
        var snapshots: [SessionKey: SessionSnapshot] = [:]
        let instant: TimeInterval = 16
        for step in script.steps where step.offset <= instant {
            let key = step.event.session
            var current = snapshots[key]
            if current == nil, case .sessionStarted(let identity) = step.event.kind {
                current = SessionStateReducer.initialSnapshot(identity: identity)
            }
            guard let current else { continue }
            snapshots[key] = reducer.reduce(current, event: step.event)
        }
        let now = epoch.addingTimeInterval(instant)
        let stale = snapshots.values
            .map { reducer.refreshStaleness($0, now: now) }
            .filter { $0.isStale && $0.state.isActive }
        #expect(!stale.isEmpty, "the scene draws a dozing session; the demo has to produce one")
    }

    @Test("the demo's auto review is folded under its root rather than shipped linked")
    func autoReviewIsFoldedFromItsVariant() throws {
        let script = DemoScript.make(startedAt: epoch)
        let identities: [SessionIdentity] = script.steps.compactMap { step in
            guard case .sessionStarted(let identity) = step.event.kind else { return nil }
            return identity
        }
        let review = try #require(identities.first(where: SessionRelations.isAutoReview))
        // The script must *not* hand the board the edge: the whole point of
        // the demo session is that the grouping pass has to derive it from the
        // variant, the way it does against a real rollout.
        #expect(review.parent == nil)
        #expect(review.parentLink == nil)

        let link = try #require(SessionRelations.links(identities: identities).first)
        #expect(link.child == review.key)
        #expect(identities.contains { $0.key == link.parent })
        // Under the root the demo's Codex session already is, so the board
        // shows a two-deep tree rather than a second orphan.
        #expect(link.parent.harness == .codex)
    }

    @Test("the folded review nests under its root in the tree grouping")
    func autoReviewNestsUnderItsRootOnTheBoard() throws {
        // The whole path in one assertion: the script's identities, the links
        // the grouping pass derives from them, and the sections the board
        // draws. A screenshot shows this too; a test says which part broke.
        var sessions = demoSnapshots()
        let links = SessionRelations.links(identities: sessions.map(\.identity))
        for link in links {
            guard let index = sessions.firstIndex(where: { $0.key == link.child }) else { continue }
            sessions[index].identity.parent = link.parent
            sessions[index].identity.parentLink = link.link
        }

        let review = try #require(sessions.first { SessionRelations.isAutoReview($0.identity) })
        let rootKey = try #require(review.identity.parent)

        let board = BoardSnapshot(generatedAt: epoch, sessions: sessions)
        let groups = BoardGrouping.groups(for: board, groupBy: .tree)
        let tree = try #require(
            groups.first { $0.roots?.contains { $0.session.key == rootKey } == true }
        )
        let root = try #require(tree.roots?.first { $0.session.key == rootKey })
        #expect(root.children.map(\.session.key) == [review.key])
        #expect(root.children.first?.depth == 1)
        // And it is not also sitting at the top level of some other section.
        #expect(!groups.contains { $0.roots?.contains { $0.session.key == review.key } == true })
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

    // MARK: - Scale

    @Test("scale 1 and no scale at all are the same script")
    func scaleOneIsTheScriptAsWritten() {
        let plain = DemoScript.make(startedAt: epoch)
        let scaled = DemoScript.make(startedAt: epoch, scale: 1)
        #expect(plain.steps == scaled.steps)
    }

    @Test("scale multiplies the cast, and every copy is its own session")
    func scaleMultipliesTheCast() {
        let plain = DemoScript.make(startedAt: epoch)
        let scaled = DemoScript.make(startedAt: epoch, scale: 4)

        let plainKeys = Set(plain.steps.map(\.event.session))
        let scaledKeys = Set(scaled.steps.map(\.event.session))
        // Four times the sessions, subagents included, and the original cast
        // is still in there — copy zero is the script as written.
        #expect(scaledKeys.count == plainKeys.count * 4)
        #expect(plainKeys.isSubset(of: scaledKeys))
    }

    @Test("copies work in directories of their own, so they are separate projects")
    func copiesAreSeparateProjects() {
        let plain = Set(directories(in: DemoScript.make(startedAt: epoch)))
        let scaled = Set(directories(in: DemoScript.make(startedAt: epoch, scale: 6)))

        #expect(scaled.count == plain.count * 6)
        #expect(plain.isSubset(of: scaled))
        // Still fabricated, whatever the scale. A copy that reached outside
        // `/Users/example` would be a demo naming somebody's real machine.
        for directory in scaled {
            #expect(directory.hasPrefix("/Users/example"))
        }
    }

    @Test("copies keep their pids apart, so one process is not twelve sessions")
    func copiesHaveTheirOwnPids() {
        let scaled = DemoScript.make(startedAt: epoch, scale: 5)
        var pidsByKey: [SessionKey: pid_t] = [:]
        for step in scaled.steps {
            guard case let .sessionStarted(identity) = step.event.kind,
                  let pid = identity.pid
            else { continue }
            pidsByKey[identity.key] = pid
        }
        let pids = Array(pidsByKey.values)
        #expect(!pids.isEmpty)
        #expect(Set(pids).count == pids.count)
    }

    /// Every working directory a script's `sessionStarted` events name.
    private func directories(in script: DemoScript) -> [String] {
        script.steps.compactMap { step in
            guard case let .sessionStarted(identity) = step.event.kind else { return nil }
            return identity.gitRoot ?? identity.cwd
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
