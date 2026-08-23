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
    /// `session_id` is now a corroborating hint, never an override. It must
    /// resolve to the same session as the process evidence. This makes a typo
    /// visible and prevents any local MCP caller from acting as an arbitrary
    /// session merely by naming a row that exists on the board.
    func caller(_ arguments: MCPArguments) async throws -> Caller {
        let board = await host.boardSnapshot()
        let identities = board.sessions.map(\.identity)
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
        let automatic: Caller
        if let pid = candidatePID,
           let resolution = resolver.resolve(pid: pid, identities: identities, table: table) {
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
                    "no session on the board owns process \($0) or any of its ancestors"
                } ?? attributionEvidence ?? "the socket caller is not attributable"
            )
        }

        guard let raw = try arguments.optionalString("session_id") else { return automatic }
        guard let cleaned = MCPTextSanitizer.clean(raw, limit: 200) else {
            throw MCPToolFailure("'session_id' must not be empty.")
        }
        let requested = try requestedSession(cleaned, board: board)
        guard let resolved = automatic.session else {
            throw MCPToolFailure(
                "Auspex cannot corroborate session_id '\(cleaned)' from this connection "
                    + "(\(automatic.evidence)). A session_id cannot identify its caller by itself."
            )
        }
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
                    + "(\(caller.evidence)). Call sessions.self to inspect the evidence; "
                    + "session_id is only a cross-check and cannot override it."
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
