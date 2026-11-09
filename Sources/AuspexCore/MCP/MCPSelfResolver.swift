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
///    `~/.claude/sessions/<pid>.json`; Grok registers its pid; a hook teaches
///    the rest (see ``HookProcessLearning``). When one of the ancestors *is* a
///    session's process, there is nothing to infer.
/// 2. **A session id in the environment.** Harnesses hand their own id down to
///    every child they spawn — that is how a tool subprocess knows which
///    conversation it belongs to — so the bridge process inherits it. The
///    values are read through ``ProcessTableReading/environment(pid:)``, which
///    redacts secret-shaped entries before anything sees them.
///
/// Nearest ancestor first, so a `codex` running inside a `claude` resolves to
/// the Codex session that actually spawned the bridge rather than to the
/// Claude session two levels up.
///
/// ## Where the walk stops
///
/// At the first ancestor that is a harness process (``HarnessProcess``). The
/// bridge belongs to that harness; everything above it is an *outer* one. A
/// Codex worker launched from a Claude Code session inherits
/// `CLAUDE_CODE_SESSION_ID` and has the Claude process as a grandparent, and
/// both used to resolve its calls to the Claude session — a misattribution
/// that looked exactly like success. Environment evidence is held to the same
/// boundary: it must name a session of the harness the walk is inside.
///
/// ## When a pid is not enough
///
/// One process can run several sessions: a Codex thread server keeps every
/// thread a desktop app has open, and a CLI can switch conversations without
/// exiting. So pid evidence is used only when it is unique — one owner, or
/// one *live* owner among several — and when the process is not serving
/// several Auspex bridges at once. Anything else is reported as ambiguous and
/// never settled by picking one.
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

    /// The flag Auspex's own stdio bridge runs with. Only consulted when the
    /// table carries argv, to tell a sibling bridge from a hook process.
    public static let bridgeFlag = "--mcp-stdio"

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

    /// A session the walk may resolve to.
    public struct Candidate: Sendable, Equatable {
        public let identity: SessionIdentity
        /// Alive and not ended. Used only to choose between several sessions
        /// that record the same pid, never to reject a lone one.
        public let isLive: Bool

        public init(identity: SessionIdentity, isLive: Bool = true) {
            self.identity = identity
            self.isLive = isLive
        }

        public init(_ snapshot: SessionSnapshot) {
            self.init(
                identity: snapshot.identity,
                isLive: snapshot.isAlive && !snapshot.state.isEnded
            )
        }
    }

    /// Everything one walk learned, including why it could not answer.
    public struct Attempt: Sendable, Equatable {
        public let resolution: Resolution?
        /// Why nothing resolved, when the walk found something more specific
        /// to say than "nothing matched". Safe to show, like the evidence.
        public let refusal: String?
        /// The nearest process at or above the client that is a harness —
        /// the program this connection belongs to — when there is one.
        public let harness: HarnessProcess?

        public init(resolution: Resolution?, refusal: String?, harness: HarnessProcess?) {
            self.resolution = resolution
            self.refusal = refusal
            self.harness = harness
        }
    }

    /// Resolves the calling session, or `nil` when nothing identifies it.
    /// Every identity counts as live.
    public func resolve(
        pid: pid_t?,
        identities: [SessionIdentity],
        table: any ProcessTableReading
    ) -> Resolution? {
        attempt(
            pid: pid,
            candidates: identities.map { Candidate(identity: $0) },
            table: table
        ).resolution
    }

    /// Resolves the calling session from the board's own rows.
    public func resolve(
        pid: pid_t?,
        sessions: [SessionSnapshot],
        table: any ProcessTableReading
    ) -> Resolution? {
        attempt(pid: pid, candidates: sessions.map(Candidate.init), table: table).resolution
    }

    /// Walks from `pid` towards the nearest harness process.
    ///
    /// - Parameters:
    ///   - pid: the client's pid — the socket's peer, or the harness itself
    ///     when a hook reported its parent.
    ///   - candidates: the sessions on the board.
    ///   - table: the process table to walk. Cached, so an ancestor walk and a
    ///     handful of environment reads cost one sweep between them.
    ///   - attached: the pids attached to the Auspex socket right now. Used to
    ///     count how many bridges one process is serving; empty skips that.
    public func attempt(
        pid: pid_t?,
        candidates: [Candidate],
        table: any ProcessTableReading,
        attached: [pid_t] = []
    ) -> Attempt {
        guard let pid, pid > 0 else { return Attempt(resolution: nil, refusal: nil, harness: nil) }

        let client = table.record(pid: pid)
        var levels: [(pid: pid_t, record: ProcessRecord?)] = [(pid, client)]
        levels.append(contentsOf: table.ancestors(of: pid).prefix(maximumDepth).map { ($0.pid, $0) })

        // The first harness on the way up owns the connection. Recognising it
        // can read one environment (Codex's host marker), and only for it.
        var harnessIndex: Int?
        var harness: HarnessProcess?
        for (index, level) in levels.enumerated() {
            guard let record = level.record,
                  let recognized = HarnessProcess.recognize(record, table: table)
            else { continue }
            harnessIndex = index
            harness = recognized
            break
        }

        guard !candidates.isEmpty else {
            return Attempt(resolution: nil, refusal: nil, harness: harness)
        }

        var owners: [pid_t: [Candidate]] = [:]
        var bySessionID: [String: [Candidate]] = [:]
        for candidate in candidates {
            if let owned = candidate.identity.pid { owners[owned, default: []].append(candidate) }
            bySessionID[candidate.identity.key.sessionID, default: []].append(candidate)
        }

        for (index, level) in levels.enumerated() {
            let candidatePID = level.pid
            var ambiguity: String?

            if let found = owners[candidatePID], !found.isEmpty {
                let live = found.filter(\.isLive)
                let chosen = found.count == 1 ? found[0] : (live.count == 1 ? live[0] : nil)
                let hosted = index == harnessIndex && harness?.isMultiSession == true
                let bridges = index > 0
                    ? Self.bridgeCount(under: candidatePID, client: pid, attached: attached, table: table)
                    : 0
                if let chosen, !hosted, bridges <= 1 {
                    let key = chosen.identity.key
                    return Attempt(
                        resolution: Resolution(
                            session: key,
                            evidence: index == 0
                                ? "the client process is session \(key.description)"
                                : "process \(candidatePID), \(index) level(s) above the client, "
                                    + "is session \(key.description)"
                        ),
                        refusal: nil,
                        harness: harness
                    )
                }
                if hosted {
                    ambiguity = "process \(candidatePID) is a \(harness?.executable ?? "harness") "
                        + "that hosts many sessions at once"
                } else if bridges > 1 {
                    ambiguity = "process \(candidatePID) serves \(bridges) Auspex connections, "
                        + "one per session it runs"
                } else {
                    ambiguity = "\(found.count) sessions on the board run in process \(candidatePID)"
                }
            }

            if let resolution = environmentResolution(
                at: candidatePID,
                governedBy: harnessIndex.map { $0 >= index } == true ? harness : nil,
                bySessionID: bySessionID,
                table: table
            ) {
                return Attempt(resolution: resolution, refusal: nil, harness: harness)
            }

            if let ambiguity {
                return Attempt(resolution: nil, refusal: ambiguity, harness: harness)
            }
            if index == harnessIndex, let harness {
                // Anything further up is an outer harness, not this caller.
                return Attempt(
                    resolution: nil,
                    refusal: harness.isMultiSession
                        ? "process \(candidatePID) is a \(harness.executable) that hosts many "
                            + "sessions at once, and none of its own processes names the caller"
                        : "the nearest harness process, \(harness.executable) (process \(candidatePID)), "
                            + "is not a session on the board yet",
                    harness: harness
                )
            }
        }
        return Attempt(resolution: nil, refusal: nil, harness: harness)
    }

    /// A session id one level's environment names, held to the harness the
    /// walk is inside.
    ///
    /// A variable that names a session of a *different* harness was inherited
    /// from an outer one, and a session that runs in another live process is
    /// that process's, not this caller's — both are passed over rather than
    /// believed.
    private func environmentResolution(
        at pid: pid_t,
        governedBy governing: HarnessProcess?,
        bySessionID: [String: [Candidate]],
        table: any ProcessTableReading
    ) -> Resolution? {
        guard let environment = table.environment(pid: pid) else { return nil }
        for (variable, hinted) in Self.sessionEnvironmentKeys {
            guard let value = environment[variable], let matches = bySessionID[value] else { continue }
            var eligible = matches
            if let governing {
                eligible = eligible.filter { candidate in
                    guard governing.harnesses.contains(candidate.identity.key.harness) else {
                        return false
                    }
                    if let recorded = candidate.identity.pid, recorded != governing.pid,
                       table.record(pid: recorded) != nil {
                        return false
                    }
                    return true
                }
            }
            guard !eligible.isEmpty else { continue }
            // The variable names a harness; prefer the session that agrees
            // with it, because one id can legitimately appear on two rows
            // (a CLI session and its desktop twin).
            let key = (eligible.first { $0.identity.key.harness == hinted } ?? eligible[0]).identity.key
            return Resolution(
                session: key,
                evidence: "\(variable) in the environment of process \(pid) names \(key.description)"
            )
        }
        return nil
    }

    /// How many of the connections attached right now are bridges the given
    /// process spawned itself.
    ///
    /// Read from the socket's live roster rather than from the process table's
    /// children: a hook is the same binary and a direct child too, and the
    /// table's snapshot can be seconds old, so counting children would now and
    /// then mistake one session plus a hook for two sessions.
    static func bridgeCount(
        under parent: pid_t,
        client: pid_t,
        attached: [pid_t],
        table: any ProcessTableReading
    ) -> Int {
        var count = 0
        for peer in Set(attached + [client]) {
            guard let record = table.record(pid: peer), record.ppid == parent else { continue }
            if !record.argv.isEmpty, !record.argv.contains(bridgeFlag) { continue }
            count += 1
        }
        return count
    }
}
