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
///    registers a milestone and its tasks, writes the ids into the briefs it
///    sends, and each worker makes one `tasks.claim` call. Twelve workers each
///    inventing their own vocabulary produce twelve vocabularies.
///
/// ## Projects contain tasks
///
/// There is one hierarchy: **project ⊃ task ⊃ sessions**. Every task belongs
/// to exactly one project, and a caller almost never has to say which —
/// Auspex resolves it from the session on the other end of the connection, the
/// same way the board decides which section a card is drawn in. `project` is
/// there for an orchestrator filing work somewhere other than where it is
/// standing.
///
/// The `plans.*` tools are still here and still work. A "plan" is now a
/// **milestone**: an optional heading *inside* a project rather than a second
/// root next to it. The names are kept because briefs already in flight name
/// them.
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

    // MARK: - Milestones (the `plans.*` names, kept)

    public static let plansList = MCPTool(
        name: Name.plansList,
        title: "List milestones",
        description: """
            The milestones registered on this machine, with the project each \
            one is inside. A milestone is a heading tasks can hang under — \
            optional, and not a container of its own: the container is the \
            project.

            Read this before creating one: the milestone you are about to \
            register may already be there, and a duplicate heading on \
            somebody's board is worse than a task filed in the wrong place.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "include_archived": .object([
                    "type": "boolean",
                    "description": "Include milestones that have been filed away. Default false."
                ]),
                "limit": limitProperty(default: 50)
            ])
        ])
    )

    public static let plansGet = MCPTool(
        name: Name.plansGet,
        title: "Read one milestone",
        description: "One milestone and every task under it.",
        inputSchema: .object([
            "type": "object",
            "properties": .object(["plan": planProperty]),
            "required": .array(["plan"])
        ])
    )

    public static let plansCreate = MCPTool(
        name: Name.plansCreate,
        title: "Register a milestone",
        description: """
            Register a decomposition you are about to hand out, as a milestone \
            inside a project. Call this when you are the one splitting work up \
            — then create a task per worker and put the task id in the brief \
            you send each of them.

            The project is the one you are working in unless you name another. \
            Registering the same slug twice returns the milestone that is \
            already there, so a retried brief does not produce a second heading.
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
                ]),
                "project": projectProperty
            ]),
            "required": .array(["title"])
        ])
    )

    public static let plansArchive = MCPTool(
        name: Name.plansArchive,
        title: "File a milestone away",
        description: """
            Take a finished milestone off the board. Its tasks stay exactly as \
            they are, in the project they are in — archiving a heading must not \
            silently close the work under it.
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
            What is on the board, grouped by the project each task is in. Call \
            this at the start of a session: if your brief named a task id, \
            claim it; if it did not, look for the task that describes what you \
            were asked to do before filing a new one.

            With no arguments it lists every project's tasks. Pass 'project' \
            to see only the one you are working in.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "plan": .object([
                    "type": "string",
                    "description": "Only tasks under this milestone, by id or slug."
                ]),
                "project": projectProperty,
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
                "ready_only": .object([
                    "type": "boolean",
                    "description": """
                        Only tasks whose dependencies are all closed. What to \
                        pass when you are looking for something to pick up: a \
                        task that waits on unfinished work is not work.
                        """
                ]),
                "label": .object([
                    "type": "string",
                    "description": "Only tasks carrying this label."
                ]),
                "limit": limitProperty(default: 100)
            ])
        ])
    )

    public static let tasksCreate = MCPTool(
        name: Name.tasksCreate,
        title: "File a task",
        description: """
            File one unit of work. The id that comes back is what you put in \
            the worker's brief.

            It is filed in **the project you are working in** — Auspex works \
            that out from your session, the same way it decides which section \
            your card is drawn in on the board. Nothing lands in an "unfiled" \
            pile. Name 'project' only when you are filing work somewhere other \
            than where you are standing, and 'plan' only if the project has a \
            milestone this belongs under.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "title": .object(["type": "string", "description": "What has to be done."]),
                "body": .object([
                    "type": "string",
                    "description": "The detail a worker needs. Up to 4000 characters."
                ]),
                "project": projectProperty,
                "plan": .object([
                    "type": "string",
                    "description": "The milestone it belongs under, by id or slug."
                ]),
                "status": .object([
                    "type": "string",
                    "enum": .array(AuspexTaskStatus.allCases.map { .string($0.rawValue) }),
                    "description": "Which column to file it in. Default 'todo'."
                ]),
                "priority": .object([
                    "type": "integer",
                    "description": "Higher sorts first within its column. Default 0."
                ]),
                "importance": importanceProperty,
                "kind": kindProperty,
                "labels": labelsProperty,
                "depends_on": dependsOnProperty
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
            Change a task's column, title, body, importance, kind, labels, \
            dependencies, milestone, or the project it is in. Use 'blocked' the \
            moment you are stuck — and call auspex.notify as well, because a \
            column change is something a person has to be looking at the board \
            to see.

            'done' is a person's word. Finish with tasks.complete, which puts \
            the task in 'review' for somebody to close.
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
                "importance": importanceProperty,
                "kind": kindProperty,
                "labels": labelsProperty,
                "depends_on": dependsOnProperty,
                "plan": .object([
                    "type": "string",
                    "description": "Move it under this milestone, by id or slug."
                ]),
                "project": .object([
                    "type": "string",
                    "description": """
                        Move it into this project — a path, or the name of a \
                        project on the board. Filed in the task's history.
                        """
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
            Say that you have finished a task, and record in one line what you \
            actually did. That line is what the person reads instead of \
            opening your transcript, so write it for them.

            **This asks for a review; it does not close anything.** The task \
            moves to 'review', stays counted as open, and waits for a person. \
            That is on purpose: nobody marks their own homework.
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

            Say which kind it is. 'decision' is a choice a later reader must \
            not silently undo; 'evidence' is something they can go and check, \
            and takes a 'ref' — a commit, a URL, a path; 'risk' is something \
            nobody has dealt with yet. Everything else is 'note'.

            Write the sentence, not the output. A note is what somebody reads \
            instead of your transcript, so no command output, no secrets, no \
            pasted files.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "task_id": .object(["type": "integer"]),
                "message": .object(["type": "string", "description": "The line. Up to 500 characters."]),
                "kind": .object([
                    "type": "string",
                    "enum": .array(TaskNoteKind.allCases.map { .string($0.rawValue) }),
                    "description": "What kind of line this is. Default 'note'."
                ]),
                "ref": .object([
                    "type": "string",
                    "description": """
                        Where to go and check: a commit hash, a URL, a path. \
                        Belongs on 'evidence' most of all.
                        """
                ]),
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
        "description": "The milestone, by numeric id or by slug."
    ])

    /// Which project, on the tools that file or move work.
    ///
    /// Optional everywhere, and described as such: a worker filing its own
    /// task should say nothing and be filed where it is working. The three
    /// spellings are the three a caller can actually have — a directory it
    /// knows, a name a person uses, or the key the board answered `sessions.self`
    /// with.
    private static let projectProperty: MCPJSON = .object([
        "type": "string",
        "description": """
            Which project, as an absolute path, the name of a project on the \
            board, or a project key from sessions.self. Leave it out to use \
            the project this session is working in, which is almost always \
            what you want.
            """
    ])

    /// How much a task matters, in words rather than in a number a caller has
    /// to guess the scale of. `priority` still works and still wins when both
    /// are given, because agents already installed on this machine pass it.
    private static let importanceProperty: MCPJSON = .object([
        "type": "string",
        "enum": .array(TaskImportance.allCases.map { .string($0.rawValue) }),
        "description": "How much this matters. Default 'normal'."
    ])

    private static let kindProperty: MCPJSON = .object([
        "type": "string",
        "enum": .array(TaskKind.allCases.map { .string($0.rawValue) }),
        "description": "What sort of work this is."
    ])

    private static let labelsProperty: MCPJSON = .object([
        "type": "array",
        "items": .object(["type": "string"]),
        "description": """
            Your own vocabulary, for filtering the board. Lowercased and \
            deduplicated; up to 12.
            """
    ])

    private static let dependsOnProperty: MCPJSON = .object([
        "type": "array",
        "items": .object(["type": "integer"]),
        "description": """
            Task ids that have to be closed before this one can start. A task \
            waiting on unfinished work is not 'ready', and tasks.list with \
            ready_only leaves it out.
            """
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
