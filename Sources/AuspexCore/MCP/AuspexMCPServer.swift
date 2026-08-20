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
///   fabricated board and refuses the nine writing tools by name.
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
    /// The same three sentences the installed protocol snippet carries, for the
    /// harness that reads server instructions and the one whose config file
    /// Auspex was never allowed to touch.
    static let instructions = """
        Auspex is watching every AI agent session on this Mac. Two habits make \
        it useful: call auspex.notify the moment you need the person — a \
        question, a review, a blocker, or a finished piece of work — instead of \
        going quiet, and keep the task board honest by claiming the task id your \
        brief named (or reading plans.list/tasks.list when it named none).
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
        case AuspexMCPTools.Name.plansList:     return try await plansList(arguments)
        case AuspexMCPTools.Name.plansGet:      return try await plansGet(arguments)
        case AuspexMCPTools.Name.plansCreate:   return try await plansCreate(arguments)
        case AuspexMCPTools.Name.plansArchive:  return try await plansArchive(arguments)
        case AuspexMCPTools.Name.tasksList:     return try await tasksList(arguments)
        case AuspexMCPTools.Name.tasksCreate:   return try await tasksCreate(arguments)
        case AuspexMCPTools.Name.tasksClaim:    return try await tasksClaim(arguments)
        case AuspexMCPTools.Name.tasksUpdate:   return try await tasksUpdate(arguments)
        case AuspexMCPTools.Name.tasksComplete: return try await tasksComplete(arguments)
        case AuspexMCPTools.Name.tasksLog:      return try await tasksLog(arguments)
        case AuspexMCPTools.Name.sessionsSelf:  return try await sessionsSelf(arguments)
        case AuspexMCPTools.Name.sessionsList:  return try await sessionsList(arguments)
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
        let caller = try await caller(arguments)
        let ledger = try await requireLedger()

        guard let session = caller.session else {
            // Refusing is the honest answer: a notice filed against nobody
            // would count towards a board nobody can act on, and the agent can
            // fix it in one call by passing its own id.
            throw MCPToolFailure(
                "Auspex could not work out which session this is (\(caller.evidence)). "
                    + "Call sessions.self, or pass 'session_id'."
            )
        }

        let notice = try ledger.recordNotice(
            session: session, kind: kind, message: message, urgency: urgency, now: now()
        )
        await host.didRecordNotice(notice)

        return Self.success(NotifyPayload(
            session: session.description,
            kind: kind.rawValue,
            message: message,
            urgency: urgency.rawValue,
            at: notice.createdAt,
            bucket: kind.wantsPerson ? "needs you" : "done unseen",
            resolved: true,
            evidence: caller.evidence,
            clearsWhen: kind == .needsInput
                ? "the person next talks to this session, or dismisses it from the card"
                : "the person dismisses it from the card"
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
        let caller = try await caller(arguments)
        let ledger = try await requireLedger()

        guard let session = caller.session else {
            throw MCPToolFailure(
                "Auspex could not work out which session this is (\(caller.evidence)). "
                    + "Call sessions.self, or pass 'session_id'."
            )
        }
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
        return Self.success(PlanListPayload(
            plans: plans.map { PlanPayload($0, tasks: byPlan[$0.id] ?? []) },
            note: plans.isEmpty
                ? "No plan is registered. If you are handing work out, register one with plans.create."
                : nil
        ))
    }

    private func plansGet(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let reference = try arguments.requiredString("plan")
        guard let plan = try ledger.plan(reference: reference) else {
            throw MCPToolFailure("No plan is registered as '\(reference)'.")
        }
        let tasks = try ledger.tasks(planID: plan.id)
        let links = try ledger.allLinks()
        let bySession = Dictionary(grouping: links) { $0.taskID }
        return Self.success(PlanDetailPayload(
            plan: PlanPayload(plan, tasks: tasks),
            tasks: tasks.map { TaskPayload($0, sessions: (bySession[$0.id] ?? []).map(\.session)) }
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
        let plan = try ledger.createPlan(
            title: title, slug: slug, summary: summary, createdBy: caller.session, now: now()
        )
        await host.didChangeLedger()
        return Self.success(PlanPayload(plan, tasks: try ledger.tasks(planID: plan.id)))
    }

    private func plansArchive(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let reference = try arguments.requiredString("plan")
        guard let plan = try ledger.plan(reference: reference) else {
            throw MCPToolFailure("No plan is registered as '\(reference)'.")
        }
        guard let archived = try ledger.archivePlan(id: plan.id, now: now()) else {
            throw MCPToolFailure("The plan could not be archived.")
        }
        await host.didChangeLedger()
        return Self.success(PlanPayload(archived))
    }

    // MARK: - Tasks

    private func tasksList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 100
        let statuses = try arguments.optionalEnumList("status", AuspexTaskStatus.self) ?? []
        var planID: Int64?
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No plan is registered as '\(reference)'.")
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
        let tasks = try ledger.tasks(
            planID: planID, statuses: statuses, claimedBy: claimedBy, limit: limit
        )
        let links = Dictionary(grouping: try ledger.allLinks()) { $0.taskID }
        return Self.success(TaskListPayload(
            tasks: tasks.map { TaskPayload($0, sessions: (links[$0.id] ?? []).map(\.session)) },
            note: tasks.isEmpty
                ? "Nothing is filed. If your brief named a task id it may be under an archived plan; otherwise file one with tasks.create."
                : nil
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
        let priority = try arguments.optionalInt("priority", minimum: -100, maximum: 100) ?? 0
        var planID: Int64?
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No plan is registered as '\(reference)'.")
            }
            planID = plan.id
        }
        let caller = try await caller(arguments)
        let task = try ledger.createTask(
            title: title, body: body, planID: planID, status: status, priority: priority,
            createdBy: caller.session, source: "mcp", now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(task))
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
        let caller = try await caller(arguments)
        guard let session = caller.session else {
            throw MCPToolFailure(
                "A claim has to name a session, and Auspex could not work out which one you are "
                    + "(\(caller.evidence)). Call sessions.self, or pass 'session_id'."
            )
        }
        let task = try ledger.claimTask(id: id, role: role, scope: scope, by: session, now: now())
        await host.didChangeLedger()
        let sessions = try ledger.links(taskID: id).map(\.session)
        return Self.success(TaskPayload(task, sessions: sessions))
    }

    private func tasksUpdate(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let status = try arguments.optionalEnum("status", AuspexTaskStatus.self)
        let title = MCPTextSanitizer.clean(try arguments.optionalString("title"), limit: 200)
        let body = MCPTextSanitizer.clean(try arguments.optionalString("body"), limit: 4_000)
        let priority = try arguments.optionalInt("priority", minimum: -100, maximum: 100)
        var planID: Int64??
        if let reference = try arguments.optionalString("plan") {
            guard let plan = try ledger.plan(reference: reference) else {
                throw MCPToolFailure("No plan is registered as '\(reference)'.")
            }
            planID = .some(plan.id)
        }
        let caller = try await caller(arguments)
        let task = try ledger.updateTask(
            id: id,
            title: title,
            body: body.map { Optional($0) },
            status: status,
            priority: priority,
            planID: planID,
            actor: caller.session,
            now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(task))
    }

    private func tasksComplete(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let result = MCPTextSanitizer.clean(try arguments.optionalString("result"))
        let caller = try await caller(arguments)
        let task = try ledger.completeTask(
            id: id, result: result, by: caller.session, now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskPayload(task))
    }

    private func tasksLog(_ arguments: MCPArguments) async throws -> MCPJSON {
        let ledger = try await requireLedger()
        let id = try requiredTaskID(arguments)
        let message = try MCPTextSanitizer.require(
            try arguments.requiredString("message"),
            field: "message", tool: AuspexMCPTools.Name.tasksLog
        )
        let caller = try await caller(arguments)
        guard try ledger.task(id: id) != nil else {
            throw TaskLedgerError.notFound("task \(id)")
        }
        try ledger.appendLog(
            taskID: id, actor: caller.session, kind: "note", message: message, now: now()
        )
        await host.didChangeLedger()
        return Self.success(TaskLogPayload(
            taskID: id,
            entries: try ledger.log(taskID: id, limit: 20).map(TaskLogPayload.Entry.init)
        ))
    }

    // MARK: - Sessions

    private func sessionsSelf(_ arguments: MCPArguments) async throws -> MCPJSON {
        let caller = try await caller(arguments)
        let board = await host.boardSnapshot()
        let ledger = await host.ledger()
        let notices = (try? ledger?.liveNotices()) ?? [:]

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
                notice: notices[key]
            ),
            evidence: caller.evidence,
            clientPID: caller.pid,
            tasks: tasks.map { TaskPayload($0) }
        ))
    }

    private func sessionsList(_ arguments: MCPArguments) async throws -> MCPJSON {
        let board = await host.boardSnapshot()
        let harnesses = try arguments.optionalEnumList("harness", Harness.self) ?? []
        let activeOnly = try arguments.optionalBool("active_only") ?? true
        let limit = try arguments.optionalInt("limit", minimum: 1, maximum: 500) ?? 50
        let notices = (try? await host.ledger()?.liveNotices()) ?? [:]

        var sessions = board.sessions
        if !harnesses.isEmpty {
            let wanted = Set(harnesses)
            sessions = sessions.filter { wanted.contains($0.key.harness) }
        }
        if activeOnly { sessions = sessions.filter { !$0.state.isEnded } }
        let total = sessions.count
        return Self.success(SessionListPayload(
            sessions: sessions.prefix(limit).map { session in
                SessionPayload(
                    session,
                    project: board.projectKey(for: session).map(BoardGrouping.projectName(forPath:)),
                    notice: notices[session.key]
                )
            },
            total: total
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

    // MARK: - Identity

    /// Who is calling, and how that was worked out.
    struct Caller {
        let session: SessionKey?
        let pid: pid_t?
        let evidence: String
    }

    /// Resolves the calling session: the explicit override first, then the pid
    /// on the socket, then the pid a bridge declared for itself.
    ///
    /// The override wins because an agent that passes `session_id` is stating
    /// a fact about itself that nothing else in the room knows better. It is
    /// still checked against the board — a key that names no session is a
    /// typo, and attributing work to a row that does not exist would be worse
    /// than saying so.
    private func caller(_ arguments: MCPArguments) async throws -> Caller {
        let board = await host.boardSnapshot()

        if let raw = try arguments.optionalString("session_id"),
           let cleaned = MCPTextSanitizer.clean(raw, limit: 200) {
            if let key = SessionKey(string: cleaned), board.session(for: key) != nil {
                return Caller(session: key, pid: nil, evidence: "you named '\(cleaned)'")
            }
            // The bare id, without the harness prefix, is what a harness's own
            // environment variable holds — so it is what an agent reaches for.
            let matches = board.sessions.filter { $0.key.sessionID == cleaned }
            if matches.count == 1 {
                return Caller(
                    session: matches[0].key,
                    pid: nil,
                    evidence: "you named session id '\(cleaned)'"
                )
            }
            if matches.count > 1 {
                throw MCPToolFailure(
                    "'\(cleaned)' matches \(matches.count) sessions. "
                        + "Pass '<harness>:<session id>' instead."
                )
            }
            throw MCPToolFailure("No session on the board is '\(cleaned)'.")
        }

        let identities = board.sessions.map(\.identity)
        let table = await host.processTable()
        let clientPIDs = await host.clientPIDs()

        for pid in clientPIDs {
            if let resolution = resolver.resolve(pid: pid, identities: identities, table: table) {
                return Caller(session: resolution.session, pid: pid, evidence: resolution.evidence)
            }
        }
        for pid in declaredPIDs.reversed() {
            if let resolution = resolver.resolve(pid: pid, identities: identities, table: table) {
                return Caller(
                    session: resolution.session,
                    pid: pid,
                    evidence: resolution.evidence + ", from the pid this bridge declared"
                )
            }
        }
        return Caller(
            session: nil,
            pid: clientPIDs.first,
            evidence: clientPIDs.isEmpty
                ? "nothing is attached to the Auspex socket that Auspex can attribute"
                : "no session on the board owns process \(clientPIDs[0]) or any of its ancestors"
        )
    }

    // MARK: - Plumbing

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
