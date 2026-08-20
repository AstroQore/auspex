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

struct PlanPayload: Encodable {
    let id: Int64
    let slug: String
    let title: String
    let summary: String?
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let taskCount: Int?
    let openTaskCount: Int?

    init(_ plan: AuspexPlan, tasks: [AuspexTask]? = nil) {
        self.id = plan.id
        self.slug = plan.slug
        self.title = plan.title
        self.summary = plan.summary
        self.status = plan.status.rawValue
        self.createdAt = plan.createdAt
        self.updatedAt = plan.updatedAt
        self.taskCount = tasks?.count
        self.openTaskCount = tasks?.count { $0.status != .done }
    }
}

struct TaskPayload: Encodable {
    let id: Int64
    let planID: Int64?
    let title: String
    let body: String?
    let status: String
    let priority: Int
    let claimRole: String?
    let claimScope: String?
    let claimedBy: String?
    let claimedAt: Date?
    let completedAt: Date?
    let result: String?
    let createdAt: Date
    let updatedAt: Date
    let sessions: [String]?

    init(_ task: AuspexTask, sessions: [SessionKey]? = nil) {
        self.id = task.id
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

struct TaskLogPayload: Encodable {
    let taskID: Int64
    let entries: [Entry]

    struct Entry: Encodable {
        let at: Date
        let kind: String
        let actor: String?
        let message: String?

        init(_ entry: AuspexTaskLogEntry) {
            self.at = entry.timestamp
            self.kind = entry.kind
            self.actor = entry.actor?.description
            self.message = entry.message
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
    /// Whether Auspex could tell which session this was, and how. An agent
    /// that reads `resolved: false` knows to pass `session_id` next time.
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

    init(
        _ session: SessionSnapshot,
        project: String?,
        notice: AgentNotice?
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
    let sessions: [SessionPayload]
    let total: Int
}

struct SelfPayload: Encodable {
    let resolved: Bool
    let session: SessionPayload?
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
