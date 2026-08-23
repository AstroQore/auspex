import AgentSessionKit
import AgentSessionLive
import Foundation

extension AuspexMCPServer {
    private static let overviewSectionLimit = 20

    func overviewGet(_ arguments: MCPArguments) async throws -> MCPJSON {
        let board = await host.boardSnapshot()
        let caller = try await caller(arguments)
        let project: String
        if try arguments.optionalString("project") != nil {
            project = try await projectKey(arguments, caller: caller)
        } else {
            guard let session = caller.session, board.session(for: session) != nil else {
                throw MCPToolFailure(
                    "Auspex cannot choose a current project because this connection is not "
                        + "attributed to a session (\(caller.evidence)). Pass 'project'."
                )
            }
            project = TaskProject.resolve(explicit: nil, session: session, board: board)
            // `resolve` normally returns the board's project key; it also gives
            // a pseudo project to a session whose directory has not arrived.
        }

        let ledger = try await requireLedger()
        let projectTasks = try ledger.tasks(projectKey: project, limit: Self.ledgerReadLimit)
        let allTasks = try ledger.tasks(limit: Self.ledgerReadLimit)
        let known = Set(allTasks.map(\.id))
        let closed = Set(allTasks.filter { $0.status == .done }.map(\.id))
        func blockers(_ task: AuspexTask) -> [Int64] {
            task.blockingDependencies(closed: closed, known: known)
        }
        func summary(_ task: AuspexTask) -> TaskSummaryPayload {
            TaskSummaryPayload(task, waitingOn: blockers(task))
        }

        let links = try ledger.allLinks()
        let taskIDsBySession = Dictionary(grouping: links, by: \.session)
            .mapValues { $0.map(\.taskID) }
        let notices = try ledger.liveNotices()
        let reports = try ledger.allReports()
        let sessions = board.sessions.filter { board.projectKey(for: $0) == project }
        let sessionByKey = Dictionary(uniqueKeysWithValues: board.sessions.map { ($0.key, $0) })

        let doingTasks = projectTasks.filter { $0.status == .doing }
        let blockedTasks = projectTasks.filter { $0.status == .blocked }
        let reviewTasks = projectTasks.filter { $0.status == .review }
        let readyTasks = projectTasks.filter {
            $0.status == .todo && !$0.isClaimed && $0.isReady(closed: closed, known: known)
        }
        let orphanedTasks = projectTasks.filter { task in
            guard task.status.isOpen, task.status != .review, let holder = task.claimedBy else {
                return false
            }
            guard let session = sessionByKey[holder] else { return true }
            return session.state.isEnded
        }
        let doing = doingTasks.prefix(Self.overviewSectionLimit).map(summary)
        let blocked = blockedTasks.prefix(Self.overviewSectionLimit).map(summary)
        let review = reviewTasks.prefix(Self.overviewSectionLimit).map(summary)
        let ready = readyTasks.prefix(Self.overviewSectionLimit).map(summary)
        let orphaned = orphanedTasks.prefix(Self.overviewSectionLimit).map(summary)

        let allNeedsYou = sessions.compactMap { session -> SessionCapsulePayload? in
            let attention = TaskLedger.attention(
                of: session, notice: notices[session.key], acknowledgedAt: nil,
                now: board.generatedAt
            )
            guard case .needsYou = attention else { return nil }
            return SessionCapsulePayload(
                session, board: board, notice: notices[session.key], report: reports[session.key],
                linkedTaskIDs: taskIDsBySession[session.key] ?? []
            )
        }
        let needsYou = Array(allNeedsYou.prefix(Self.overviewSectionLimit))

        let selfCapsule: SessionCapsulePayload?
        if let key = caller.session, let session = board.session(for: key),
           board.projectKey(for: session) == project {
            selfCapsule = SessionCapsulePayload(
                session, board: board, notice: notices[key], report: reports[key],
                linkedTaskIDs: taskIDsBySession[key] ?? []
            )
        } else {
            selfCapsule = nil
        }

        return Self.success(OverviewPayload(
            project: .init(
                key: project, name: TaskProject.displayName(forKey: project, in: board)
            ),
            generatedAt: board.generatedAt,
            perSectionLimit: Self.overviewSectionLimit,
            self: selfCapsule,
            doing: doing,
            blocked: blocked,
            review: review,
            ready: ready,
            orphanedClaims: orphaned,
            needsYou: needsYou,
            counts: .init(
                sessions: sessions.count, tasks: projectTasks.count, doing: doingTasks.count,
                blocked: blockedTasks.count, review: reviewTasks.count, ready: readyTasks.count,
                orphanedClaims: orphanedTasks.count, needsYou: allNeedsYou.count
            )
        ))
    }
}
