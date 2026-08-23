import AgentSessionKit
import AgentSessionLive
import Foundation

// The shapes tool results come back in.
//
// One `Encodable` per answer, encoded once into both the `structuredContent` a
// client can parse and the pretty JSON block a model reads — see
// `MCPJSON.encoder(pretty:)`. Two renderings of one value cannot disagree about
// a field name or a date format, which is the whole reason these are types
// rather than dictionaries built at each call site.
//
// Everything here is already sanitized: the strings came out of the store, and
// everything an agent wrote went through `MCPTextSanitizer` on the way in.
// Nothing carries a transcript, a token, or an absolute path Auspex was not
// already showing on its own board.

// MARK: - Plans and tasks

/// A milestone, as the `plans.*` tools still spell it.
struct PlanPayload: Encodable {
    let id: Int64
    let slug: String
    let title: String
    let summary: String?
    let status: String
    /// The project this milestone is inside, in the board's key space.
    let project: String?
    /// What that project is called on screen.
    let projectName: String?
    let createdAt: Date
    let updatedAt: Date
    let taskCount: Int?
    let openTaskCount: Int?

    init(_ plan: AuspexPlan, tasks: [AuspexTask]? = nil, projectName: String? = nil) {
        self.id = plan.id
        self.slug = plan.slug
        self.title = plan.title
        self.summary = plan.summary
        self.status = plan.status.rawValue
        self.project = plan.projectKey
        self.projectName = projectName
        self.createdAt = plan.createdAt
        self.updatedAt = plan.updatedAt
        self.taskCount = tasks?.count
        self.openTaskCount = tasks?.count { $0.status != .done }
    }
}

struct TaskPayload: Encodable {
    let id: Int64
    /// Compare-and-swap token for the next agent-authored mutation.
    let version: Int64
    /// The handle a person reads and says out loud. Sent so an agent writing a
    /// brief can quote the same string the board shows.
    let shortID: String
    /// The project this task is in — always, for anything this build filed.
    /// The same key `sessions.self` reports for the session working there, so
    /// a caller can compare the two without translating.
    let project: String?
    /// What that project is called on screen.
    let projectName: String?
    /// The milestone it hangs under, when it has one.
    let planID: Int64?
    let title: String
    let body: String?
    let status: String
    let priority: Int
    /// The same number in words — see ``TaskImportance``.
    let importance: String
    /// What sort of work this is, when somebody said.
    let kind: String?
    let labels: [String]?
    /// Task ids that have to be closed before this one can start.
    let dependsOn: [Int64]?
    let claimRole: String?
    let claimScope: String?
    let claimedBy: String?
    let claimedAt: Date?
    let completedAt: Date?
    let result: String?
    let createdAt: Date
    let updatedAt: Date
    let sessions: [String]?
    let pendingClaims: [TaskClaimRequestPayload]?
    /// Present on tasks.claim so a success cannot be mistaken for ownership.
    let claimOutcome: String?

    init(
        _ task: AuspexTask,
        sessions: [SessionKey]? = nil,
        projectName: String? = nil,
        pendingClaims: [TaskClaimRequest] = [],
        claimOutcome: String? = nil
    ) {
        self.id = task.id
        self.version = task.version
        self.shortID = task.shortID
        self.importance = task.importance.rawValue
        self.kind = task.kind?.rawValue
        self.labels = task.labels.isEmpty ? nil : task.labels
        self.dependsOn = task.dependsOn.isEmpty ? nil : task.dependsOn
        self.project = task.projectKey
        self.projectName = projectName
        self.planID = task.planID
        self.title = task.title
        self.body = task.body
        self.status = task.status.rawValue
        self.priority = task.priority
        self.claimRole = task.claimRole
        self.claimScope = task.claimScope
        self.claimedBy = task.claimedBy?.description
        self.claimedAt = task.claimedAt
        self.completedAt = task.completedAt
        self.result = task.result
        self.createdAt = task.createdAt
        self.updatedAt = task.updatedAt
        self.sessions = sessions?.map(\.description)
        self.pendingClaims = pendingClaims.isEmpty
            ? nil : pendingClaims.map(TaskClaimRequestPayload.init)
        self.claimOutcome = claimOutcome
    }
}

struct TaskClaimRequestPayload: Encodable {
    let id: Int64
    let requester: String
    let holder: String?
    let role: String
    let scope: String?
    let reason: String?
    let taskVersion: Int64
    let status: String
    let requestedAt: Date
    let resolvedAt: Date?

