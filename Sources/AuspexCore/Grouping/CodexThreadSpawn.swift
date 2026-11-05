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
///     "agent_path": "/root/<name>", "agent_nickname": "…"}}}
/// ```
///
/// `agent_path` is the spawn's place in Codex's own tree of agents — the
/// conversation's agent is `/root` — and not a directory: these threads run on
/// this Mac, in the same checkout as the thread that spawned them. Nothing here
/// reads it.
///
/// The kit reads this header for the cwd, the originator and the entrypoint
/// (`subagent`), and for a guardian run's root; it does not read
/// `thread_spawn`. So the parent the header names is not on the identity
/// unless the parent's own transcript linked it or the header also carried a
/// `session_id`.
///
/// ## Why it matters to grouping
///
/// A spawned thread is working on whatever its parent is working on, and the
/// working directory it reports is not a reliable way to say so: it is not
/// always a plain path, and placed by it on its own the thread can become a
/// project of one, or a scratch row nobody asked for. So it takes its parent's
/// project instead, whatever its own directory says.
///
/// The fact is carried on the identity's ``SessionIdentity/variant`` as
/// `spawn:<parent thread id>` — the same trick the kit uses for a guardian's
/// `auto-review:<root>`. The identity is a kit type with no field for it, the
/// variant on a Codex thread otherwise holds only its originator, and an
/// encoding every reader can parse from the identity alone keeps
/// ``SessionRelations`` and ``BoardSnapshot/projectKey(for:)`` pure.
public struct CodexThreadSpawn: Sendable, Hashable {
    /// The thread that spawned this one.
    public let parentThreadID: String

    public init(parentThreadID: String) {
        self.parentThreadID = parentThreadID
    }

    /// What a spawned thread's variant begins with.
    public static let variantPrefix = "spawn:"

    /// The variant a spawned thread carries.
    public var variant: String { Self.variantPrefix + parentThreadID }

    // MARK: - Reading the header

    /// The most head lines looked through.
    ///
    /// A forked thread replays every ancestor's `session_meta` ahead of its
    /// own, one per generation, so the header is as long as the chain is deep
    /// — a fixed window of four lost the thread's own header at depth four.
    /// The scan stops at the first record that is not a `session_meta`, which
    /// is where every real header ends; this cap is only what keeps a file
    /// that never stops being one from being read whole.
    static let headerLimit = 64

    /// The longest single header line read before the scan gives up on it.
    ///
    /// A `session_meta` carries the base instructions and runs to tens of
    /// kilobytes; the first record after the header can be a tool output of
    /// any size, and reading a megabyte of it to learn it is not a header is
    /// the whole cost this bound exists to refuse.
    static let headerLineLimit = 1 << 20

    /// The spawn the header of `sessionID`'s rollout records, or `nil` when it
    /// records none.
    ///
    /// The header is the leading run of `session_meta` records, and it ends at
    /// the first line that is not one. A forked thread's run holds its
    /// ancestors' headers, replayed, and then its own; so the thread's header
    /// is the **last** one in the run that names this thread (or names none).
    /// One whose `id` names another thread is an ancestor's and is never
    /// read as this thread's — the same rule the kit's mapper applies — and a
    /// `session_meta` after the run ended is not part of the header at all.
    public static func parse(headerLines: [Data], sessionID: String) -> CodexThreadSpawn? {
        var own: [String: Any]?
        for line in headerLines.prefix(headerLimit) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "session_meta"
            else { break }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            if let id = payload["id"] as? String,
               id.caseInsensitiveCompare(sessionID) != .orderedSame {
                continue
            }
            own = payload
        }
        guard let own else { return nil }
        let source = own["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        guard let spawn = subagent?["thread_spawn"] as? [String: Any],
              let parent = (spawn["parent_thread_id"] as? String)?
                  .trimmingCharacters(in: .whitespaces),
              !parent.isEmpty,
              parent.caseInsensitiveCompare(sessionID) != .orderedSame
        else { return nil }
        return CodexThreadSpawn(parentThreadID: parent)
    }

    /// Reads the head of a rollout and parses it. Read-only, and it reads no
    /// further than the first record after the header — see ``headerLimit``;
    /// nothing from the file is kept but the parent's thread id.
    public static func read(rolloutAt path: String, sessionID: String) -> CodexThreadSpawn? {
        guard !path.isEmpty else { return nil }
        let lines = headerLines(url: URL(fileURLWithPath: path))
        return parse(headerLines: lines, sessionID: sessionID)
    }

    /// The rollout's leading `session_meta` lines, plus the one line after
    /// them that ended the run, at most ``headerLimit`` of them.
    ///
    /// Streams the file a chunk at a time rather than asking for a fixed
    /// number of lines, because the line that ends the header is the one that
    /// can be enormous and nothing past it is wanted. A line longer than
    /// ``headerLineLimit`` ends the read as though it were that line.
    static func headerLines(url: URL, chunkSize: Int = 16 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var out: [Data] = []
        // One growing buffer and two cursors — where the current line began
        // and how far it has been searched — so a long line is scanned once,
        // not once per chunk that extends it.
        var buffer: [UInt8] = []
        var lineStart = 0
        var searched = 0
        while out.count < headerLimit {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(contentsOf: chunk)
            while searched < buffer.count {
                guard buffer[searched] == 0x0A else {
                    searched += 1
                    continue
                }
                if searched > lineStart {
                    out.append(Data(buffer[lineStart..<searched]))
                    if out.count >= headerLimit || !isSessionMeta(out[out.count - 1]) {
                        return out
                    }
                }
                searched += 1
                lineStart = searched
            }
            if searched - lineStart > headerLineLimit { return out }
            if lineStart > chunkSize {
                buffer.removeFirst(lineStart)
                searched -= lineStart
                lineStart = 0
            }
        }
        if lineStart < buffer.count, out.count < headerLimit {
            out.append(Data(buffer[lineStart...]))
        }
        return out
    }

    /// Whether one line is a `session_meta` record.
    private static func isSessionMeta(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "session_meta"
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

/// Which Codex threads were spawned by another, read from each rollout's
/// header once.
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

    /// The variant each spawned thread among `identities` should carry and
    /// does not yet.
    ///
    /// Empty on a quiet board: an identity already tagged is not looked at
    /// again, and one whose header named no parent is not re-read.
    /// A tag the kit overwrote — a rollout re-read from the top writes its
    /// originator back — is restored from the memo without opening the file.
    func pendingVariants(for identities: [SessionIdentity]) -> [SessionKey: String] {
        var out: [SessionKey: String] = [:]
        for identity in identities where !SessionRelations.isThreadSpawn(identity) {
            guard CodexThreadSpawn.mayBeSpawn(identity) else { continue }
            guard let spawn = answer(for: identity) else { continue }
            out[identity.key] = spawn.variant
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
