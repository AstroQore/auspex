import AgentSessionKit
import AgentSessionLive
import Foundation

/// The task ledger's vocabulary: what a plan is, what a task is, and what an
/// agent said when it asked for a person.
///
/// These are the values the MCP surface hands out and the Tasks board draws.
/// They are deliberately flat and `Codable`: one tool result and one SwiftUI
/// row read the same struct, so a field the board shows is a field an agent
/// can ask for.

// MARK: - Plans

/// A decomposition somebody registered: the parent of a set of tasks.
///
/// Registered by whoever *hands work out* — a supervisor splitting a job,
/// or a person building a board by hand — rather than by each worker in turn.
/// N workers each classifying themselves produce N vocabularies; one
/// orchestrator writing the plan down produces one.
public struct AuspexPlan: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    /// A short stable handle an agent can pass in a brief instead of a number.
    /// Derived from the title when the caller does not supply one.
    public let slug: String
    public let title: String
    /// One paragraph of what the plan is for. Optional, and capped like every
    /// other agent-supplied string.
    public let summary: String?
    public let status: Status
    /// The project the plan belongs to, when one was resolved.
    public let projectID: Int64?
    /// The session that registered it, when an agent did.
    public let createdBy: SessionKey?
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?

    /// Whether the plan is still being worked on.
    public enum Status: String, Codable, Sendable, CaseIterable, Hashable {
        case active
        case archived
    }

    public init(
        id: Int64,
        slug: String,
        title: String,
        summary: String?,
        status: Status,
        projectID: Int64?,
        createdBy: SessionKey?,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date?
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.summary = summary
        self.status = status
        self.projectID = projectID
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

// MARK: - Tasks

/// Where a task sits on the board.
///
/// Four columns, and the fourth is not "closed": a task that a person still
/// has to read is exactly the thing this app exists to surface, so `done`
/// stays on the board and the ledger decides how loudly.
public enum AuspexTaskStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case todo
    case doing
    case blocked
    case done

    /// The column heading.
    public var label: String {
        switch self {
        case .todo: "To do"
        case .doing: "Doing"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    /// Board order, left to right.
    public var rank: Int {
        switch self {
        case .todo: 0
        case .doing: 1
        case .blocked: 2
        case .done: 3
        }
    }
}

/// One unit of assigned work.
///
/// A task is what a brief is *about*. An orchestrator creates it, writes its
/// id into the brief it hands a worker, and the worker claims it with a role
/// and a scope — two strings that answer "who are you on this task" and "which
/// part of it is yours", which is the whole of what a person scanning a board
/// of twelve sessions needs from a row.
public struct AuspexTask: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    /// The plan it hangs under, when it has one. A task without a plan is
    /// legitimate — somebody filed one thing — and shows in an "unfiled" lane.
    public let planID: Int64?
    public let title: String
    public let body: String?
    public let status: AuspexTaskStatus
    /// Higher sorts first within a column. Zero unless somebody set it.
    public let priority: Int
    public let projectID: Int64?
    /// The session that filed the task.
    public let createdBy: SessionKey?
    /// What the claimer said it is: `implementer`, `reviewer`, `researcher`…
    /// Free text, because the vocabulary is the orchestrator's, not ours.
    public let claimRole: String?
    /// Which part of the task the claimer took.
    public let claimScope: String?
    /// The session holding the claim.
    public let claimedBy: SessionKey?
    public let claimedAt: Date?
    public let completedAt: Date?
    /// What the worker said it finished. The line a person reads instead of
    /// opening the transcript.
    public let result: String?
    /// How the task got here: `mcp`, `ui`, or whatever a later ingress calls
    /// itself.
    public let source: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64,
        planID: Int64?,
        title: String,
        body: String?,
        status: AuspexTaskStatus,
        priority: Int,
        projectID: Int64?,
        createdBy: SessionKey?,
        claimRole: String?,
        claimScope: String?,
        claimedBy: SessionKey?,
        claimedAt: Date?,
        completedAt: Date?,
        result: String?,
        source: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.projectID = projectID
        self.createdBy = createdBy
        self.claimRole = claimRole
        self.claimScope = claimScope
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.result = result
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether anybody is holding this task.
    public var isClaimed: Bool { claimedBy != nil || claimRole != nil }

    /// The one line a row shows under the title: who took it and for what.
    public var claimDescription: String? {
        switch (claimRole, claimScope) {
        case let (role?, scope?): "\(role) · \(scope)"
        case let (role?, nil): role
        case let (nil, scope?): scope
        case (nil, nil): nil
        }
    }
}

/// Why a session is attached to a task.
public enum AuspexTaskLinkKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// The session claimed the task.
    case claim
    /// A person dragged the session onto it, or used "Link to task…".
    case manual
    /// The session descends from one that claimed the task.
    case inherited

    public var label: String {
        switch self {
        case .claim: "claimed"
        case .manual: "linked"
        case .inherited: "under claimer"
        }
    }
}

/// One session attached to one task.
public struct AuspexTaskLink: Hashable, Sendable, Codable {
    public let taskID: Int64
    public let session: SessionKey
    public let kind: AuspexTaskLinkKind
    public let createdAt: Date