    init(_ request: TaskClaimRequest) {
        self.id = request.id
        self.requester = request.requester.description
        self.holder = request.holder?.description
        self.role = request.role
        self.scope = request.scope
        self.reason = request.reason
        self.taskVersion = request.taskVersion
        self.status = request.status.rawValue
        self.requestedAt = request.requestedAt
        self.resolvedAt = request.resolvedAt
    }
}

struct PlanDetailPayload: Encodable {
    let plan: PlanPayload
    let tasks: [TaskPayload]
}

struct PlanListPayload: Encodable {
    let plans: [PlanPayload]
    /// What a caller should do with an empty list, said once rather than
    /// inferred sixteen different ways by sixteen different agents.
    let note: String?
}

struct TaskListPayload: Encodable {
    let tasks: [TaskPayload]
    let note: String?
}

/// The compact task shape used by a project overview and a session capsule.
/// The body and result stay on `tasks.get`; a situation report should remain a
/// situation report rather than turning into a second task detail page.
struct TaskSummaryPayload: Encodable {
    let id: Int64
    let shortID: String
    let title: String
    let status: String
    let importance: String
    let claimedBy: String?
    let claimRole: String?
    let claimScope: String?
    let waitingOn: [Int64]?
    let updatedAt: Date

    init(_ task: AuspexTask, waitingOn: [Int64] = []) {
        self.id = task.id
        self.shortID = task.shortID
        self.title = task.title
        self.status = task.status.rawValue
        self.importance = task.importance.rawValue
        self.claimedBy = task.claimedBy?.description
        self.claimRole = task.claimRole
        self.claimScope = task.claimScope
        self.waitingOn = waitingOn.isEmpty ? nil : waitingOn
        self.updatedAt = task.updatedAt
    }
}

struct TaskLogPayload: Encodable {
    let taskID: Int64
    let version: Int64?
    let entries: [Entry]

    struct Entry: Encodable {
        let at: Date
        let kind: String
        let actor: String?
        let message: String?
        /// Where to go and check, for the entries that carry one.
        let ref: String?

        init(_ entry: AuspexTaskLogEntry) {
            self.at = entry.timestamp
            self.kind = entry.kind
            self.actor = entry.actor?.description
            self.message = entry.message
            self.ref = entry.ref
        }
    }
}

struct TaskDetailPayload: Encodable {
    let task: TaskPayload
    let readiness: Readiness
    let pendingClaims: [TaskClaimRequestPayload]
    /// Claim/release/finish is an execution-attempt audit, not task identity.
    let attempts: [Attempt]
    let history: [TaskLogPayload.Entry]
    let sessions: [LinkedSession]

    struct Readiness: Encodable {
        let ready: Bool
        let dependencies: [Dependency]
        let blocking: [Int64]
    }

    struct Dependency: Encodable {
        let id: Int64
        let shortID: String?
        let title: String?
        let status: String?
        let satisfied: Bool
    }

    struct LinkedSession: Encodable {
        let key: String
        let linkKinds: [String]
        let linkedAt: Date
        let availability: String
        let session: SessionCapsulePayload?
    }

    struct Attempt: Encodable {
        let event: String
        let session: String?
        let at: Date
        let detail: String?

        init(_ entry: AuspexTaskLogEntry) {
            self.event = entry.kind
            self.session = entry.actor?.description
            self.at = entry.timestamp
            self.detail = entry.message
        }
    }
}

// MARK: - Notices and reports

struct NotifyPayload: Encodable {
    let session: String?
    let kind: String
    let message: String
    let urgency: String
    let at: Date
    /// Where the session landed on the board, in the board's own vocabulary.
    let bucket: String
    /// The tasks this notice moved into review, when it was a `done`.
    var reviewing: [Int64]? = nil
    /// Whether Auspex could tell which session this was, and how. A session id
    /// can corroborate the process evidence but cannot replace it.
    let resolved: Bool
    let evidence: String?
    let clearsWhen: String
}

struct ReportPayload: Encodable {
    let session: String?
    let focus: String
    let progress: String?
    let at: Date
    let resolved: Bool
}

/// A persisted self-report as a reader sees it. Reports are not deleted when
/// prose supersedes them: the freshness field makes that distinction explicit
/// without pretending the old line is still the session's present focus.
struct SessionReportPayload: Encodable {
    let focus: String
    let progress: String?
    let reportedAt: Date
    let freshness: String
    let provenance: String

