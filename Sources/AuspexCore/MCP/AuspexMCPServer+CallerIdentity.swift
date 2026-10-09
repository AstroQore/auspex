import AgentSessionKit
import AgentSessionLive
import Foundation

extension AuspexMCPServer {
    enum RequestScope {
        @TaskLocal static var attribution: MCPTransportAttribution = .absent
    }

    /// Who is calling, and how that was worked out.
    struct Caller {
        let session: SessionKey?
        let pid: pid_t?
        let evidence: String
    }

    /// The project a call is about: the one the caller named, or the one the
    /// caller is working in.
    ///
    /// The second half is the whole of why there is no "unfiled" any more. A
    /// worker filing a task says nothing about projects and its task lands
    /// where its session is, resolved by the same
    /// ``BoardSnapshot/projectKey(for:)`` the wall groups by — so the card and
    /// the task are in the same place on two different pages without anybody
    /// typing a path.
    ///
    /// A named project that nothing answers to is a failure rather than a
    /// silent fallback: an orchestrator that misspelled a path would otherwise
    /// file a dozen tasks in its own project and find out tomorrow.
    func projectKey(_ arguments: MCPArguments, caller: Caller) async throws -> String {
        let board = await host.boardSnapshot()
        if let raw = try arguments.optionalString("project") {
            guard let cleaned = MCPTextSanitizer.clean(raw, limit: 1_000),
                  let key = TaskProject.key(named: cleaned, in: board)
            else {
                throw MCPToolFailure(
                    "No project on the board is '\(raw)'. Pass an absolute path, or a name "
                        + "sessions.list shows — or leave 'project' out to file it where you are."
                )
            }
            return key
        }
        return TaskProject.resolve(explicit: nil, session: caller.session, board: board)
    }

    /// What a project key is called, for a payload a person will read.
    func projectName(_ key: String?) async -> String? {
        guard let key else { return nil }
        return TaskProject.displayName(forKey: key, in: await host.boardSnapshot())
    }

    /// Resolves the calling session from the peer stamped by Auspex's official
    /// stdio bridge and corroborated against the kernel's live socket roster.
    /// Old clients without the stamp remain compatible only when exactly one
    /// socket is attached; multiple connections without request attribution
    /// fail closed instead of choosing whoever happened to speak last.
    ///
    /// `session_id` corroborates process evidence whenever there is some: it
    /// must then name the same session, which makes a typo visible and stops
    /// any local MCP caller from acting as another session merely by naming a
    /// row on the board.
    ///
    /// When the process tree cannot answer — a Codex thread server runs every
    /// open thread in one process, and most harnesses tell their MCP servers
    /// nothing — `session_id` is accepted as a *bounded* self-report. See
    /// ``selfReported(_:reference:bridge:attempt:board:table:attribution:)``
    /// for the bounds; outside them it is refused with the reason.
    func caller(_ arguments: MCPArguments) async throws -> Caller {
        let board = await host.boardSnapshot()
        let table = await host.processTable()
        let roster = await host.clientRoster()
        let candidatePID: pid_t?
        let attributionEvidence: String?
        switch RequestScope.attribution {
        case .peer(let reported):
            let peer = pid_t(reported)
            if roster.processIDs.contains(peer) {
                candidatePID = peer
                attributionEvidence = "request-scoped bridge pid corroborated by the kernel roster"
            } else {
                candidatePID = nil
                attributionEvidence = "request-scoped bridge process \(reported) is not attached"
            }
        case .invalid:
            candidatePID = nil
            attributionEvidence = "the request carried malformed transport attribution"
        case .absent:
            if roster.connectionCount == 1, roster.processIDs.count == 1 {
                candidatePID = roster.processIDs[0]
                attributionEvidence = "single-connection compatibility fallback"
            } else {
                candidatePID = nil
                attributionEvidence = roster.connectionCount == 0
                    ? "nothing is attached to the Auspex socket"
                    : "\(roster.connectionCount) connections are attached without request-scoped identity"
            }
        }
        let attempt = candidatePID.map {
            resolver.attempt(
                pid: $0,
                candidates: board.sessions.map(MCPSelfResolver.Candidate.init),
                table: table,
                attached: roster.processIDs
            )
        }
        let automatic: Caller
        if let pid = candidatePID, let resolution = attempt?.resolution {
            automatic = Caller(
                session: resolution.session,
                pid: pid,
                evidence: resolution.evidence + "; " + (attributionEvidence ?? "socket peer")
            )
        } else {
            automatic = Caller(
                session: nil,
                pid: candidatePID,
                evidence: candidatePID.map {
                    attempt?.refusal
                        ?? "no session on the board owns process \($0) or any of its ancestors"
                } ?? attributionEvidence ?? "the socket caller is not attributable"
            )
        }

        guard let raw = try arguments.optionalString("session_id") else { return automatic }
        guard let cleaned = MCPTextSanitizer.clean(raw, limit: 200) else {
            throw MCPToolFailure("'session_id' must not be empty.")
        }
        let requested = try requestedSession(cleaned, board: board)
        if let resolved = automatic.session {
            guard requested == resolved else {
                throw MCPToolFailure(
                    "session_id '\(cleaned)' names \(requested.description), but this connection "
                        + "resolves to \(resolved.description). Auspex will not act as another session."
                )
            }
            return Caller(
                session: resolved,
                pid: automatic.pid,
                evidence: automatic.evidence + "; session_id agreed"
            )
        }
        guard let bridge = candidatePID else {
            throw MCPToolFailure(
                "Auspex cannot corroborate session_id '\(cleaned)' from this connection "
                    + "(\(automatic.evidence)). A session_id cannot identify its caller by itself."
            )
        }
        return try selfReported(
            requested,
            reference: cleaned,
            bridge: bridge,
            attempt: attempt,
            board: board,
            table: table,
            attribution: attributionEvidence ?? "socket peer"
        )
    }

