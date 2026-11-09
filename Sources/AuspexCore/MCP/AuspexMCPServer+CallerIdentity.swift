import AgentSessionKit
import AgentSessionLive
import Foundation

extension AuspexMCPServer {
    enum RequestScope {
        @TaskLocal static var attribution: MCPTransportAttribution = .absent
        /// The tool this request is calling, for corroborating a caller by
        /// what its own transcript records; `nil` outside `tools/call`.
        @TaskLocal static var tool: String?
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
        var automatic: Caller
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
            // The process tree stopped at a harness that could not say which
            // of its sessions is calling. The sessions can: the one whose
            // transcript records this very call is the caller.
            if let pid = candidatePID, let harness = attempt?.harness,
               let corroborated = await transcriptCorroboration(harness: harness, board: board, table: table) {
                switch corroborated {
                case .session(let key, let evidence):
                    automatic = Caller(
                        session: key,
                        pid: pid,
                        evidence: evidence + "; " + (attributionEvidence ?? "socket peer")
                    )
                case .ambiguous(let reason):
                    automatic = Caller(session: nil, pid: pid, evidence: automatic.evidence + "; " + reason)
                }
            }
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

    // MARK: - Corroboration by the caller's own transcript

    /// What the transcripts said about who is calling.
    enum TranscriptCorroboration: Equatable {
        case session(SessionKey, evidence: String)
        case ambiguous(String)
    }

    /// How recently a transcript must record the call for it to be this one.
    /// Generous, because a harness flushes its log on its own schedule and a
    /// tailer picks the line up on Auspex's; strict enough that yesterday's
    /// `auspex.notify` cannot vouch for today's.
    static let transcriptWindow: TimeInterval = 180

    /// Finds the session whose transcript records the call being answered.
    ///
    /// The case this exists for is a desktop app's Codex: one `codex app-server`
    /// hosts every thread the app has open, each thread gets its own Auspex
    /// bridge, and neither the bridge's environment nor the board's pid column
    /// says which thread spawned which. The pid walk stops there, honestly
    /// ambiguous — and before this, every `auspex.notify` from those threads
    /// was refused, so agents wrote "Auspex could not identify this session"
    /// instead of posting the notification.
    ///
    /// But Auspex is already reading those threads' transcripts, and a tool
    /// call is recorded there as the model emits it, before the harness runs
    /// it. So among the harness's own live sessions — those not demonstrably
    /// living in some other process — the one with an open call to this tool,
    /// started within ``transcriptWindow``, is the caller. Two of them calling
    /// the same tool at once stays ambiguous: the answer is never a guess.
    ///
    /// The transcript may lag the socket by a moment. When nothing matches
    /// under a multi-session harness, the board is re-read for up to
    /// `transcriptPatience` before giving up; only on that path, so a call
    /// the pid walk already settled costs nothing here.
    func transcriptCorroboration(
        harness: HarnessProcess,
        board: BoardSnapshot,
        table: any ProcessTableReading
    ) async -> TranscriptCorroboration? {
        guard let tool = RequestScope.tool else { return nil }
        var board = board
        let deadline = Date().addingTimeInterval(transcriptPatience)
        while true {
            let matches = Self.sessionsRecordingCall(
                to: tool, harness: harness, board: board, table: table, now: now()
            )
            if matches.count == 1 {
                let key = matches[0]
                return .session(key, evidence: "the transcript of \(key.description) records this "
                    + "\(tool) call, and it is the only live \(harness.executable) session that does")
            }
            if matches.count > 1 {
                return .ambiguous("\(matches.count) live \(harness.executable) sessions record a \(tool) "
                    + "call right now, so none of them can be told to be this one")
            }
            guard harness.isMultiSession, Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(250))
            board = await host.boardSnapshot()
        }
    }

    /// The live sessions of `harness` whose open tool calls include one to
    /// `tool`, as the harness spells it: the MCP name (`auspex.notify`), the
    /// underscored name a client registers (`auspex_notify`), or a code-mode
    /// snippet that calls `tools.mcp__auspex__auspex_notify(...)`.
    static func sessionsRecordingCall(
        to tool: String,
        harness: HarnessProcess,
        board: BoardSnapshot,
        table: any ProcessTableReading,
        now: Date
    ) -> [SessionKey] {
        let underscored = tool.replacingOccurrences(of: ".", with: "_")
        let since = now.addingTimeInterval(-transcriptWindow)
        return board.sessions.compactMap { session -> SessionKey? in
            guard session.isAlive, !session.state.isEnded,
                  harness.harnesses.contains(session.key.harness)
            else { return nil }
            if let recorded = session.identity.pid, recorded != harness.pid,
               table.record(pid: recorded) != nil {
                return nil
            }
            let records = session.pending.openToolCalls.values.contains { call in
                guard call.startedAt >= since else { return false }
                let text = call.name + " " + (call.target ?? "")
                return text.contains("auspex") && (text.contains(tool) || text.contains(underscored))
            }
            return records ? session.key : nil
        }
        .sorted { $0.description < $1.description }
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
