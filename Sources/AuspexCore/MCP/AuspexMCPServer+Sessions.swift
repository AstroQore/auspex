import AgentSessionKit
import AgentSessionLive
import Foundation

extension AuspexMCPServer {
    func sessionsSelf(_ arguments: MCPArguments) async throws -> MCPJSON {
        let caller = try await caller(arguments)
        let board = await host.boardSnapshot()
        let ledger = await host.ledger()
        let notices = (try? ledger?.liveNotices()) ?? [:]
        let reports = (try? ledger?.allReports()) ?? [:]

        guard let key = caller.session, let session = board.session(for: key) else {
            return Self.success(SelfPayload(
                resolved: false,
                session: nil,
                evidence: caller.evidence,
                clientPID: caller.pid,
                tasks: []
            ))
        }
        let tasks = (try? ledger?.tasks(linkedTo: key)) ?? []
        return Self.success(SelfPayload(
            resolved: true,
            session: SessionPayload(
                session,
                project: board.projectKey(for: session).map(BoardGrouping.projectName(forPath:)),
                notice: notices[key],
                report: reports[key]
            ),
            // The key, not the name: this is the answer an agent passes back as
            // `project` on tasks.create, and a name is the one spelling of a
            // project that two of them can share.
            projectKey: board.projectKey(for: session),
            evidence: caller.evidence,
            clientPID: caller.pid,
            tasks: tasks.map {
                TaskPayload(
                    $0,
                    projectName: $0.projectKey.map {
                        TaskProject.displayName(forKey: $0, in: board)
                    }
                )
            }
        ))
    }

    func sessionsList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let board = await host.boardSnapshot()
        let harnesses = try arguments.optionalEnumList("harness", Harness.self) ?? []
        let activeOnly = try arguments.optionalBool("active_only") ?? true
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 50
        let ledger = await host.ledger()
        let notices = (try? ledger?.liveNotices()) ?? [:]
        let reports = (try? ledger?.allReports()) ?? [:]
        let links = (try? ledger?.allLinks()) ?? []
        let taskIDsBySession = Dictionary(grouping: links, by: \.session)
            .mapValues { $0.map(\.taskID) }

        var sessions = board.sessions
        if !harnesses.isEmpty {
            let wanted = Set(harnesses)
            sessions = sessions.filter { wanted.contains($0.key.harness) }
        }
        let calling = try await caller(arguments)
        let selected: String
        if try arguments.optionalString("project") != nil {
            selected = try await projectKey(arguments, caller: calling)
        } else if let key = calling.session,
                  let session = board.session(for: key),
                  let project = board.projectKey(for: session) {
            selected = project
        } else {
            throw MCPToolFailure(
                "Auspex cannot infer your project from this connection. Pass an explicit "
                    + "project from overview.get; sessions.list never defaults to every project."
            )
        }
        sessions = sessions.filter { board.projectKey(for: $0) == selected }
        if activeOnly { sessions = sessions.filter { !$0.state.isEnded } }
        let total = sessions.count
        return Self.success(SessionListPayload(
            sessions: sessions.prefix(limit).map { session in
                SessionCapsulePayload(
                    session, board: board, notice: notices[session.key],
                    report: reports[session.key],
                    linkedTaskIDs: taskIDsBySession[session.key] ?? []
                )
            },
            total: total
        ))
    }

    func sessionsGet(_ arguments: MCPArguments) async throws -> MCPJSON {
        let raw = try arguments.requiredString("session_key")
        guard let key = SessionKey(string: raw) else {
            throw MCPToolFailure("'\(raw)' is not a '<harness>:<session id>' key.")
        }
        let board = await host.boardSnapshot()
        guard let session = board.session(for: key) else {
            throw MCPToolFailure("No session on the board is '\(raw)'.")
        }

        let ledger = await host.ledger()
        let notices = (try? ledger?.liveNotices()) ?? [:]
        let reports = (try? ledger?.allReports()) ?? [:]
        let linkedRows = (try? ledger?.tasks(linkedTo: key)) ?? []
        var seenTaskIDs: Set<Int64> = []
        let linkedTasks = linkedRows.filter { seenTaskIDs.insert($0.id).inserted }
        let taskIDs = linkedTasks.map(\.id)
        return Self.success(SessionDetailPayload(
            session: SessionCapsulePayload(
                session, board: board, notice: notices[key], report: reports[key],
                linkedTaskIDs: taskIDs
            ),
            tasks: linkedTasks.map { TaskSummaryPayload($0) }
        ))
    }

    func sessionsTree(_ arguments: MCPArguments) async throws -> MCPJSON {
        let board = await host.boardSnapshot()
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 50
        var index: [SessionKey: SessionSnapshot] = [:]
        for session in board.sessions { index[session.key] = session }

        func payload(_ node: SessionTree.Node) -> TreeNodePayload {
            let session = index[node.key]
            return TreeNodePayload(
                key: node.key.description,
                harness: node.key.harness.rawValue,
                title: session?.identity.title,
                state: session?.state.columnValue ?? "unknown",
                children: node.children.map(payload)
            )
        }

        if let raw = try arguments.optionalString("session_key") {
            guard let key = SessionKey(string: raw), let node = board.tree.node(for: key) else {
                throw MCPToolFailure("No session on the board is '\(raw)'.")
            }
            return Self.success(TreePayload(roots: [payload(node)], sessionCount: board.tree.count))
        }
        return Self.success(TreePayload(
            roots: board.tree.roots.prefix(limit).map(payload),
            sessionCount: board.tree.count
        ))
    }

    func peersStatus(_ arguments: MCPArguments) async throws -> MCPJSON {
        _ = arguments
        let board = await host.boardSnapshot()
        let notices = (try? await host.ledger()?.liveNotices()) ?? [:]
        let counts = board.counts
        let onBoard = Set(board.sessions.map(\.key))
        let callers = notices.values
            .filter { $0.kind.wantsPerson && onBoard.contains($0.session) }
            .sorted { $0.createdAt > $1.createdAt }
        // A session that a harness reports as blocked *and* that called
        // `notify` is one session needing one person, not two.
        let alreadyBlocked = Set(
            board.sessions.filter { if case .waitingPermission = $0.state { true } else { false } }
                .map(\.key)
        )
        let extra = callers.count { !alreadyBlocked.contains($0.session) }
        return Self.success(PeersPayload(
            working: counts.thinking + counts.tooling + counts.delegating,
            idle: counts.idle,
            ended: counts.ended,
            needsYou: counts.waitingPermission + extra,
            calling: callers.map {
                PeersPayload.Caller(
                    session: $0.session.description,
                    kind: $0.kind.rawValue,
                    message: $0.message,
                    at: $0.createdAt
                )
            },
            total: board.sessions.count
        ))
    }
}