    /// Accepts a `session_id` the process tree could not establish, within
    /// bounds that keep it from being an impersonation tool:
    ///
    /// 1. The connection itself is attributed — a kernel-corroborated bridge
    ///    pid, never a bare claim.
    /// 2. The named session is on the board, alive, and not ended.
    /// 3. The nearest harness process above the bridge is one that runs that
    ///    session's harness. A Codex bridge can name a Codex (or ChatGPT Work)
    ///    session and nothing else; there is no route from it to a Claude
    ///    Code row.
    /// 4. If the session records a pid that is still running, it is that same
    ///    harness process. A session demonstrably living in another process
    ///    belongs to that process.
    ///
    /// The evidence says "self-reported" first, so a person reading the
    /// claim history can tell it from one the kernel established.
    private func selfReported(
        _ requested: SessionKey,
        reference: String,
        bridge: pid_t,
        attempt: MCPSelfResolver.Attempt?,
        board: BoardSnapshot,
        table: any ProcessTableReading,
        attribution: String
    ) throws -> Caller {
        let because = attempt?.refusal
            ?? "no session on the board owns process \(bridge) or any of its ancestors"
        guard let session = board.session(for: requested), session.isAlive, !session.state.isEnded else {
            throw MCPToolFailure(
                "session_id '\(reference)' names \(requested.description), which is not running. "
                    + "Auspex accepts a self-reported session_id only for a live session (\(because))."
            )
        }
        guard let harness = attempt?.harness else {
            throw MCPToolFailure(
                "Auspex cannot corroborate session_id '\(reference)' from this connection: no process "
                    + "above it is a harness Auspex recognises (\(because)). "
                    + "A session_id cannot identify its caller by itself."
            )
        }
        guard harness.harnesses.contains(requested.harness) else {
            throw MCPToolFailure(
                "session_id '\(reference)' names a \(requested.harness.displayName) session, but this "
                    + "connection was opened by \(harness.executable) (process \(harness.pid)). "
                    + "Auspex will not act as a session of another harness."
            )
        }
        if let recorded = session.identity.pid, recorded != harness.pid,
           table.record(pid: recorded) != nil {
            throw MCPToolFailure(
                "session_id '\(reference)' names \(requested.description), which runs in process "
                    + "\(recorded), not in the \(harness.executable) process \(harness.pid) this "
                    + "connection belongs to. Auspex will not act as another session."
            )
        }
        return Caller(
            session: requested,
            pid: bridge,
            evidence: "self-reported, harness-corroborated by \(harness.executable) "
                + "(process \(harness.pid)); \(because); \(attribution)"
        )
    }

    /// A write that changes a session's state or authors history must have an
    /// attributable process. Task and milestone creation stay usable without
    /// one — they can be explicitly filed in a project or Scratch — but an
    /// anonymous caller cannot claim, finish, release, edit, log, archive, or
    /// signal on behalf of an agent.
    func requireAttributedCaller(
        _ arguments: MCPArguments,
        action: String
    ) async throws -> Caller {
        let caller = try await caller(arguments)
        guard caller.session != nil else {
            throw MCPToolFailure(
                "Auspex cannot \(action) without a process-attributed session "
                    + "(\(caller.evidence)). Call sessions.self to inspect the evidence. "
                    + "If it stays unresolved, pass your harness's own session id as session_id: "
                    + "Auspex accepts it for a live session of the harness this connection runs under."
            )
        }
        return caller
    }

    private func requestedSession(_ reference: String, board: BoardSnapshot) throws -> SessionKey {
        if let key = SessionKey(string: reference), board.session(for: key) != nil { return key }
        let matches = board.sessions.filter { $0.key.sessionID == reference }
        if matches.count == 1 { return matches[0].key }
        if matches.count > 1 {
            throw MCPToolFailure(
                "'\(reference)' matches \(matches.count) sessions. Pass '<harness>:<session id>'."
            )
        }
        throw MCPToolFailure("No session on the board is '\(reference)'.")
    }
}
