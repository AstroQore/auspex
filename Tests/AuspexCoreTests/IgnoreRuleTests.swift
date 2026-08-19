import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

/// What each kind of rule matches, what disappears from the board when it
/// does, and what survives a round trip through `~/.auspex/settings.json`.
@Suite("Ignore rules")
struct IgnoreRuleTests {
    // MARK: - Fixtures

    private func session(
        _ id: String,
        harness: Harness = .claudeCode,
        cwd: String? = "/Users/example/Code/auspex",
        gitRoot: String? = nil,
        parent: SessionKey? = nil,
        title: String? = nil,
        state: SessionState = .thinking
    ) -> SessionSnapshot {
        let key = SessionKey(harness: harness, sessionID: id)
        var snapshot = SessionStateReducer.initialSnapshot(
            identity: SessionIdentity(
                key: key,
                sourcePath: "/Users/example/store/\(id).jsonl",
                parent: parent,
                cwd: cwd,
                gitRoot: gitRoot,
                title: title
            )
        )
        snapshot.state = state
        snapshot.isAlive = true
        snapshot.lastEventAt = Fixtures.date(0)
        return snapshot
    }

    private func board(_ sessions: [SessionSnapshot]) -> BoardSnapshot {
        BoardSnapshot(generatedAt: Fixtures.date(0), sessions: sessions)
    }

    private func visible(
        _ sessions: [SessionSnapshot],
        _ rules: [IgnoreRule],
        claims: ProjectClaims = .empty,
        showsIgnored: Bool = false
    ) -> VisibleBoard {
        BoardFilter.apply(
            to: board(sessions),
            claims: claims,
            rules: IgnoreRules(rules),
            showsIgnored: showsIgnored
        )
    }

    // MARK: - One rule per kind

    @Test("A folder rule hides everything working under it, and nothing beside it")
    func pathPrefixMatchesSubdirectoriesOnly() {
        let inside = session("1", cwd: "/Users/example/Code/auspex/Sources")
        let sibling = session("2", cwd: "/Users/example/Code/auspex-notes")
        let result = visible(
            [inside, sibling],
            [IgnoreRule(kind: .pathPrefix("/Users/example/Code/auspex"))]
        )

        #expect(result.ignored == [inside.key])
        #expect(result.board.sessions.map(\.key) == [sibling.key])
    }

    @Test("A folder rule also sees the git root and the worktree")
    func pathPrefixMatchesEveryDirectoryASessionReports() {
        var snapshot = session("1", cwd: "/tmp/elsewhere", gitRoot: "/Users/example/Code/auspex")
        snapshot.identity.worktreePath = "/Users/example/Code/auspex/.agents/worktrees/x"
        let result = visible([snapshot], [IgnoreRule(kind: .pathPrefix("/Users/example/Code"))])
        #expect(result.board.sessions.isEmpty)
    }

    @Test("A project rule hides a project however its sessions were placed")
    func projectRuleMatchesTheBoardsKey() {
        let claims = ProjectClaims(projects: [
            AuspexProject(
                name: "Storefront",
                roots: ["/Users/example/Code/storefront-web", "/Users/example/Code/payments-api"],
                createdAt: Fixtures.date(0)
            )
        ])
        let web = session("1", cwd: "/Users/example/Code/storefront-web")
        let api = session("2", cwd: "/Users/example/Code/payments-api")
        let other = session("3", cwd: "/Users/example/Code/auspex")

        // By the name a person gave it…
        let byName = visible(
            [web, api, other],
            [IgnoreRule(kind: .project("Storefront"))],
            claims: claims
        )
        #expect(byName.board.sessions.map(\.key) == [other.key])

        // …and by the key the board groups under.
        let byKey = visible(
            [web, api, other],
            [IgnoreRule(kind: .project("/Users/example/Code/storefront-web"))],
            claims: claims
        )
        #expect(byKey.board.sessions.map(\.key) == [other.key])
    }

