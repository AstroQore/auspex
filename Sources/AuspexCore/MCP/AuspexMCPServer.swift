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
/// An actor because hook routing and ledger operations are serialized here.
/// Request attribution is task-local, so overlapping connections cannot
/// overwrite one another while this actor is re-entered at an `await`.
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
    let host: any AuspexMCPHost
    let resolver: MCPSelfResolver
    private let now: @Sendable () -> Date

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
        let attribution = MCPTransportEnvelope.attribution(in: line)
        return await RequestScope.$attribution.withValue(attribution) {
            await answerAttributed(line: line)
        }
    }

    private func answerAttributed(line: Data) async -> Data? {
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

    /// Notifications: initialization, legacy bridge hello, and hook ingress.
    /// Hello is accepted for wire compatibility but is never identity evidence:
    /// it was global to the server and could cross two live connections.
    private func handleNotification(_ request: MCPRequest) async {
        switch request.method {
        case "auspex/hello":
            return
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
        with a reason when you stop. Read a task's version and pass it as \
        expected_version on later writes; a claim conflict becomes a pending \
        takeover for the person to decide, never an automatic steal. Completion \
        enters Review rather than closing your own work. With no task id, keep \
        the implicit session task instead of creating one merely for the \
        protocol. Explicit tasks remain inside their observed projects. If MCP \
        or session identity is unavailable, continue the user's work and report \
        which updates were not recorded.
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
        let pending = Dictionary(grouping: try ledger.claimRequests()) { $0.taskID }
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
                    projectName: $0.projectKey.map { TaskProject.displayName(forKey: $0, in: board) },
                    pendingClaims: pending[$0.id] ?? []
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
        let pending = Dictionary(grouping: try ledger.claimRequests()) { $0.taskID }
        let board = await host.boardSnapshot()
        return Self.success(TaskListPayload(
            tasks: tasks.map {
                TaskPayload(
                    $0,
                    sessions: (links[$0.id] ?? []).map(\.session),
                    projectName: $0.projectKey.map { TaskProject.displayName(forKey: $0, in: board) },
                    pendingClaims: pending[$0.id] ?? []
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
                satisfied: row?.status == .done
            )
        }

        let board = await host.boardSnapshot()
        let notices = try ledger.liveNotices()
        let reports = try ledger.allReports()
        let allLinks = try ledger.allLinks()
        let taskIDsBySession = Dictionary(grouping: allLinks, by: \.session)
            .mapValues { $0.map(\.taskID) }
        let taskLinks = try ledger.links(taskID: id)
        let pendingClaims = try ledger.claimRequests(taskID: id)
        let history = try ledger.log(taskID: id, limit: 20)
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
                },
                pendingClaims: pendingClaims
            ),
            readiness: .init(
                ready: blocking.isEmpty,
                dependencies: dependencies,
                blocking: blocking
            ),
            pendingClaims: pendingClaims.map(TaskClaimRequestPayload.init),
            attempts: history
                .filter { ["claimed", "released", "finished"].contains($0.kind) }
                .map(TaskDetailPayload.Attempt.init),
            history: history.map(TaskLogPayload.Entry.init),
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
        let reason = MCPTextSanitizer.clean(try arguments.optionalString("reason"))
        let expectedVersion = try Self.expectedVersion(arguments)
        let caller = try await requireAttributedCaller(arguments, action: "claim a task")
        let session = caller.session!
        // The claimer's own project, applied only if the task has none — a task
        // inherits its project from whoever first takes it.
        let board = await host.boardSnapshot()
        let outcome = try ledger.claimOrRequestTask(
            id: id, role: role, scope: scope, reason: reason, by: session,
            projectKey: TaskProject.resolve(explicit: nil, session: session, board: board),
            expectedVersion: expectedVersion,
            now: now()
        )
        let task: AuspexTask
        let claimOutcome: String
        switch outcome {
        case .claimed(let claimed):
            task = claimed
            claimOutcome = "claimed"
        case .pending(let unchanged, _):
            task = unchanged
            claimOutcome = "pending_takeover"
        }
        await host.didChangeLedger()
        let sessions = try ledger.links(taskID: id).map(\.session)
        return Self.success(TaskPayload(
            task,
            sessions: sessions,
            projectName: task.projectKey.map { TaskProject.displayName(forKey: $0, in: board) },
            pendingClaims: try ledger.claimRequests(taskID: id),
            claimOutcome: claimOutcome
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
            id: id, by: session, reason: reason, requireHolder: true,
            expectedVersion: try Self.expectedVersion(arguments), now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(
            task,
            sessions: try ledger.links(taskID: id).map(\.session),
            projectName: await projectName(task.projectKey),
            pendingClaims: try ledger.claimRequests(taskID: id)
        ))
    }

    private func tasksUpdate(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let status = try arguments.optionalEnum("status", AuspexTaskStatus.self)
        if status == .done {
            throw MCPToolFailure(
                "An agent cannot close its own task. Use tasks.complete to move it into Review."
            )
        }
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
        let targetProject: String?
        if try arguments.optionalString("project") != nil {
            targetProject = try await projectKey(arguments, caller: caller)
        } else {
            targetProject = nil
        }
        let task = try ledger.updateTask(
            id: id,
            title: title,
            body: body.map { Optional($0) },
            status: status,
            priority: priority,
            planID: planID,
            kind: kind,
            labels: labels,
            dependsOn: dependsOn,
            projectKey: targetProject,
            actor: caller.session,
            expectedVersion: try Self.expectedVersion(arguments),
            now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(
            task,
            projectName: await projectName(task.projectKey),
            pendingClaims: try ledger.claimRequests(taskID: id)
        ))
    }

    private func tasksComplete(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let result = MCPTextSanitizer.clean(try arguments.optionalString("result"))
        let caller = try await requireAttributedCaller(arguments, action: "finish a task")
        let task = try ledger.completeTask(
            id: id, result: result, by: caller.session,
            requireHolder: true,
            expectedVersion: try Self.expectedVersion(arguments), now: now()
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
        return Self.success(TaskPayload(
            task,
            projectName: await projectName(task.projectKey),
            pendingClaims: try ledger.claimRequests(taskID: id)
        ))
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
            ref: ref, expectedVersion: try Self.expectedVersion(arguments), now: now()
        )
        await host.didChangeLedger()
        let task = try ledger.task(id: id)
        return Self.success(TaskLogPayload(
            taskID: id,
            version: task?.version,
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
        var ids: [Int64] = []
        for item in items {
            guard let value = item.intValue, value > 0 else {
                throw MCPToolFailure("'depends_on' contains a value that is not a positive task id.")
            }
            ids.append(Int64(value))
        }
        return ids
    }

    private static func expectedVersion(_ arguments: MCPArguments) throws -> Int64? {
        try arguments.optionalInt("expected_version", minimum: 1, maximum: Int.max)
            .map(Int64.init)
    }

    // MARK: - Plumbing

    /// MCP reads are deliberate, low-frequency snapshots rather than a live UI
    /// path. This is a practical ceiling that keeps a corrupt or future store
    /// from producing an unbounded tool response while remaining far above any
    /// task ledger a person can scan.
    static let ledgerReadLimit = 100_000

    func requireLedger() async throws -> TaskRepository {
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
