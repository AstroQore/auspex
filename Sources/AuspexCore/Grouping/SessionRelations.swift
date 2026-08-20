import AgentSessionKit
import AgentSessionLive
import Foundation

/// Parent/child edges a harness records in a session's *identity* rather than
/// in either transcript.
///
/// ``ProcessLinker`` answers "who spawned this?" by reading the machine — the
/// process tree, an inherited environment variable — because two harnesses
/// that spawn each other write nothing about it. This answers the same
/// question for the case where the harness did write it down, just not in a
/// place a transcript reader would look: Codex encodes a guardian rollout's
/// originating thread in the session's provider variant
/// (`auto-review:<root session id>`), and nothing in either rollout's *body*
/// mentions the other.
///
/// Auto Review is the first of those, and the shape is worth keeping separate
/// from the process linker for the reason the kit gives for the encoding: this
/// is a *recorded* relationship, not an inferred one. It is as good as the
/// parent's own log — better, in the Codex case, because `parent_thread_id`
/// can name an intermediate sub-agent while `session_id` names the root
/// directly — so it is proposed with ``ParentLink/subagent`` and the highest
/// confidence, and an inference from the process table can never displace it.
///
/// ## What it deliberately does not do
///
/// - **It never invents a parent that is not on the board.** A guardian
///   rollout whose root has aged out stays a root of its own. A dangling edge
///   would make it an orphan with extra steps — see ``SessionTreeBuilder``.
/// - **It never overwrites a parent already recorded.** A session that arrived
///   with a link keeps it; this only fills blanks, exactly like
///   ``ProcessLinker/infer(identities:table:)``.
/// - **It reads the variant, not the file.** The parse is
///   ``CodexSessionAdapter/autoReviewParentSessionID(providerVariant:)``, the
///   kit's own, so the two layers cannot drift into disagreeing about what an
///   auto-review variant looks like.
public enum SessionRelations {
    /// The harnesses that write into `~/.codex/sessions`, and so the ones a
    /// Codex root session id can belong to.
    ///
    /// Only the rollout header's `originator` separates them, and a guardian
    /// run does not have to carry the same one as the thread it is reviewing —
    /// so the root is looked for under the child's own harness first and under
    /// its sibling second, rather than being assumed.
    static let codexStoreHarnesses: [Harness] = [.codex, .chatgptWork]

    /// The root session id a Codex Auto Review rollout belongs to, or `nil`
    /// when this is not one.
    ///
    /// `nil` for every harness but the two that share the Codex store: the
    /// `auto-review:` variant is Codex's encoding, and reading it off an
    /// unrelated harness's variant would be inventing a relationship out of a
    /// string that happens to start the same way.
    public static func autoReviewRootID(of identity: SessionIdentity) -> String? {
        guard codexStoreHarnesses.contains(identity.key.harness) else { return nil }
        guard let root = CodexSessionAdapter.autoReviewParentSessionID(
            providerVariant: identity.variant
        ) else { return nil }
        // A rollout that names itself is a root, not its own child.
        guard root.caseInsensitiveCompare(identity.key.sessionID) != .orderedSame else { return nil }
        return root
    }

    /// `true` when this session is a Codex Auto Review run.
    ///
    /// Deliberately independent of whether the root is on the board: a
    /// guardian rollout whose root has aged out is still a review, and the
    /// card should say so even when there is nothing to link it to.
    public static func isAutoReview(_ identity: SessionIdentity) -> Bool {
        guard codexStoreHarnesses.contains(identity.key.harness) else { return false }
        return CodexSessionAdapter.autoReviewParentSessionID(providerVariant: identity.variant)
            != nil
    }

    /// The parent edges recorded in `identities` but not yet folded into them.
    ///
    /// Pure and total, like every grouping pass: same input, same output, no
    /// filesystem and no process table. What comes back is a proposal in the
    /// same shape ``ProcessLinker`` produces, so ``SessionRegistry/applyLinks(_:)``
    /// applies both through one path and one set of guards.
    ///
    /// - Parameter identities: whatever the board is holding. Routinely
    ///   incomplete — a review whose root is not here yields nothing.
    /// - Returns: one link per auto-review session whose root is present and
    ///   whose own parent is still unknown, in input order.
    public static func links(identities: [SessionIdentity]) -> [ProcessLink] {
        let present = Set(identities.map(\.key))
        guard !present.isEmpty else { return [] }

        var links: [ProcessLink] = []
        for identity in identities where identity.parent == nil {
            guard let rootID = autoReviewRootID(of: identity) else { continue }
            guard let parent = rootKey(rootID, for: identity.key, among: present) else { continue }
            links.append(ProcessLink(
                child: identity.key,
                parent: parent,
                // The same evidence class an adapter emits for a spawn the
                // parent's own log recorded: the id came out of the child's
                // own header, which only the run that started it could have
                // written there. No call id — a guardian run is not a tool
                // call in the root's transcript.
                link: .subagent(toolUseID: nil),
                confidence: .high,
                // Session keys only, per `ProcessLink.evidence`: no path, no
                // command, nothing out of a transcript.
                evidence: "provider variant names root session \(parent)"
            ))
        }
        return links
    }

    /// Which of the Codex-store harnesses the root id belongs to.
    ///
    /// The child's own harness first, because a review of a Codex thread is
    /// overwhelmingly a Codex thread; the sibling second, so a ChatGPT Work
    /// thread reviewed by an ordinary Codex guardian still finds its root.
    /// Ambiguity is impossible here — the same id under both harnesses would
    /// be two different threads that happen to share a UUID, and the child's
    /// own harness is the better answer either way.
    private static func rootKey(
        _ rootID: String,
        for child: SessionKey,
        among present: Set<SessionKey>
    ) -> SessionKey? {
        let ordered = [child.harness] + codexStoreHarnesses.filter { $0 != child.harness }
        for harness in ordered {
            let candidate = SessionKey(harness: harness, sessionID: rootID)
            if candidate != child, present.contains(candidate) { return candidate }
        }
        return nil
    }
}
