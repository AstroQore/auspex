import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Session relations")
struct SessionRelationsTests {
    /// The root a guardian rollout says it belongs to.
    private static let rootID = "0198f4c2-77bd-7a10-b3e9-5c2d84f10ab6"
    private static let reviewID = "0198f6d0-11ac-7e54-8b26-3ad70f9c1e83"

    private func identity(
        _ harness: Harness,
        _ sessionID: String,
        variant: String? = nil,
        parent: SessionKey? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: harness, sessionID: sessionID),
            sourcePath: "/Users/example/.codex/sessions/2026/08/19/rollout-\(sessionID).jsonl",
            variant: variant,
            parent: parent,
            parentLink: parent == nil ? nil : .spawnedProcess,
            cwd: "/Users/example/Code/auspex"
        )
    }

    private func review(
        _ harness: Harness = .codex,
        root: String = SessionRelationsTests.rootID,
        parent: SessionKey? = nil
    ) -> SessionIdentity {
        identity(harness, Self.reviewID, variant: "auto-review:\(root)", parent: parent)
    }

    private func root(_ harness: Harness = .codex) -> SessionIdentity {
        identity(harness, Self.rootID, variant: "codex_cli_rs")
    }

    // MARK: - Reading the variant

    @Test("a guardian rollout names the root its variant encodes")
    func autoReviewRootIsParsed() {
        #expect(SessionRelations.autoReviewRootID(of: review()) == Self.rootID)
        #expect(SessionRelations.isAutoReview(review()))
    }

    @Test("an ordinary Codex rollout names nothing")
    func ordinaryRolloutHasNoRoot() {
        #expect(SessionRelations.autoReviewRootID(of: root()) == nil)
        #expect(SessionRelations.isAutoReview(root()) == false)
    }

    @Test("the encoding is Codex's, so another harness's variant is not read as one")
    func otherHarnessesAreLeftAlone() {
        // A Claude Code session whose variant happens to be spelled the same
        // way is not a Codex guardian run, and folding it under a Claude
        // session with that id would be inventing a relationship out of a
        // string prefix.
        let impostor = identity(.claudeCode, Self.reviewID, variant: "auto-review:\(Self.rootID)")
        #expect(SessionRelations.autoReviewRootID(of: impostor) == nil)
        #expect(SessionRelations.isAutoReview(impostor) == false)
        #expect(SessionRelations.links(identities: [
            impostor, identity(.claudeCode, Self.rootID)
        ]).isEmpty)
    }

    @Test("a rollout that names itself is a root, not its own child")
    func selfNamingRolloutIsNotItsOwnChild() {
        let narcissist = review(root: Self.reviewID)
        #expect(SessionRelations.autoReviewRootID(of: narcissist) == nil)
        #expect(SessionRelations.links(identities: [narcissist]).isEmpty)
        // It is still a review — the card should say so even with nothing to
        // link it to.
        #expect(SessionRelations.isAutoReview(narcissist))
    }

    // MARK: - Proposing links

    @Test("a guardian rollout is linked to the root on the board")
    func reviewIsLinkedToItsRoot() throws {
        let links = SessionRelations.links(identities: [root(), review()])
        let link = try #require(links.first)
        #expect(links.count == 1)
        #expect(link.child == SessionKey(harness: .codex, sessionID: Self.reviewID))
        #expect(link.parent == SessionKey(harness: .codex, sessionID: Self.rootID))
        // Recorded evidence, not inferred: an identity the run itself wrote.
        #expect(link.link == .subagent(toolUseID: nil))
        #expect(link.confidence == .high)
        // `ProcessLink.evidence` is safe to log — session keys only.
        #expect(!link.evidence.contains("/Users"))
    }

    @Test("a root that is not on the board leaves the review a root of its own")
    func noLinkWithoutTheRoot() {
        #expect(SessionRelations.links(identities: [review()]).isEmpty)
        // And it stays visible rather than disappearing.
        let tree = SessionTreeBuilder.build(identities: [review()])
        #expect(tree.roots.map(\.key) == [review().key])
    }

    @Test("a review that already has a parent is left alone")
    func recordedParentIsNotDisplaced() {
        let other = identity(.codex, "0198aaaa-0000-7000-8000-000000000000")
        let claimed = review(parent: other.key)
        #expect(SessionRelations.links(identities: [root(), other, claimed]).isEmpty)
    }

    @Test("a review of a ChatGPT Work thread finds its root under the sibling harness")
    func rootIsFoundUnderTheSiblingHarness() throws {
        // Both harnesses write into `~/.codex/sessions`, and only the header's
        // originator separates them — so a guardian run keyed to Codex can be
        // reviewing a thread keyed to ChatGPT Work.
        let identities = [root(.chatgptWork), review(.codex)]
        let link = try #require(SessionRelations.links(identities: identities).first)
        #expect(link.parent == SessionKey(harness: .chatgptWork, sessionID: Self.rootID))
    }

    @Test("the child's own harness wins when the id exists under both")
    func ownHarnessWinsOverTheSibling() throws {
        let identities = [root(.chatgptWork), root(.codex), review(.codex)]
        let link = try #require(SessionRelations.links(identities: identities).first)
        #expect(link.parent == SessionKey(harness: .codex, sessionID: Self.rootID))
    }

    @Test("the link is what the tree nests on")
    func linkNestsTheReviewUnderTheRoot() throws {
        var folded = review()
        let link = try #require(SessionRelations.links(identities: [root(), folded]).first)
        folded.parent = link.parent
        folded.parentLink = link.link

        let tree = SessionTreeBuilder.build(identities: [root(), folded])
        #expect(tree.roots.count == 1)
        #expect(tree.roots.first?.key == root().key)
        #expect(tree.roots.first?.children.map(\.key) == [folded.key])
        #expect(tree.rootKey(for: folded.key) == root().key)
    }

    @Test("nothing is proposed for an empty board")
    func emptyBoardProposesNothing() {
        #expect(SessionRelations.links(identities: []).isEmpty)
    }
}
