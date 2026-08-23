import AgentSessionKit
import AgentSessionLive
import Foundation

/// Auspex's MCP server: the dispatch layer over the kit's transport.
///
/// The kit owns the bytes — `MCPSocketServer` reframes a Unix socket into
/// newline-delimited JSON-RPC lines, `MCPStdioBridge` pumps a spawned process's
/// stdio into that socket — and knows nothing about tools. This is the half
/// that knows what the lines mean, and it is the only half Auspex writes.
///
/// An actor because two things mutate here from different places: the map of
/// pids a bridge declared for itself, and the per-connection bookkeeping that
/// stands in for a connection label. Neither is hot — a handful of messages per
/// agent per minute — so a serial actor is the right shape rather than a lock.
///
/// ## What it will not do
///
/// - **Never executes anything from an argument.** Nothing here builds a
///   command, opens a path an agent named, or interpolates input into SQL: the
///   repository binds every value.
/// - **Never writes in demo mode.** A demo Auspex answers reads out of its
///   fabricated board and refuses the ten writing tools by name.
/// - **Never trusts a length.** Every agent-authored string goes through
///   ``MCPTextSanitizer`` before it reaches the store or the screen.
public actor AuspexMCPServer {
    private let host: any AuspexMCPHost
    private let resolver: MCPSelfResolver
    private let now: @Sendable () -> Date

    /// The pids bridges have declared for themselves in `auspex/hello`,
    /// newest last.
    ///
    /// A fallback, not the primary answer: the socket's own `LOCAL_PEERPID` is
    /// what identifies a client, and this only matters when the kernel would
    /// not give one. Bounded, because a long-lived Auspex sees a bridge per
    /// agent invocation and this must not become a pid log.
    private var declaredPIDs: [pid_t] = []
    private static let declaredPIDLimit = 32

    /// Turns harness hook payloads into board events, and remembers which
    /// sessions are blocked on a permission so the resolution can close the one
    /// that was opened.
    private var hooks = HookEventRouter()

    public init(
        host: any AuspexMCPHost,
        resolver: MCPSelfResolver = MCPSelfResolver(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.host = host
        self.resolver = resolver
        self.now = now
    }

    // MARK: - JSON-RPC

    /// Answers one framed line. `nil` for a notification.
    public func answer(line: Data) async -> Data? {
        let request: MCPRequest
        do {
            request = try MCPRequest.decode(line: line)
        } catch let error as MCPRPCError {
            // A line that could not be parsed has no id to answer under, but a
            // client that gets nothing back waits forever.
            return MCPResponse(id: .null, error: error).framed()
        } catch {
            return MCPResponse(id: .null, error: .parseError()).framed()
        }

        if request.isNotification {
            await handleNotification(request)
            return nil
        }
        guard let id = request.id else { return nil }

        do {
            return MCPResponse(id: id, result: try await result(for: request)).framed()
        } catch let error as MCPRPCError {
            return MCPResponse(id: id, error: error).framed()
        } catch {
            return MCPResponse(id: id, error: .internalError("\(error)")).framed()
        }
    }

    /// Notifications: `notifications/initialized`, Auspex's own hello, and the
    /// hook ingress.
    private func handleNotification(_ request: MCPRequest) async {
        switch request.method {
        case "auspex/hello":
            guard let pid = request.params?["pid"]?.intValue, pid > 0, pid < Int(Int32.max) else {
                return
            }
            let declared = pid_t(pid)
            declaredPIDs.removeAll { $0 == declared }
            declaredPIDs.append(declared)
            if declaredPIDs.count > Self.declaredPIDLimit {
                declaredPIDs.removeFirst(declaredPIDs.count - Self.declaredPIDLimit)
            }
        case HookEvent.method:
            await handleHook(request.params)
        default:
            return
        }
    }

    /// One hook invocation, from the short-lived `Auspex --hook` process.
    ///
    /// A notification rather than a request, and answered with silence: the
    /// hook process has a 200-millisecond budget and a harness waiting on it,
    /// so it writes its line and goes. Nothing it could be told would be worth
    /// the round trip.
    ///
    /// Session resolution is the payload's own id first — Claude Code's is the
    /// name of its transcript, so a key built from it is the key the tailer
    /// builds — and the process the hook ran in otherwise. The hook is a direct
    /// child of the harness, so its parent pid is the strongest evidence
    /// anything in Auspex gets.
    ///
    /// Not refused in demo mode, unlike the writing tools. A hook event touches
    /// no store and no file; it moves a card. And a demo binds no socket unless
    /// one was named explicitly, so a hook can only reach a fabricated board
    /// that somebody deliberately pointed at it — which is how this is
    /// demonstrated.
    private func handleHook(_ params: MCPJSON?) async {
        guard let hook = HookEvent(params: params) else { return }
        let board = await host.boardSnapshot()
        let fallback = resolver.resolve(
            pid: hook.pid,
            identities: board.sessions.map(\.identity),
            table: await host.processTable()
        )?.session
        let events = hooks.events(
            for: hook,
            known: Set(board.sessions.map(\.key)),
            fallback: fallback
        )
        guard !events.isEmpty else { return }
        await host.didObserve(events)
    }

    private func result(for request: MCPRequest) async throws -> MCPJSON {
        switch request.method {
        case "initialize":
            return initializeResult()
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(AuspexMCPTools.all.map(\.json))])
        case "tools/call":
            return try await callResult(request.params)
        case "resources/list", "resources/templates/list", "prompts/list":
            // Answered rather than refused: a client that walks every capability
            // on connect should get an empty list, not an error it reports as a
            // broken server.
            return .object([
                "resources": .array([]), "resourceTemplates": .array([]), "prompts": .array([])
            ])
        default:
            throw MCPRPCError.methodNotFound(request.method)
        }
    }

    private func initializeResult() -> MCPJSON {
        .object([
            "protocolVersion": .string(AuspexMCPTools.protocolVersion),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(AuspexMCPTools.serverName),
                "title": .string("Auspex"),
                "version": .string(AuspexVersion.marketingVersion)
            ]),
            "instructions": .string(Self.instructions)
        ])
    }

    /// What a client shows the model before it has called anything.
    ///
    /// The same invariants as the installed short note, for a harness that
    /// reads server instructions and one whose config Auspex never touches.
    /// The versioned skill carries the detailed role playbooks.
    static let instructions = """
        Auspex passively watches every AI agent session on this Mac; MCP adds \
        explicit coordination. Read overview.get when you join work already in \
        flight; it gives the current project's tasks, peers, blockers, review, \
        and ready work without exposing transcripts. When a brief names an \
        Auspex task id, load the auspex-coordination skill and follow its role \
        playbook, using this server's capabilities as truth. Call auspex.notify \
        the moment you need the person instead of going quiet; release a task \
        with a reason when you stop, and finish into Review rather than closing \
        your own work. With no task id, keep the implicit session task instead \
        of creating one merely for the protocol. If MCP or session identity is \
        unavailable, continue the user's work and report which updates were not \
        recorded.
        """

    // MARK: - tools/call

    private func callResult(_ params: MCPJSON?) async throws -> MCPJSON {
        guard let name = params?["name"]?.stringValue else {
            throw MCPRPCError.invalidParams("'name' is required.")
        }
        guard let tool = AuspexMCPTools.tool(named: name) else {
            throw MCPRPCError.invalidParams(
                "Unknown tool '\(name)'. Call tools/list for what this server answers."
            )
        }
        let arguments = try MCPArguments(tool: tool, raw: params?["arguments"])

        if AuspexMCPTools.writingTools.contains(name), await host.isReadOnly {
            return Self.failure(TaskLedgerError.readOnly.description)
        }

        do {
            return try await run(tool: name, arguments: arguments)
        } catch let failure as MCPToolFailure {
            // A tool that ran and could not answer reports through `isError`,
            // which is what an MCP client shows the model. A JSON-RPC error
            // would be swallowed by the client as a transport fault.
            return Self.failure(failure.message)
        } catch let failure as TaskLedgerError {
            return Self.failure(failure.description)
        }
    }

    private func run(tool name: String, arguments: MCPArguments) async throws -> MCPJSON {
        switch name {
        case AuspexMCPTools.Name.notify:        return try await notify(arguments)
        case AuspexMCPTools.Name.report:        return try await report(arguments)
        case AuspexMCPTools.Name.overviewGet:   return try await overviewGet(arguments)
        case AuspexMCPTools.Name.plansList:     return try await plansList(arguments)
        case AuspexMCPTools.Name.plansGet:      return try await plansGet(arguments)
        case AuspexMCPTools.Name.plansCreate:   return try await plansCreate(arguments)
        case AuspexMCPTools.Name.plansArchive:  return try await plansArchive(arguments)
        case AuspexMCPTools.Name.tasksList:     return try await tasksList(arguments)
        case AuspexMCPTools.Name.tasksGet:      return try await tasksGet(arguments)
        case AuspexMCPTools.Name.tasksCreate:   return try await tasksCreate(arguments)
        case AuspexMCPTools.Name.tasksClaim:    return try await tasksClaim(arguments)
        case AuspexMCPTools.Name.tasksRelease:  return try await tasksRelease(arguments)
        case AuspexMCPTools.Name.tasksUpdate:   return try await tasksUpdate(arguments)
        case AuspexMCPTools.Name.tasksComplete: return try await tasksComplete(arguments)
        case AuspexMCPTools.Name.tasksLog:      return try await tasksLog(arguments)
        case AuspexMCPTools.Name.sessionsSelf:  return try await sessionsSelf(arguments)
        case AuspexMCPTools.Name.sessionsList:  return try await sessionsList(arguments)
        case AuspexMCPTools.Name.sessionsGet:   return try await sessionsGet(arguments)
        case AuspexMCPTools.Name.sessionsTree:  return try await sessionsTree(arguments)
        case AuspexMCPTools.Name.peersStatus:   return try await peersStatus(arguments)
        default: throw MCPRPCError.methodNotFound(name)
        }
    }

    // MARK: - Project briefing

    private func overviewGet(_ arguments: MCPArguments) async throws -> MCPJSON {
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

    // MARK: - The two that matter most

    private func notify(_ arguments: MCPArguments) async throws -> MCPJSON {
        let kind = try arguments.requiredEnum("kind", AgentNoticeKind.self)
        let message = try MCPTextSanitizer.require(
            try arguments.requiredString("message"),
            field: "message",
            tool: AuspexMCPTools.Name.notify
        )
        let urgency = try arguments.optionalEnum("urgency", AgentNoticeUrgency.self) ?? .normal
        let caller = try await requireAttributedCaller(arguments, action: "call the person")
        let ledger = try await requireLedger()
        let session = caller.session!

        let notice = try ledger.recordNotice(
            session: session, kind: kind, message: message, urgency: urgency, now: now()
        )
        await host.didRecordNotice(notice)

        // Saying "done" and finishing your task are the same gesture, and an
        // agent that has to make it twice makes it once. So a `done` notice
        // moves whatever this session was holding into review, carrying the
        // sentence it just wrote — which is exactly what `tasks.complete`
        // does, reached from the other side.
        var reviewed: [Int64] = []
        if kind == .done {
            for task in (try? ledger.tasks(linkedTo: session)) ?? []
            where task.claimedBy == session && task.status != .done && task.status != .review {
                guard let moved = try? ledger.completeTask(
                    id: task.id, result: message, by: session, now: now()
                ) else { continue }
                reviewed.append(moved.id)
            }
            if !reviewed.isEmpty { await host.didChangeLedger() }
        }

        return Self.success(NotifyPayload(
            session: session.description,
            kind: kind.rawValue,
            message: message,
            urgency: urgency.rawValue,
            at: notice.createdAt,
            bucket: kind.wantsPerson ? "needs you" : "review",
            reviewing: reviewed.isEmpty ? nil : reviewed,
            resolved: true,
            evidence: caller.evidence,
            clearsWhen: "the person opens or dismisses the card, talks to this session "
                + "again, or a day goes by"
        ))
    }

    private func report(_ arguments: MCPArguments) async throws -> MCPJSON {
        let focus = try MCPTextSanitizer.require(
            try arguments.requiredString("focus"),
            field: "focus",
            tool: AuspexMCPTools.Name.report
        )
        let progress = MCPTextSanitizer.clean(
            try arguments.optionalString("progress"), limit: MCPTextSanitizer.labelLimit
        )
        let caller = try await requireAttributedCaller(arguments, action: "file a report")
        let ledger = try await requireLedger()
        let session = caller.session!
        let report = try ledger.recordReport(
            session: session, focus: focus, progress: progress, now: now()
        )
        await host.didRecordReport(report)
        return Self.success(ReportPayload(
            session: session.description,
            focus: focus,
            progress: progress,
            at: report.createdAt,
            resolved: true
        ))
    }

    // MARK: - Plans

    private func plansList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let includeArchived = try arguments.optionalBool("include_archived") ?? false
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 50
        let plans = try ledger.plans(includingArchived: includeArchived, limit: limit)
        let tasks = try ledger.tasks(limit: 1_000)
        let byPlan = Dictionary(grouping: tasks) { $0.planID }
        let board = await host.boardSnapshot()
        return Self.success(PlanListPayload(
            plans: plans.map {
                PlanPayload(
                    $0,
                    tasks: byPlan[$0.id] ?? [],
                    projectName: $0.projectKey.map {
                        TaskProject.displayName(forKey: $0, in: board)
                    }
                )
            },
            note: plans.isEmpty
                ? "No milestone is registered. Tasks do not need one — they are filed in a project — so register one only if you are handing out work that wants a heading."
                : nil
        ))
    }

    private func plansGet(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let reference = try arguments.requiredString("plan")
        guard let plan = try ledger.plan(reference: reference) else {
            throw MCPToolFailure("No milestone is registered as '\(reference)'.")
        }
        let tasks = try ledger.tasks(planID: plan.id)
        let links = try ledger.allLinks()
        let bySession = Dictionary(grouping: links) { $0.taskID }
        let board = await host.boardSnapshot()
        return Self.success(PlanDetailPayload(
            plan: PlanPayload(
                plan,
                tasks: tasks,
                projectName: plan.projectKey.map { TaskProject.displayName(forKey: $0, in: board) }
            ),
            tasks: tasks.map {
                TaskPayload(
                    $0,
                    sessions: (bySession[$0.id] ?? []).map(\.session),
                    projectName: $0.projectKey.map { TaskProject.displayName(forKey: $0, in: board) }
                )
            }
        ))
    }

    private func plansCreate(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let title = try MCPTextSanitizer.require(
            try arguments.requiredString("title"),
            limit: 200, field: "title", tool: AuspexMCPTools.Name.plansCreate
        )
        let slug = MCPTextSanitizer.clean(
            try arguments.optionalString("slug"), limit: MCPTextSanitizer.labelLimit
        )
        let summary = MCPTextSanitizer.clean(try arguments.optionalString("summary"))
        let caller = try await caller(arguments)
        let project = try await projectKey(arguments, caller: caller)
        let plan = try ledger.createPlan(
            title: title, slug: slug, summary: summary, projectKey: project,
            createdBy: caller.session, now: now()
        )
        await host.didChangeLedger()
        return Self.success(PlanPayload(
            plan,
            tasks: try ledger.tasks(planID: plan.id),
            projectName: await projectName(plan.projectKey)
        ))
    }

    private func plansArchive(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        _ = try await requireAttributedCaller(arguments, action: "archive a milestone")
        let reference = try arguments.requiredString("plan")
        guard let plan = try ledger.plan(reference: reference) else {
            throw MCPToolFailure("No milestone is registered as '\(reference)'.")
        }
        guard let archived = try ledger.archivePlan(id: plan.id, now: now()) else {
            throw MCPToolFailure("The milestone could not be archived.")
        }
        await host.didChangeLedger()
        return Self.success(PlanPayload(archived, projectName: await projectName(archived.projectKey)))
    }

    // MARK: - Tasks

    private func tasksList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 100
        let statuses = try arguments.optionalEnumList("status", AuspexTaskStatus.self) ?? []
        var planID: Int64?
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No milestone is registered as '\(reference)'.")
            }
            planID = plan.id
        }
        var claimedBy: SessionKey?
        if try arguments.optionalBool("mine") == true {
            let caller = try await caller(arguments)
            guard let session = caller.session else {
                throw MCPToolFailure(
                    "'mine' needs Auspex to know which session you are (\(caller.evidence))."
                )
            }
            claimedBy = session
        }
        // Only when it was asked for. A bare `tasks.list` is "what is on the
        // whole board", and narrowing it to the caller's own project by
        // default would hide the work next door that a supervisor called this
        // to find.
        var projectKey: String?
        if try arguments.optionalString("project") != nil {
            projectKey = try await self.projectKey(arguments, caller: try await caller(arguments))
        }
        let readyOnly = try arguments.optionalBool("ready_only") ?? false
        let label = MCPTextSanitizer.clean(
            try arguments.optionalString("label"), limit: TaskLabels.lengthLimit
        )?.lowercased()
        var tasks = try ledger.tasks(
            planID: planID, projectKey: projectKey, statuses: statuses,
            claimedBy: claimedBy, readyOnly: readyOnly, limit: limit
        )
        if let label { tasks = tasks.filter { $0.labels.contains(label) } }
        let links = Dictionary(grouping: try ledger.allLinks()) { $0.taskID }
        let board = await host.boardSnapshot()
        return Self.success(TaskListPayload(
            tasks: tasks.map {
                TaskPayload(
                    $0,
                    sessions: (links[$0.id] ?? []).map(\.session),
                    projectName: $0.projectKey.map { TaskProject.displayName(forKey: $0, in: board) }
                )
            },
            note: tasks.isEmpty
                ? (readyOnly
                    ? "Nothing here is ready: every task is either finished or waiting on one that is not. Call again without ready_only to see what is blocked."
                    : "Nothing is filed here. If your brief named a task id it may be under an archived milestone, or in another project; otherwise file one with tasks.create.")
                : nil
        ))
    }

    private func tasksGet(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        guard let task = try ledger.task(id: id) else {
            throw TaskLedgerError.notFound("task \(id)")
        }

        let allTasks = try ledger.tasks(limit: Self.ledgerReadLimit)
        let byID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        let known = Set(byID.keys)
        let closed = Set(allTasks.filter { $0.status == .done }.map(\.id))
        let blocking = task.blockingDependencies(closed: closed, known: known)
        let dependencies = task.dependsOn.map { dependency -> TaskDetailPayload.Dependency in
            let row = byID[dependency]
            return TaskDetailPayload.Dependency(
                id: dependency,
                shortID: row?.shortID,
                title: row?.title,
                status: row?.status.rawValue,
                satisfied: row == nil || row?.status == .done
            )
        }

        let board = await host.boardSnapshot()
        let notices = try ledger.liveNotices()
        let reports = try ledger.allReports()
        let allLinks = try ledger.allLinks()
        let taskIDsBySession = Dictionary(grouping: allLinks, by: \.session)
            .mapValues { $0.map(\.taskID) }
        let taskLinks = try ledger.links(taskID: id)
        let linksBySession = Dictionary(grouping: taskLinks, by: \.session)
        let linked = linksBySession.keys.sorted { $0.description < $1.description }.map { key in
            let sessionLinks = linksBySession[key] ?? []
            let snapshot = board.session(for: key)
            return TaskDetailPayload.LinkedSession(
                key: key.description,
                linkKinds: sessionLinks.map { $0.kind.rawValue },
                linkedAt: sessionLinks.map(\.createdAt).min() ?? task.updatedAt,
                availability: snapshot == nil ? "not_on_board" : "on_board",
                session: snapshot.map {
                    SessionCapsulePayload(
                        $0, board: board, notice: notices[key],
                        report: reports[key],
                        linkedTaskIDs: taskIDsBySession[key] ?? []
                    )
                }
            )
        }

        return Self.success(TaskDetailPayload(
            task: TaskPayload(
                task,
                sessions: linksBySession.keys.sorted { $0.description < $1.description },
                projectName: task.projectKey.map {
                    TaskProject.displayName(forKey: $0, in: board)
                }
            ),
            readiness: .init(
                ready: blocking.isEmpty,
                dependencies: dependencies,
                blocking: blocking
            ),
            history: try ledger.log(taskID: id, limit: 20).map(TaskLogPayload.Entry.init),
            sessions: linked
        ))
    }

    private func tasksCreate(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let title = try MCPTextSanitizer.require(
            try arguments.requiredString("title"),
            limit: 200, field: "title", tool: AuspexMCPTools.Name.tasksCreate
        )
        // A body is the one field a brief legitimately fills with paragraphs,
        // so it gets a larger cap than a message — and still a cap.
        let body = MCPTextSanitizer.clean(try arguments.optionalString("body"), limit: 4_000)
        let status = try arguments.optionalEnum("status", AuspexTaskStatus.self) ?? .todo
        let priority = try Self.priority(arguments) ?? 0
        let kind = try Self.kind(arguments) ?? nil
        let labels = try Self.labels(arguments) ?? []
        let dependsOn = try Self.dependsOn(arguments) ?? []
        var planID: Int64?
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No milestone is registered as '\(reference)'.")
            }
            planID = plan.id
        }
        let caller = try await caller(arguments)
        let project = try await projectKey(arguments, caller: caller)
        let task = try ledger.createTask(
            title: title, body: body, planID: planID, status: status, priority: priority,
            projectKey: project, createdBy: caller.session, source: "mcp",
            kind: kind, labels: labels, dependsOn: dependsOn, now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(task, projectName: await projectName(task.projectKey)))
    }

    private func tasksClaim(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let role = try MCPTextSanitizer.require(
            try arguments.requiredString("role"),
            limit: MCPTextSanitizer.labelLimit,
            field: "role", tool: AuspexMCPTools.Name.tasksClaim
        )
        let scope = MCPTextSanitizer.clean(try arguments.optionalString("scope"))
        let caller = try await requireAttributedCaller(arguments, action: "claim a task")
        let session = caller.session!
        // The claimer's own project, applied only if the task has none — a task
        // inherits its project from whoever first takes it.
        let board = await host.boardSnapshot()
        let task = try ledger.claimTask(
            id: id, role: role, scope: scope, by: session,
            projectKey: TaskProject.resolve(explicit: nil, session: session, board: board),
            now: now()
        )
        await host.didChangeLedger()
        let sessions = try ledger.links(taskID: id).map(\.session)
        return Self.success(TaskPayload(
            task,
            sessions: sessions,
            projectName: task.projectKey.map { TaskProject.displayName(forKey: $0, in: board) }
        ))
    }

    private func tasksRelease(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let reason = try MCPTextSanitizer.require(
            try arguments.requiredString("reason"),
            field: "reason", tool: AuspexMCPTools.Name.tasksRelease
        )
        let caller = try await requireAttributedCaller(
            arguments, action: "release a task"
        )
        let session = caller.session!
        let task = try ledger.releaseTask(
            id: id, by: session, reason: reason, requireHolder: true, now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(
            task,
            sessions: try ledger.links(taskID: id).map(\.session),
            projectName: await projectName(task.projectKey)
        ))
    }

    private func tasksUpdate(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let status = try arguments.optionalEnum("status", AuspexTaskStatus.self)
        let title = MCPTextSanitizer.clean(try arguments.optionalString("title"), limit: 200)
        let body = MCPTextSanitizer.clean(try arguments.optionalString("body"), limit: 4_000)
        let priority = try Self.priority(arguments)
        let kind = try Self.kind(arguments)
        let labels = try Self.labels(arguments)
        let dependsOn = try Self.dependsOn(arguments)
        var planID: Int64??
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No milestone is registered as '\(reference)'.")
            }
            planID = .some(plan.id)
        }
        let caller = try await requireAttributedCaller(arguments, action: "update a task")
        var task = try ledger.updateTask(
            id: id,
            title: title,
            body: body.map { Optional($0) },
            status: status,
            priority: priority,
            planID: planID,
            kind: kind,
            labels: labels,
            dependsOn: dependsOn,
            actor: caller.session,
            now: now()
        )
        // Re-filing is its own statement, because it writes a line into the
        // task's history: a task that changed project silently is a task
        // somebody will spend an afternoon looking for.
        if try arguments.optionalString("project") != nil {
            task = try ledger.moveTask(
                id: id,
                toProjectKey: try await projectKey(arguments, caller: caller),
                actor: caller.session,
                now: now()
            )
        }
        await host.didChangeLedger()
        return Self.success(TaskPayload(task, projectName: await projectName(task.projectKey)))
    }

    private func tasksComplete(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let result = MCPTextSanitizer.clean(try arguments.optionalString("result"))
        let caller = try await requireAttributedCaller(arguments, action: "finish a task")
        let task = try ledger.completeTask(
            id: id, result: result, by: caller.session, now: now()
        )
        // Finishing a task *is* reporting done, and a worker that has to say so
        // twice is a worker that says it once. The board's `done` bucket counts
        // explicit signals only, so the one an agent already made by completing
        // its task has to be one of them — otherwise the most disciplined
        // callers are the ones whose work disappears.
        if let session = caller.session {
            let notice = try ledger.recordNotice(
                session: session,
                kind: .done,
                message: result ?? "Finished: \(task.title)",
                now: now()
            )
            await host.didRecordNotice(notice)
        }
        await host.didChangeLedger()
        return Self.success(TaskPayload(task, projectName: await projectName(task.projectKey)))
    }

    private func tasksLog(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let message = try MCPTextSanitizer.require(
            try arguments.requiredString("message"),
            field: "message", tool: AuspexMCPTools.Name.tasksLog
        )
        let kind = try arguments.optionalEnum("kind", TaskNoteKind.self) ?? .note
        let ref = MCPTextSanitizer.clean(try arguments.optionalString("ref"), limit: 300)
        let caller = try await requireAttributedCaller(arguments, action: "write a task note")
        guard try ledger.task(id: id) != nil else {
            throw TaskLedgerError.notFound("task \(id)")
        }
        try ledger.appendLog(
            taskID: id, actor: caller.session, kind: kind.rawValue, message: message,
            ref: ref, now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskLogPayload(
            taskID: id,
            entries: try ledger.log(taskID: id, limit: 20).map(TaskLogPayload.Entry.init)
        ))
    }

    // MARK: - Reading the task-shaped arguments

    /// `priority` if given, else the number `importance` stands for.
    ///
    /// Both, and `priority` wins, because agents already installed on this
    /// machine pass it and an argument that quietly stopped working would be
    /// the worst kind of break — the caller carries on and the board is wrong.
    private static func priority(_ arguments: MCPArguments) throws -> Int? {
        if let priority = try arguments.optionalInt("priority", minimum: -100, maximum: 100) {
            return priority
        }
        return try arguments.optionalEnum("importance", TaskImportance.self)?.priority
    }

    /// A double optional: absent means "leave it alone", present-and-empty
    /// means "clear it". `tasks.update` needs to be able to say both.
    private static func kind(_ arguments: MCPArguments) throws -> TaskKind?? {
        guard let raw = try arguments.optionalString("kind") else { return nil }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .some(nil)
        }
        guard let kind = TaskKind(loose: raw) else {
            let known = TaskKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPToolFailure("'\(raw)' is not a task kind. One of: \(known).")
        }
        return .some(kind)
    }

    private static func labels(_ arguments: MCPArguments) throws -> [String]? {
        guard let raw = try arguments.optionalStringList("labels") else { return nil }
        return TaskLabels.normalize(raw.compactMap {
            MCPTextSanitizer.clean($0, limit: TaskLabels.lengthLimit)
        })
    }

    private static func dependsOn(_ arguments: MCPArguments) throws -> [Int64]? {
        guard let value = arguments.present("depends_on") else { return nil }
        guard let items = value.arrayValue else {
            throw MCPToolFailure("'depends_on' takes an array of task ids.")
        }
        return items.compactMap { $0.intValue.map(Int64.init) }
    }

    // MARK: - Sessions

    private func sessionsSelf(_ arguments: MCPArguments) async throws -> MCPJSON {
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

    private func sessionsList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let board = await host.boardSnapshot()
        let harnesses = try arguments.optionalEnumList("harness", Harness.self) ?? []
        let activeOnly = try arguments.optionalBool("active_only") ?? true
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 50
        let ledger = await host.ledger()
        let notices = (try? ledger?.liveNotices()) ?? [:]
        let reports = (try? ledger?.allReports()) ?? [:]

        var sessions = board.sessions
        if !harnesses.isEmpty {
            let wanted = Set(harnesses)
            sessions = sessions.filter { wanted.contains($0.key.harness) }
        }
        if try arguments.optionalString("project") != nil {
            let selected = try await projectKey(arguments, caller: try await caller(arguments))
            sessions = sessions.filter { board.projectKey(for: $0) == selected }
        }
        if activeOnly { sessions = sessions.filter { !$0.state.isEnded } }
        let total = sessions.count
        return Self.success(SessionListPayload(
            sessions: sessions.prefix(limit).map { session in
                SessionPayload(
                    session,
                    project: board.projectKey(for: session).map(BoardGrouping.projectName(forPath:)),
                    notice: notices[session.key],
                    report: reports[session.key]
                )
            },
            total: total
        ))
    }

    private func sessionsGet(_ arguments: MCPArguments) async throws -> MCPJSON {
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

    private func sessionsTree(_ arguments: MCPArguments) async throws -> MCPJSON {
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

    private func peersStatus(_ arguments: MCPArguments) async throws -> MCPJSON {
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

    // MARK: - Projects

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
    private func projectKey(_ arguments: MCPArguments, caller: Caller) async throws -> String {
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
    private func projectName(_ key: String?) async -> String? {
        guard let key else { return nil }
        return TaskProject.displayName(forKey: key, in: await host.boardSnapshot())
    }

    // MARK: - Identity

    /// Who is calling, and how that was worked out.
    struct Caller {
        let session: SessionKey?
        let pid: pid_t?
        let evidence: String
    }

    /// Resolves the calling session from the most recently active kernel peer.
    ///
    /// The kit does not yet pass a connection id into `MCPLineHandler`, so the
    /// host cannot hand this actor an exact connection label. It does record
    /// activity immediately before dispatch, however, and exposes the peers in
    /// that order. We trust only the head. Walking on to another live client,
    /// as the old implementation did, could turn an unresolvable caller into a
    /// completely different agent that happened to be connected.
    ///
    /// `session_id` is now a corroborating hint, never an override. It must
    /// resolve to the same session as the process evidence. This makes a typo
    /// visible and prevents any local MCP caller from acting as an arbitrary
    /// session merely by naming a row that exists on the board.
    private func caller(_ arguments: MCPArguments) async throws -> Caller {
        let board = await host.boardSnapshot()
        let identities = board.sessions.map(\.identity)
        let table = await host.processTable()
        let clientPIDs = await host.clientPIDs()
        let automatic: Caller
        if let pid = clientPIDs.first,
           let resolution = resolver.resolve(pid: pid, identities: identities, table: table) {
            automatic = Caller(
                session: resolution.session, pid: pid, evidence: resolution.evidence
            )
        } else if clientPIDs.isEmpty, let pid = declaredPIDs.last,
                  let resolution = resolver.resolve(pid: pid, identities: identities, table: table) {
            automatic = Caller(
                session: resolution.session,
                pid: pid,
                evidence: resolution.evidence + ", from the pid this bridge declared"
            )
        } else {
            automatic = Caller(
                session: nil,
                pid: clientPIDs.first,
                evidence: clientPIDs.isEmpty
                    ? "nothing is attached to the Auspex socket that Auspex can attribute"
                    : "no session on the board owns process \(clientPIDs[0]) or any of its ancestors"
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

    /// A write that changes a session's state or authors history must have an
    /// attributable process. Task and milestone creation stay usable without
    /// one — they can be explicitly filed in a project or Scratch — but an
    /// anonymous caller cannot claim, finish, release, edit, log, archive, or
    /// signal on behalf of an agent.
    private func requireAttributedCaller(
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

    // MARK: - Plumbing

    /// MCP reads are deliberate, low-frequency snapshots rather than a live UI
    /// path. This is a practical ceiling that keeps a corrupt or future store
    /// from producing an unbounded tool response while remaining far above any
    /// task ledger a person can scan.
    private static let ledgerReadLimit = 100_000
    private static let overviewSectionLimit = 20

    private func requireLedger() async throws -> TaskRepository {
        guard let ledger = await host.ledger() else {
            throw MCPToolFailure(
                "Auspex could not open its store, so it has no task board to answer with."
            )
        }
        return ledger
    }

    private func requiredTaskID(_ arguments: MCPArguments) throws -> Int64 {
        guard let value = arguments.present("task_id")?.intValue, value > 0 else {
            throw MCPRPCError.invalidParams("'task_id' must be a positive whole number.")
        }
        return Int64(value)
    }

    /// One answer, rendered twice: as the pretty JSON a model reads and as the
    /// structured object a client can parse. Both from one encode, so they
    /// cannot disagree.
    static func success(_ payload: some Encodable) -> MCPJSON {
        let text = (try? MCPJSON.prettyText(payload)) ?? "{}"
        let structured = (try? MCPJSON.encoding(payload)) ?? .object([:])
        return .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "structuredContent": structured,
            "isError": .bool(false)
        ])
    }

    /// A tool that ran and could not answer.
    static func failure(_ message: String) -> MCPJSON {
        .object([
            "content": .array([.object(["type": "text", "text": .string(message)])]),
            "isError": .bool(true)
        ])
    }
}

// MARK: - Transport

/// Adapts the server to the kit's transport, which knows nothing about MCP.
extension AuspexMCPServer: MCPLineHandler {
    public func handle(line: Data) async -> Data? {
        await answer(line: line)
    }
}
