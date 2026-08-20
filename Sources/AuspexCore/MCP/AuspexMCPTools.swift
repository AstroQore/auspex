import AgentSessionKit
import Foundation

/// Every tool Auspex answers, and the schema each one is called with.
///
/// ## What this surface is for
///
/// Auspex watches harness stores passively, and that layer is the floor: it
/// works for an agent that has never heard of Auspex, which is most of them
/// most of the time. This surface is the *enrichment*, and the ranking inside
/// it is deliberate:
///
/// 1. **`auspex.notify` is the valuable one.** Passive observation can tell
///    that a session went quiet; it cannot tell whether that session is stuck
///    on a question, waiting to be reviewed, or simply finished. No harness
///    exports "I asked the user something and I am waiting" — Claude Code and
///    Cursor do not surface a permission state in their files at all — so one
///    call from the agent is worth more than any amount of inference.
/// 2. **`auspex.report` is a nicety.** It replaces a guess with a statement.
/// 3. **The task tools are the skeleton**, and their intended caller is
///    whoever *hands work out*, not each worker in turn. A supervisor
///    registers a plan and its tasks, writes the ids into the briefs it sends,
///    and each worker makes one `tasks.claim` call. Twelve workers each
///    inventing their own vocabulary produce twelve vocabularies.
///
/// ## Naming
///
/// Dotted names — `tasks.claim`, not `tasks_claim`. MCP clients normalise the
/// separator for their own tool namespaces anyway, and the dot is what makes a
/// list of sixteen tools read as four groups.
public enum AuspexMCPTools {
    /// The MCP protocol revision this server implements.
    public static let protocolVersion = "2025-06-18"

    /// The server's own name, as it appears in a client's tool list and in
    /// every harness config Auspex writes.
    public static let serverName = "auspex"

    // MARK: - Names

    public enum Name {
        public static let notify = "auspex.notify"
        public static let report = "auspex.report"
        public static let plansList = "plans.list"
        public static let plansGet = "plans.get"
        public static let plansCreate = "plans.create"
        public static let plansArchive = "plans.archive"
        public static let tasksList = "tasks.list"
        public static let tasksCreate = "tasks.create"
        public static let tasksClaim = "tasks.claim"
        public static let tasksUpdate = "tasks.update"
        public static let tasksComplete = "tasks.complete"
        public static let tasksLog = "tasks.log"
        public static let sessionsSelf = "sessions.self"
        public static let sessionsList = "sessions.list"
        public static let sessionsTree = "sessions.tree"
        public static let peersStatus = "peers.status"
    }

    /// Which tools write. A read-only host (a demo replay) refuses exactly
    /// these and answers the rest normally, so an agent pointed at a demo gets
    /// a plain refusal rather than a board that silently forgets.
    public static let writingTools: Set<String> = [
        Name.notify, Name.report, Name.plansCreate, Name.plansArchive,
        Name.tasksCreate, Name.tasksClaim, Name.tasksUpdate,
        Name.tasksComplete, Name.tasksLog
    ]

    // MARK: - Catalog

    /// Every tool, in the order a reader should meet them.
    public static let all: [MCPTool] = [
        notify, report,
        plansList, plansGet, plansCreate, plansArchive,
        tasksList, tasksCreate, tasksClaim, tasksUpdate, tasksComplete, tasksLog,
        sessionsSelf, sessionsList, sessionsTree, peersStatus
    ]

    /// One tool by name.
    public static func tool(named name: String) -> MCPTool? {
        all.first { $0.name == name }
    }

    // MARK: - The two that matter most