    init(_ report: AgentReport, session: SessionSnapshot) {
        self.focus = report.focus
        self.progress = report.progress
        self.reportedAt = report.createdAt
        self.freshness = report.isSuperseded(byAssistantAt: session.brief.lastAssistantAt)
            ? "superseded" : "current"
        self.provenance = "self_reported"
    }
}

// MARK: - Sessions

struct SessionPayload: Encodable {
    let key: String
    let harness: String
    let title: String?
    let state: String
    let detail: String?
    let isAlive: Bool
    let isStale: Bool
    let project: String?
    let branch: String?
    let cwd: String?
    let parent: String?
    let startedAt: Date?
    let lastEventAt: Date?
    /// What the person asked it to do.
    let assignment: String?
    /// What it is calling for, when it is.
    let notice: NoticePayload?
    /// The last line the agent deliberately filed, even when later prose has
    /// superseded it. `freshness` says which it is.
    let report: SessionReportPayload?

    init(
        _ session: SessionSnapshot,
        project: String?,
        notice: AgentNotice?,
        report: AgentReport? = nil
    ) {
        self.key = session.key.description
        self.harness = session.key.harness.rawValue
        self.title = session.identity.title
        self.state = session.state.columnValue
        self.detail = session.state.detailColumnValue
        self.isAlive = session.isAlive
        self.isStale = session.isStale
        self.project = project
        self.branch = session.identity.gitBranch
        self.cwd = session.identity.cwd
        self.parent = session.identity.parent?.description
        self.startedAt = session.startedAt
        self.lastEventAt = session.lastEventAt
        self.assignment = session.brief.firstPrompt
        self.notice = notice.map(NoticePayload.init)
        self.report = report.map { SessionReportPayload($0, session: session) }
    }
}

struct NoticePayload: Encodable {
    let kind: String
    let message: String
    let urgency: String
    let at: Date

    init(_ notice: AgentNotice) {
        self.kind = notice.kind.rawValue
        self.message = notice.message
        self.urgency = notice.urgency.rawValue
        self.at = notice.createdAt
    }
}

struct SessionListPayload: Encodable {
    let sessions: [SessionCapsulePayload]
    let total: Int
}

/// Safe context another agent may read about a peer.
///
/// No prompt, assistant message, cwd, source path, argv or tool output is in
/// this type. The strings it does carry are names, structured task linkage, or
/// words the session explicitly filed through report/notify.
struct SessionCapsulePayload: Encodable {
    let key: String
    let harness: String
    let title: String?
    let branch: String?
    let startedAt: Date?
    let lastEventAt: Date?
    let activity: Activity
    let attention: Attention?
    let project: Project?
    let report: SessionReportPayload?
    let relationship: Relationship?
    let linkedTasks: LinkedTasks?

    struct Activity: Encodable {
        let state: String
        let detail: String?
        let isAlive: Bool
        let isStale: Bool
        let provenance: String
    }

    struct Attention: Encodable {
        let state: String
        let message: String
        let source: String
        let signalledAt: Date?
        let provenance: String
    }

    struct Project: Encodable {
        let key: String
        let name: String
        let provenance: String
    }

    struct Relationship: Encodable {
        let parent: String?
        let children: [String]?
        let evidence: String?
        let provenance: String
    }

    struct LinkedTasks: Encodable {
        let ids: [Int64]
        let provenance: String
    }