    public init(taskID: Int64, session: SessionKey, kind: AuspexTaskLinkKind, createdAt: Date) {
        self.taskID = taskID
        self.session = session
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// One line of a task's history.
public struct AuspexTaskLogEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public let taskID: Int64
    public let timestamp: Date
    /// Who wrote it, when a session did.
    public let actor: SessionKey?
    /// `created`, `claimed`, `status`, `note`, `completed`, `linked`…
    public let kind: String
    /// The line itself.
    public let message: String?

    public init(
        id: Int64,
        taskID: Int64,
        timestamp: Date,
        actor: SessionKey?,
        kind: String,
        message: String?
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.actor = actor
        self.kind = kind
        self.message = message
    }
}

// MARK: - Notices

/// What an agent called a person about.
///
/// The four are the whole vocabulary on purpose. An agent that has to choose
/// between fifteen kinds chooses badly and inconsistently; a person scanning a
/// board wants to know only whether they have to *do* something, *read*
/// something, or neither.
public enum AgentNoticeKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// It asked a question and is going nowhere until it is answered.
    case needsInput = "needs_input"
    /// It finished something it wants looked at before it goes on.
    case needsReview = "needs_review"
    /// It hit something it cannot get past.
    case blocked
    /// It finished, and here is what it did.
    case done

    /// The words the card, the notification, and the menu bar all use.
    public var label: String {
        switch self {
        case .needsInput: "needs input"
        case .needsReview: "needs review"
        case .blocked: "blocked"
        case .done: "done"
        }
    }

    /// Whether a person has to act before the session moves again.
    ///
    /// `needsReview` counts: an agent that stopped to be checked is stopped.
    /// `done` does not — it is finished work to read, which the ledger already
    /// has a bucket for.
    public var wantsPerson: Bool {
        switch self {
        case .needsInput, .needsReview, .blocked: true
        case .done: false
        }
    }
}

/// How loud the agent thinks this is.
///
/// Advisory. It changes the notification's interruption level and nothing
/// about where the card lands: an agent that marks everything urgent must not
/// be able to reorder somebody else's board.
public enum AgentNoticeUrgency: String, Codable, Sendable, CaseIterable, Hashable {
    case low
    case normal
    case high
}

/// One live call for a person, as the board holds it.
///
/// Auspex's own state, like `session_views` — not a projection of any
/// harness's — so it lives in its own table and outlives the session row that
/// retention may drop.
public struct AgentNotice: Hashable, Sendable, Codable {
    public let session: SessionKey
    public let kind: AgentNoticeKind
    /// What the agent said, sanitized and capped before it ever got here.
    public let message: String
    public let urgency: AgentNoticeUrgency
    public let createdAt: Date
    /// When it stopped being live — the person answered, or dismissed it.
    public let clearedAt: Date?

    public init(
        session: SessionKey,
        kind: AgentNoticeKind,
        message: String,
        urgency: AgentNoticeUrgency = .normal,
        createdAt: Date,
        clearedAt: Date? = nil
    ) {
        self.session = session
        self.kind = kind
        self.message = message
        self.urgency = urgency
        self.createdAt = createdAt
        self.clearedAt = clearedAt
    }

    /// Whether it is still asking.
    public var isLive: Bool { clearedAt == nil }

    /// Whether the person's next prompt has already answered it.
    ///
    /// The auto-clear rule, in one place so the board and the store agree: a
    /// person who has typed into that session's terminal since the call was
    /// made has dealt with it, whatever the call was. A question has been
    /// answered, a block has been unblocked or overtaken, and a receipt has
    /// been read by somebody who then asked for the next thing.
    ///
    /// It is the one clearing gesture that happens where the *work* is rather
    /// than where the board is, which is why it matters: nobody should have to
    /// visit Auspex to tell it something they have already told the agent.
    public func isAnswered(byPromptAt promptAt: Date?) -> Bool {
        guard let promptAt else { return false }
        return promptAt > createdAt
    }
}

/// One line an agent wrote about what it is doing right now.
///
/// Overrides the card's inferred "said" line until the next assistant text
/// arrives, and is marked as self-reported so nobody mistakes it for
/// something Auspex observed.
public struct AgentReport: Hashable, Sendable, Codable {
    public let session: SessionKey
    /// "Rewriting the tailer's cursor handling".
    public let focus: String
    /// "step 2 of 5", "40%", whatever the agent counts in. Free text because
    /// the shapes are not comparable across harnesses anyway.
    public let progress: String?
    public let createdAt: Date

    public init(session: SessionKey, focus: String, progress: String?, createdAt: Date) {
        self.session = session
        self.focus = focus
        self.progress = progress
        self.createdAt = createdAt
    }

    /// The line a card draws, with the progress folded in.
    public var line: String {
        guard let progress, !progress.isEmpty else { return focus }
        return "\(focus) · \(progress)"
    }

    /// Whether the session has said something in prose since this was written,
    /// which is what puts the observed line back.
    public func isSuperseded(byAssistantAt assistantAt: Date?) -> Bool {
        guard let assistantAt else { return false }
        return assistantAt > createdAt
    }
}