    public static let notify = MCPTool(
        name: Name.notify,
        title: "Call the user",
        description: """
            Ask the person watching Auspex to come and look. The session moves \
            into the matching bucket on the board with your own words on it, a \
            macOS notification is posted, and the menu-bar count changes.

            Use it the moment you would otherwise sit and wait: 'needs_input' \
            when you asked a question, 'needs_review' when you want something \
            checked before you go on, 'blocked' when you cannot proceed, \
            'done' when you have finished and want the result read. A \
            'needs_input' call clears itself when the person next talks to \
            this session.

            Say what you need in one sentence. The message is what appears on \
            the notification and on the card, so 'Which of the two migrations \
            should I keep?' is useful and 'need help' is not.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "kind": .object([
                    "type": "string",
                    "enum": .array(AgentNoticeKind.allCases.map { .string($0.rawValue) }),
                    "description": "Why you are calling."
                ]),
                "message": .object([
                    "type": "string",
                    "description": "One sentence, in your own words. Up to 500 characters."
                ]),
                "urgency": .object([
                    "type": "string",
                    "enum": .array(AgentNoticeUrgency.allCases.map { .string($0.rawValue) }),
                    "description": "Advisory. Changes how loudly the notification arrives, nothing else."
                ]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["kind", "message"])
        ])
    )

    public static let report = MCPTool(
        name: Name.report,
        title: "Say what you are doing",
        description: """
            Replace Auspex's guess about what this session is doing with one \
            line of your own. It shows on the card, marked as self-reported, \
            until you next say something in prose.

            Optional. Auspex infers a line from the transcript when you do not \
            call this, so a session that never reports is not worse off — it \
            is just described less precisely.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "focus": .object([
                    "type": "string",
                    "description": "What you are working on right now. Up to 500 characters."
                ]),
                "progress": .object([
                    "type": "string",
                    "description": "How far along, in whatever you count in: 'step 2 of 5', '40%'."
                ]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["focus"])
        ])
    )

    // MARK: - Plans

    public static let plansList = MCPTool(
        name: Name.plansList,
        title: "List plans",
        description: """
            The decompositions registered on this machine. Read this before \
            creating one: the plan you are about to register may already be \
            there, and a duplicate lane on somebody's board is worse than a \
            task filed in the wrong place.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "include_archived": .object([
                    "type": "boolean",
                    "description": "Include plans that have been filed away. Default false."
                ]),
                "limit": limitProperty(default: 50)
            ])
        ])
    )

    public static let plansGet = MCPTool(
        name: Name.plansGet,
        title: "Read one plan",
        description: "One plan and every task under it.",
        inputSchema: .object([
            "type": "object",
            "properties": .object(["plan": planProperty]),
            "required": .array(["plan"])
        ])
    )

    public static let plansCreate = MCPTool(
        name: Name.plansCreate,
        title: "Register a plan",
        description: """
            Register a decomposition you are about to hand out. Call this when \
            you are the one splitting work up — then create a task per worker \
            and put the task id in the brief you send each of them.

            Registering the same slug twice returns the plan that is already \
            there, so a retried brief does not produce a second lane.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "title": .object([
                    "type": "string",
                    "description": "What the whole piece of work is."
                ]),
                "slug": .object([
                    "type": "string",
                    "description": "A short handle to name it by in briefs. Derived from the title if omitted."
                ]),
                "summary": .object([
                    "type": "string",
                    "description": "A paragraph of context for whoever reads the board later."
                ])
            ]),
            "required": .array(["title"])
        ])
    )

    public static let plansArchive = MCPTool(
        name: Name.plansArchive,
        title: "File a plan away",
        description: """
            Take a finished plan off the board. Its tasks stay exactly as they \
            are — archiving a heading must not silently close the work under it.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object(["plan": planProperty]),
            "required": .array(["plan"])
        ])
    )

    // MARK: - Tasks

    public static let tasksList = MCPTool(
        name: Name.tasksList,
        title: "List tasks",
        description: """
            What is on the board. Call this at the start of a session together \
            with plans.list: if your brief named a task id, claim it; if it did \
            not, look for the task that describes what you were asked to do \
            before filing a new one.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "plan": .object([
                    "type": "string",
                    "description": "Only tasks under this plan, by id or slug."
                ]),
                "status": .object([
                    "type": "array",
                    "items": .object([
                        "type": "string",
                        "enum": .array(AuspexTaskStatus.allCases.map { .string($0.rawValue) })
                    ]),
                    "description": "Only tasks in these columns."
                ]),
                "mine": .object([
                    "type": "boolean",
                    "description": "Only the tasks this session holds a claim on."
                ]),
                "limit": limitProperty(default: 100)
            ])
        ])
    )

    public static let tasksCreate = MCPTool(
        name: Name.tasksCreate,
        title: "File a task",
        description: """
            File one unit of work, normally under a plan you just registered. \
            The id that comes back is what you put in the worker's brief.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "title": .object(["type": "string", "description": "What has to be done."]),
                "body": .object([
                    "type": "string",
                    "description": "The detail a worker needs. Up to 4000 characters."
                ]),
                "plan": .object([
                    "type": "string",
                    "description": "The plan it belongs under, by id or slug."
                ]),
                "status": .object([
                    "type": "string",
                    "enum": .array(AuspexTaskStatus.allCases.map { .string($0.rawValue) }),
                    "description": "Which column to file it in. Default 'todo'."
                ]),
                "priority": .object([
                    "type": "integer",
                    "description": "Higher sorts first within its column. Default 0."
                ])
            ]),
            "required": .array(["title"])
        ])
    )

    public static let tasksClaim = MCPTool(
        name: Name.tasksClaim,
        title: "Take a task",
        description: """
            Say that this session is doing this task, in what role and over \
            what part of it. The board then hangs your session under the task \
            and shows the role and scope on the row, which is how somebody \
            scanning twelve live sessions tells them apart.

            Refused when another session already holds it. Re-claiming a task \
            you already hold is fine and updates the scope.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "task_id": .object(["type": "integer", "description": "The task to take."]),
                "role": .object([
                    "type": "string",
                    "description": "What you are on this task: 'implementer', 'reviewer', 'researcher'…"
                ]),
                "scope": .object([
                    "type": "string",
                    "description": "Which part of it is yours, in a few words."
                ]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["task_id", "role"])
        ])
    )

    public static let tasksUpdate = MCPTool(
        name: Name.tasksUpdate,
        title: "Move a task",
        description: """
            Change a task's column, title, body, priority, or plan. Use \
            'blocked' the moment you are stuck — and call auspex.notify as \
            well, because a column change is something a person has to be \
            looking at the board to see.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "task_id": .object(["type": "integer", "description": "The task to change."]),
                "status": .object([
                    "type": "string",
                    "enum": .array(AuspexTaskStatus.allCases.map { .string($0.rawValue) })
                ]),
                "title": .object(["type": "string"]),
                "body": .object(["type": "string"]),
                "priority": .object(["type": "integer"]),
                "plan": .object([
                    "type": "string",
                    "description": "Move it under this plan, by id or slug."
                ]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["task_id"])
        ])
    )

    public static let tasksComplete = MCPTool(
        name: Name.tasksComplete,
        title: "Finish a task",
        description: """
            Close a task and record, in one line, what you actually finished. \
            That line is what the person reads instead of opening your \
            transcript, so write it for them.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "task_id": .object(["type": "integer"]),
                "result": .object([
                    "type": "string",
                    "description": "What you finished, in one sentence."
                ]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["task_id"])
        ])
    )

    public static let tasksLog = MCPTool(
        name: Name.tasksLog,
        title: "Add a note to a task",
        description: """
            Append one line to a task's history — a decision, a dead end, a \
            handover note for whoever picks it up next.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "task_id": .object(["type": "integer"]),
                "message": .object(["type": "string", "description": "The line. Up to 500 characters."]),
                "session_id": sessionIDProperty
            ]),
            "required": .array(["task_id", "message"])
        ])
    )

    // MARK: - Sessions

    public static let sessionsSelf = MCPTool(
        name: Name.sessionsSelf,
        title: "Who am I",
        description: """
            Which session Auspex thinks you are, worked out from the process \
            on the other end of this connection. You never need to know your \
            own session id; call this if you want to check that Auspex has \
            placed you correctly, or to find the tasks already linked to you.
            """,
        inputSchema: .object(["type": "object", "properties": .object([:])])
    )

    public static let sessionsList = MCPTool(
        name: Name.sessionsList,
        title: "List sessions",
        description: """
            Every agent session Auspex can see on this machine, across every \
            harness — what each is doing, what it was asked to do, and whether \
            it is calling for the user. Read-only.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "harness": .object([
                    "type": "array",
                    "items": .object([
                        "type": "string",
                        "enum": .array(Harness.allCases.map { .string($0.rawValue) })
                    ]),
                    "description": "Only these harnesses."
                ]),
                "active_only": .object([
                    "type": "boolean",
                    "description": "Leave out the sessions that have ended. Default true."
                ]),
                "limit": limitProperty(default: 50)
            ])
        ])
    )

    public static let sessionsTree = MCPTool(
        name: Name.sessionsTree,
        title: "Delegation tree",
        description: """
            Who spawned whom, across harnesses — a Claude Code session that \
            shelled out to Codex shows as its parent. Given no session, the \
            whole forest; given one, the branch it is on.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "session_key": .object([
                    "type": "string",
                    "description": "'<harness>:<session id>'. Omit for the whole forest."
                ]),
                "limit": limitProperty(default: 50)
            ])
        ])
    )

    public static let peersStatus = MCPTool(
        name: Name.peersStatus,
        title: "What everyone is doing",
        description: """
            One line of counts: how many sessions are working, idle, finished, \
            and how many are calling for the user right now. The cheapest way \
            to find out whether you are the only thing running.
            """,
        inputSchema: .object(["type": "object", "properties": .object([:])])
    )

    // MARK: - Shared schema fragments

    /// The identity override, on every tool that acts *as* a session.
    ///
    /// Normally unnecessary and deliberately described that way: the pid on
    /// the socket answers the question, and an agent that guesses its own id
    /// wrong would file its work under somebody else's row. It exists for the
    /// harness whose bridge the kernel will not attribute a pid to.
    private static let sessionIDProperty: MCPJSON = .object([
        "type": "string",
        "description": """
            Only if Auspex could not work out who you are. Your harness's own \
            session id, or '<harness>:<session id>'.
            """
    ])

    private static let planProperty: MCPJSON = .object([
        "type": "string",
        "description": "The plan, by numeric id or by slug."
    ])

    private static func limitProperty(default value: Int) -> MCPJSON {
        .object([
            "type": "integer",
            "minimum": 1,
            "maximum": 500,
            "description": .string("How many rows at most. Default \(value).")
        ])
    }
}