    init(
        _ session: SessionSnapshot,
        board: BoardSnapshot,
        notice: AgentNotice?,
        report: AgentReport?,
        linkedTaskIDs: [Int64] = []
    ) {
        self.key = session.key.description
        self.harness = session.key.harness.rawValue
        self.title = session.identity.title
        self.branch = session.identity.gitBranch
        self.startedAt = session.startedAt
        self.lastEventAt = session.lastEventAt
        self.activity = Activity(
            state: session.state.columnValue,
            detail: session.state.detailColumnValue,
            isAlive: session.isAlive,
            isStale: session.isStale,
            // Activity is a reducer's interpretation of observed events. It is
            // useful, but it is not something the agent asserted as truth.
            provenance: "inferred"
        )

        let attention = TaskLedger.attention(
            of: session, notice: notice, acknowledgedAt: nil, now: board.generatedAt
        )
        switch attention {
        case .none:
            self.attention = nil
        case .needsYou(let message, let source):
            self.attention = Attention(
                state: "needs_you", message: message, source: source.rawValue,
                signalledAt: source == .agent ? notice?.createdAt : session.lastEventAt,
                provenance: source == .agent ? "self_reported" : "observed"
            )
        case .doneReported(let message, let source):
            self.attention = Attention(
                state: "done_reported", message: message, source: source.rawValue,
                signalledAt: source == .agent ? notice?.createdAt : session.lastEventAt,
                provenance: source == .agent ? "self_reported" : "observed"
            )
        }

        if let key = board.projectKey(for: session) {
            self.project = Project(
                key: key,
                name: TaskProject.displayName(forKey: key, in: board),
                provenance: "inferred"
            )
        } else {
            self.project = nil
        }
        self.report = report.map { SessionReportPayload($0, session: session) }

        let children = board.tree.node(for: session.key)?.children.map { $0.key.description } ?? []
        if session.identity.parent != nil || !children.isEmpty {
            let link = session.identity.parentLink
            self.relationship = Relationship(
                parent: session.identity.parent?.description,
                children: children.isEmpty ? nil : children,
                evidence: link.map(Self.parentEvidence),
                provenance: Self.parentProvenance(link)
            )
        } else {
            self.relationship = nil
        }
        let taskIDs = Array(Set(linkedTaskIDs)).sorted()
        self.linkedTasks = taskIDs.isEmpty
            ? nil : LinkedTasks(ids: taskIDs, provenance: "observed")
    }

    private static func parentEvidence(_ link: ParentLink) -> String {
        switch link {
        case .manual: "manual"
        case .subagent: "recorded_subagent"
        case .envInherited: "inherited_environment"
        case .spawnedProcess: "process_ancestry"
        }
    }

    private static func parentProvenance(_ link: ParentLink?) -> String {
        switch link {
        case .manual?, .subagent?: "observed"
        case .envInherited?, .spawnedProcess?, nil: "inferred"
        }
    }
}

struct SessionDetailPayload: Encodable {
    let session: SessionCapsulePayload
    let tasks: [TaskSummaryPayload]
}

struct OverviewPayload: Encodable {
    let project: Project
    let generatedAt: Date
    /// Each array is capped at this many rows; counts remain complete.
    let perSectionLimit: Int
    let `self`: SessionCapsulePayload?
    let doing: [TaskSummaryPayload]
    let blocked: [TaskSummaryPayload]
    let review: [TaskSummaryPayload]
    /// Ready means unclaimed Todo work whose dependencies are closed.
    let ready: [TaskSummaryPayload]
    let orphanedClaims: [TaskSummaryPayload]
    let needsYou: [SessionCapsulePayload]
    let counts: Counts

    struct Project: Encodable {
        let key: String
        let name: String
    }

    struct Counts: Encodable {
        let sessions: Int
        let tasks: Int
        let doing: Int
        let blocked: Int
        let review: Int
        let ready: Int
        let orphanedClaims: Int
        let needsYou: Int
    }
}

struct SelfPayload: Encodable {
    let resolved: Bool
    let session: SessionPayload?
    /// The project key this session's work is filed under — what to pass back
    /// as `project` on `tasks.create`, on the rare occasion it has to be said
    /// out loud.
    var projectKey: String? = nil
    /// How Auspex worked it out, or why it could not.
    let evidence: String
    /// The pid the answer was derived from, so a puzzled agent can check it
    /// against its own process tree.
    let clientPID: Int32?
    /// Tasks this session already holds or is linked to.
    let tasks: [TaskPayload]
}

struct TreeNodePayload: Encodable {
    let key: String
    let harness: String
    let title: String?
    let state: String
    let children: [TreeNodePayload]
}

struct TreePayload: Encodable {
    let roots: [TreeNodePayload]
    let sessionCount: Int
}

struct PeersPayload: Encodable {
    let working: Int
    let idle: Int
    let ended: Int
    /// Sessions blocked on a person: a harness-reported permission prompt, or
    /// an agent that called `auspex.notify` and has not been answered.
    let needsYou: Int
    /// The `auspex.notify` half of `needsYou`, with what each one said.
    let calling: [Caller]
    let total: Int

    struct Caller: Encodable {
        let session: String
        let kind: String
        let message: String
        let at: Date
    }
}
