import AgentSessionKit
import AgentSessionLive
import Foundation
import Synchronization

/// What a Codex rollout's header says about the thread that spawned it.
///
/// A thread Codex starts itself — a sub-agent of a desktop conversation —
/// records where it came from in its `session_meta`:
///
/// ```json
/// "source": {"subagent": {"thread_spawn": {
///     "parent_thread_id": "…", "depth": 1,
///     "agent_path": "/root/factory_build", "agent_nickname": "…"}}}
/// ```
///
/// The kit reads this header for the cwd, the originator and the entrypoint
/// (`subagent`), and for a guardian run's root; it does not read
/// `thread_spawn`. So the parent the header names is not on the identity
/// unless the parent's own transcript linked it or the header also carried a
/// `session_id`, and nothing says where the thread ran.
///
/// ## Why it matters to grouping
///
/// A spawn whose `agent_path` sits under `/root/` ran in Codex's own
/// execution sandbox, and the directory it reports is that sandbox's, not a
/// folder on this Mac. Placed by its own `cwd` it becomes a project nobody has
/// — or, now, a scratch row nobody asked for. It is working on whatever its
/// parent is working on, so it takes its parent's project instead.
///
/// The fact is carried on the identity's ``SessionIdentity/variant`` as
/// `cloud:<parent thread id>` — the same trick the kit uses for a guardian's
/// `auto-review:<root>`. The identity is a kit type with no room for an
/// origin field, the variant on a Codex thread otherwise holds only its
/// originator, and an encoding every reader can parse from the identity alone
/// keeps ``SessionRelations`` and ``BoardSnapshot/projectKey(for:)`` pure.
public struct CodexThreadSpawn: Sendable, Hashable {
    /// The thread that spawned this one.
    public let parentThreadID: String
    /// Where in the spawning agent's tree this one sits, when recorded.
    public let agentPath: String?

    public init(parentThreadID: String, agentPath: String?) {
        self.parentThreadID = parentThreadID
        self.agentPath = agentPath
    }

    /// The root every cloud execution path hangs off.
    public static let cloudRoot = "/root/"

    /// What a cloud spawn's variant begins with.
    public static let variantPrefix = "cloud:"

    /// `true` when this thread ran in Codex's execution sandbox rather than
    /// in a directory on this Mac.
    public var runsInCloud: Bool { agentPath?.hasPrefix(Self.cloudRoot) ?? false }

    /// The variant a cloud spawn carries.
    public var cloudVariant: String { Self.variantPrefix + parentThreadID }

    // MARK: - Reading the header

    /// How many head lines are looked through. A forked thread replays its
    /// ancestors' headers before or after its own; four is room for that and
    /// still a bounded read.
    static let headerWindow = 4

    /// The spawn the header of `sessionID`'s rollout records, or `nil` when it
    /// records none.
    ///
    /// A header whose `id` names another thread is an ancestor's, replayed,
    /// and is skipped — the same rule the kit's mapper applies.
    public static func parse(headerLines: [Data], sessionID: String) -> CodexThreadSpawn? {
        for line in headerLines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            if let id = payload["id"] as? String,
               id.caseInsensitiveCompare(sessionID) != .orderedSame {
                continue
            }
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            guard let spawn = subagent?["thread_spawn"] as? [String: Any],
                  let parent = (spawn["parent_thread_id"] as? String)?
                      .trimmingCharacters(in: .whitespaces),
                  !parent.isEmpty,
                  parent.caseInsensitiveCompare(sessionID) != .orderedSame
            else { return nil }
            return CodexThreadSpawn(parentThreadID: parent, agentPath: spawn["agent_path"] as? String)
        }
        return nil
    }

    /// Reads the head of a rollout and parses it. Read-only, bounded to
    /// ``headerWindow`` lines; nothing from the file is kept but the two
    /// fields above.
    public static func read(rolloutAt path: String, sessionID: String) -> CodexThreadSpawn? {
        guard !path.isEmpty else { return nil }
        let lines = JSONLHeadTail.headLines(url: URL(fileURLWithPath: path), count: headerWindow)
        return parse(headerLines: lines, sessionID: sessionID)
    }

    /// Whether an identity could be a Codex-spawned thread whose header is
    /// worth reading: a Codex-store session whose entrypoint is `subagent`
    /// that is not a guardian run and is not already tagged.
    static func mayBeSpawn(_ identity: SessionIdentity) -> Bool {
        SessionRelations.codexStoreHarnesses.contains(identity.key.harness)
            && identity.entrypoint == subagentEntrypoint
            && !identity.sourcePath.isEmpty
            && !SessionRelations.isAutoReview(identity)
    }

    /// What the kit writes as the entrypoint of a thread Codex spawned.
    static let subagentEntrypoint = "subagent"
}

/// Which Codex threads ran in the cloud, read from each rollout's header once.
///
/// The grouping pass asks every few seconds; the header of a thread does not
/// change, so each candidate's file is opened once and the answer — spawn or
/// not — is remembered for as long as the session is on the board.
final class CodexSpawnMemo: Sendable {
    private struct State {
        var answers: [SessionKey: CodexThreadSpawn?] = [:]
        var reads = 0
    }

    private let state = Mutex(State())
    private let read: @Sendable (_ path: String, _ sessionID: String) -> CodexThreadSpawn?

    init(
        read: @escaping @Sendable (_ path: String, _ sessionID: String) -> CodexThreadSpawn?
            = { CodexThreadSpawn.read(rolloutAt: $0, sessionID: $1) }
    ) {
        self.read = read
    }

    /// How many headers have actually been read. Diagnostic, and what the
    /// suite asserts on.
    var readCount: Int { state.withLock { $0.reads } }

    /// The variant each cloud spawn among `identities` should carry and does
    /// not yet.
    ///
    /// Empty on a quiet board: an identity already tagged is not looked at
    /// again, and one whose header said "not a cloud spawn" is not re-read.
    /// A tag the kit overwrote — a rollout re-read from the top writes its
    /// originator back — is restored from the memo without opening the file.
    func pendingVariants(for identities: [SessionIdentity]) -> [SessionKey: String] {
        var out: [SessionKey: String] = [:]
        for identity in identities where !SessionRelations.isCloudSpawn(identity) {
            guard CodexThreadSpawn.mayBeSpawn(identity) else { continue }
            guard let spawn = answer(for: identity), spawn.runsInCloud else { continue }
            out[identity.key] = spawn.cloudVariant
        }
        prune(keeping: identities)
        return out
    }

    private func answer(for identity: SessionIdentity) -> CodexThreadSpawn? {
        if let known = state.withLock({ $0.answers[identity.key] }) { return known }
        let spawn = read(identity.sourcePath, identity.key.sessionID)
        state.withLock { state in
            state.answers[identity.key] = .some(spawn)
            state.reads += 1
        }
        return spawn
    }

    /// Forgets sessions that left the board, once there are more answers than
    /// sessions — so a long-running board does not keep every header it ever
    /// read.
    private func prune(keeping identities: [SessionIdentity]) {
        state.withLock { state in
            guard state.answers.count > identities.count else { return }
            let present = Set(identities.map(\.key))
            state.answers = state.answers.filter { present.contains($0.key) }
        }
    }
}