    @Test("A project rule names an automatic project by its own name")
    func projectRuleMatchesAnAutomaticProject() {
        let session = session("1", cwd: "/Users/example/Code/design-tokens")
        #expect(visible([session], [IgnoreRule(kind: .project("design-tokens"))])
            .board.sessions.isEmpty)
    }

    @Test("A harness rule hides that harness and leaves the others")
    func harnessRule() {
        let claude = session("1")
        let codex = session("2", harness: .codex)
        let result = visible([claude, codex], [IgnoreRule(kind: .harness(.codex))])
        #expect(result.board.sessions.map(\.key) == [claude.key])
    }

    @Test("A title rule matches anywhere in the title, ignoring case")
    func titleContainsRule() {
        let noisy = session("1", title: "Nightly dependency AUDIT")
        let real = session("2", title: "Fix the cart total")
        let result = visible([noisy, real], [IgnoreRule(kind: .titleContains("audit"))])
        #expect(result.board.sessions.map(\.key) == [real.key])
    }

    /// The rule the kit cannot answer yet. It matches the title until
    /// `SessionSnapshot.brief.firstPrompt` lands, and this is the test that
    /// says so — when the field arrives, this becomes a first-prompt test and
    /// the title case moves to `titleContains`.
    @Test("A prompt-prefix rule matches the opening of the title, for now")
    func promptPrefixRuleFallsBackToTheTitle() {
        let scripted = session("1", title: "chore: sync the changelog")
        let human = session("2", title: "Fix the cart total")
        let result = visible([scripted, human], [IgnoreRule(kind: .promptPrefix("chore:"))])
        #expect(result.ignored == [scripted.key])
        #expect(result.board.sessions.map(\.key) == [human.key])
    }

    @Test("A prompt-prefix rule matches nothing on a session with no title yet")
    func promptPrefixNeedsSomethingToMatch() {
        let untitled = session("1", title: nil)
        #expect(visible([untitled], [IgnoreRule(kind: .promptPrefix("chore:"))])
            .board.sessions.count == 1)
    }

    // MARK: - What the board does with a match

    @Test("Hiding a session hides what it delegated to")
    func descendantsFollowTheirParent() {
        let parent = session("1", cwd: "/Users/example/Code/scratch")
        let child = session("2", cwd: nil, parent: parent.key)
        let grandchild = session("3", cwd: nil, parent: child.key)
        let other = session("4", cwd: "/Users/example/Code/auspex")

        let result = visible(
            [parent, child, grandchild, other],
            [IgnoreRule(kind: .pathPrefix("/Users/example/Code/scratch"))]
        )
        #expect(result.ignored == [parent.key, child.key, grandchild.key])
        #expect(result.board.sessions.map(\.key) == [other.key])
    }

    @Test("The counts, the groups and the summary all come from the visible board")
    func countsFollowTheFilter() {
        let kept = session("1", state: .waitingPermission(tool: "Bash"))
        let hidden = session("2", harness: .codex, state: .waitingPermission(tool: "Bash"))
        let result = visible([kept, hidden], [IgnoreRule(kind: .harness(.codex))])

        #expect(result.board.counts.waitingPermission == 1)
        #expect(BoardSummary(board: result.board).needsYou == 1)
        #expect(BoardGrouping.groups(for: result.board, groupBy: .harness).count == 1)
        #expect(ProjectTree.build(board: result.board).projects.count == 1)
    }

    @Test("A disabled rule hides nothing")
    func disabledRulesAreInert() {
        let session = session("1")
        let rule = IgnoreRule(kind: .harness(.claudeCode), isEnabled: false)
        #expect(visible([session], [rule]).board.sessions.count == 1)
        #expect(IgnoreRules([rule]).isEmpty)
    }

    @Test("Showing ignored sessions puts them back and still says which they are")
    func showIgnoredKeepsTheRows() {
        let kept = session("1")
        let hidden = session("2", harness: .codex)
        let result = visible([kept, hidden], [IgnoreRule(kind: .harness(.codex))],
                             showsIgnored: true)
        #expect(result.board.sessions.count == 2)
        #expect(result.ignored == [hidden.key])
        #expect(result.ignoredCount == 1)
    }

    @Test("No rules at all is the same frame, unchanged")
    func noRulesIsTheIdentity() {
        let frame = board([session("1"), session("2")])
        let result = BoardFilter.apply(to: frame, claims: .empty, rules: .none)
        #expect(result.board == frame)
        #expect(result.ignored.isEmpty)
    }

    // MARK: - Persistence

    @Test("Rules survive a round trip through ~/.auspex/settings.json")
    func rulesRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = AuspexSettingsStore(paths: AuspexPaths(homeDirectory: home))

        #expect(store.load().isEmpty)

        let settings = AuspexSettings(
            ignoreRules: [
                IgnoreRule(kind: .pathPrefix("/Users/example/Code/vendor")),
                IgnoreRule(kind: .harness(.grokBot), isEnabled: false),
                IgnoreRule(kind: .promptPrefix("chore:")),
                IgnoreRule(kind: .project("Storefront")),
                IgnoreRule(kind: .titleContains("audit")),
            ],
            showsIgnored: true
        )
        try store.save(settings)

        let loaded = store.load()
        #expect(loaded.showsIgnored)
        #expect(loaded.ignoreRules.count == 5)
        #expect(loaded.ignoreRules.map(\.kind) == settings.ignoreRules.map(\.kind))
        #expect(loaded.ignoreRules[1].isEnabled == false)
    }

    @Test("A rule of a kind this build does not know costs itself, not the file")
    func unknownRuleKindIsDropped() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("auspex-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        try paths.ensureBaseDirectory()
        try """
            {"ignoreRules": [
                {"id": "00000000-0000-0000-0000-000000000001", "type": "fromTheFuture",
                 "value": "x", "enabled": true},
                {"id": "00000000-0000-0000-0000-000000000002", "type": "harness",
                 "value": "codex", "enabled": true}
            ], "showsIgnored": false}
            """.write(to: paths.settingsURL, atomically: true, encoding: .utf8)

        let loaded = AuspexSettingsStore(paths: paths).load()
        #expect(loaded.ignoreRules.count == 1)
        #expect(loaded.ignoreRules.first?.kind == .harness(.codex))
    }
}
