import AgentSessionKit
import AgentSessionLive
import Foundation

/// Works out which session is calling, from the pid on the other end of the
/// socket.
///
/// ## Why an agent must not have to know its own id
///
/// Every harness knows its session id and almost none of them tell their MCP
/// servers. A protocol that asked an agent to pass `session_id` would work
/// exactly until the first harness that does not export it — and would fail
/// silently, by attributing one agent's call to nobody.
///
/// The pid answers it instead. `MCPSocketServer` reports the kernel's own
/// `LOCAL_PEERPID` for each client, which is the `Auspex --mcp-stdio` process
/// the harness spawned. Walking up from there reaches the harness itself, and
/// two kinds of evidence identify it:
///
/// 1. **A pid the board already knows.** Claude Code writes
///    `~/.claude/sessions/<pid>.json`; Grok registers its pid. When one of the
///    ancestors *is* a session's process, there is nothing to infer.
/// 2. **A session id in the environment.** Harnesses hand their own id down to
///    every child they spawn — that is how a tool subprocess knows which
///    conversation it belongs to — so the bridge process inherits it. The
///    values are read through ``ProcessTableReading/environment(pid:)``, which
///    redacts secret-shaped entries before anything sees them.
///
/// Nearest ancestor first, so a `codex` running inside a `claude` resolves to
/// the Codex session that actually spawned the bridge rather than to the
/// Claude session two levels up.
public struct MCPSelfResolver: Sendable {
    /// The environment variables harnesses export their session id in.
    ///
    /// Each maps to the harness that writes it, which is used as a hint rather
    /// than a requirement: `chatgptWork` and `codex` share `CODEX_SESSION_ID`
    /// and are told apart by which board session actually carries the id.
    public static let sessionEnvironmentKeys: [(key: String, harness: Harness)] = [
        ("CLAUDE_CODE_SESSION_ID", .claudeCode),
        ("CODEX_SESSION_ID", .codex),
        ("CODEX_THREAD_ID", .codex),
        ("GROK_SESSION_ID", .grokBuild),
        ("CURSOR_AGENT_CHAT_ID", .cursor),
        ("ANTIGRAVITY_CONVERSATION_ID", .antigravity)
    ]

    /// How far up the process tree to look.
    ///
    /// A bridge is one hop below its harness in the ordinary case and a few
    /// more when a shell or a wrapper sits between them. Twelve is past any
    /// real arrangement and bounds the number of `KERN_PROCARGS2` reads a
    /// single `sessions.self` can cause.
    public let maximumDepth: Int

    public init(maximumDepth: Int = 12) {
        self.maximumDepth = maximumDepth
    }

    /// What was worked out, and from what.
    public struct Resolution: Sendable, Equatable {
        public let session: SessionKey
        /// One sentence naming the evidence. Safe to log and to show: it
        /// carries a pid, a variable name, and a session key, never a value,
        /// a path, or a command line.
        public let evidence: String

        public init(session: SessionKey, evidence: String) {
            self.session = session
            self.evidence = evidence
        }
    }

    /// Resolves the calling session, or `nil` when nothing identifies it.
    ///
    /// - Parameters:
    ///   - pid: the client's pid — the socket's peer, or the ppid a bridge
    ///     declared in its `auspex/hello`.
    ///   - identities: the sessions on the board.
    ///   - table: the process table to walk. Cached, so an ancestor walk and a
    ///     handful of environment reads cost one sweep between them.
    public func resolve(
        pid: pid_t?,
        identities: [SessionIdentity],
        table: any ProcessTableReading
    ) -> Resolution? {
        guard let pid, pid > 0, !identities.isEmpty else { return nil }

        var byPID: [pid_t: SessionKey] = [:]
        var bySessionID: [String: [SessionKey]] = [:]
        for identity in identities {
            if let identityPID = identity.pid { byPID[identityPID] = identity.key }
            bySessionID[identity.key.sessionID, default: []].append(identity.key)
        }

        var chain: [pid_t] = [pid]
        chain.append(contentsOf: table.ancestors(of: pid).prefix(maximumDepth).map(\.pid))

        for (index, candidate) in chain.enumerated() where index <= maximumDepth {
            if let key = byPID[candidate] {
                return Resolution(
                    session: key,
                    evidence: index == 0
                        ? "the client process is session \(key.description)"
                        : "process \(candidate), \(index) level(s) above the client, is session \(key.description)"
                )
            }
            guard let environment = table.environment(pid: candidate) else { continue }
            for (variable, harness) in Self.sessionEnvironmentKeys {
                guard let value = environment[variable],
                      let matches = bySessionID[value], !matches.isEmpty
                else { continue }
                // The variable names a harness; prefer the session that agrees
                // with it, because one id can legitimately appear on two rows
                // (a CLI session and its desktop twin).
                let key = matches.first { $0.harness == harness } ?? matches[0]
                return Resolution(
                    session: key,
                    evidence: "\(variable) in the environment of process \(candidate) names \(key.description)"
                )
            }
        }
        return nil
    }
}
