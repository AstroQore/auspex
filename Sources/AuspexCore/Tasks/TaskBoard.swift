import AgentSessionKit
import AgentSessionLive
import Foundation

/// The task ledger's vocabulary: what a milestone is, what a task is, and what
/// an agent said when it asked for a person.
///
/// These are the values the MCP surface hands out and the Tasks board draws.
/// They are deliberately flat and `Codable`: one tool result and one SwiftUI
/// row read the same struct, so a field the board shows is a field an agent
/// can ask for.
///
/// ## One containment hierarchy
///
/// **Project ⊃ Task ⊃ Sessions.** A project is the one top-level container —
/// resolved from where the work is happening (git root, working directory, a
/// folder a person claimed) by the same
/// ``BoardSnapshot/projectKey(for:)`` every other surface asks. Every task
/// belongs to exactly one project, always: a task filed by an agent that named
/// no project is filed under the project *that agent is working in*, which is
/// the whole of what "Unfiled" used to mean and was never true.
///
/// A milestone is a *label inside* a project rather than a second root. It is
/// optional, it groups tasks under a sub-heading, and archiving one leaves its
/// tasks exactly where they are. It is still called ``AuspexPlan`` in code and
/// still reached through the `plans.*` tools, because agents already installed
/// on this machine hold that vocabulary in their briefs.

// MARK: - Milestones

/// A named stage inside a project: the optional parent of a set of tasks.
///
/// Registered by whoever *hands work out* — a supervisor splitting a job,
/// or a person building a board by hand — rather than by each worker in turn.
/// N workers each classifying themselves produce N vocabularies; one
/// orchestrator writing the decomposition down produces one.
///
/// Not a container in its own right: the container is the project. A milestone
/// that outlives its tasks is a heading with nothing under it, and a task whose
/// milestone is archived is still somebody's job in some project.
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
    /// The project this milestone is inside, in the board's own key space —
    /// see ``BoardSnapshot/projectKey(for:)``.
    ///
    /// The same string the wall's sections, the sidebar's rows and a task's
    /// ``AuspexTask/projectKey`` use, because a milestone that named its
    /// project differently from the tasks under it would be a second key space
    /// and a second set of bugs. `nil` only for a milestone registered before
    /// its first task, which takes the project of that task.
    public let projectKey: String?
    /// The session that registered it, when an agent did.
    public let createdBy: SessionKey?
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?

    /// Whether the milestone is still being worked on.
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
        projectKey: String? = nil,
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
        self.projectKey = projectKey
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

// MARK: - Tasks

/// Where a task sits on the board.
///
/// Five columns, and the interesting one is the fourth. An agent that says it
/// finished has not closed anything: it has *asked to be checked*, which is a
/// different claim and one only a person can answer. So `tasks.complete` and
/// `auspex.notify(done)` both land a task in ``review``, where it stays —
/// counted, coloured, and on the board — until somebody closes it.
///
/// That is the same thing the ledger already called "done, reported, nobody has
/// read it"; naming it Review is what makes the column, the chip, and the card
/// agree about it, and what stops `done` meaning two things at once.
public enum AuspexTaskStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case todo
    case doing
    case blocked
    /// Finished by whoever did it, and waiting on a person to agree.
    case review
    /// Closed by a person.
    case done

    /// The column heading.
    public var label: String {
        switch self {
        case .todo: "To do"
        case .doing: "Doing"
        case .blocked: "Blocked"
        case .review: "Review"
        case .done: "Done"
        }
    }

    /// Board order, left to right.
    public var rank: Int {
        switch self {
        case .todo: 0
        case .doing: 1
        case .blocked: 2
        case .review: 3
        case .done: 4
        }
    }

    /// Whether the task is still somebody's job.
    ///
    /// `review` counts as open: the work is done and the *task* is not, because
    /// nobody has looked at it. A count of open tasks that dropped a task the
    /// moment its worker declared victory would be the one number on the board
    /// an agent could move on its own.
    public var isOpen: Bool { self != .done }

    /// Whether a person is what this task is waiting for.
    public var wantsPerson: Bool {
        switch self {
        case .blocked, .review: true
        case .todo, .doing, .done: false
        }
    }
}

// MARK: - Importance, kind, labels

/// How much a task matters, in the four steps a person can actually tell
/// apart.
///
/// Stored as ``AuspexTask/priority`` — an `Int` the ledger has always had —
/// rather than as a second column, so an orchestrator that has been passing
/// `priority: 3` keeps working and reads as `urgent` on the board. The enum is
/// what the *UI* is allowed to know: four icons, four words, one order.
public enum TaskImportance: String, Codable, Sendable, CaseIterable, Hashable {
    case low
    case normal
    case important
    case urgent

    /// The word on the chip.
    public var label: String {
        switch self {
        case .low: "low"
        case .normal: "normal"
        case .important: "important"
        case .urgent: "urgent"
        }
    }

    /// The stored priority this importance is written as.
    public var priority: Int {
        switch self {
        case .low: -1
        case .normal: 0
        case .important: 2
        case .urgent: 4
        }
    }

    /// Which band a stored priority falls in.
    public init(priority: Int) {
        switch priority {
        case ..<0: self = .low
        case 0: self = .normal
        case 1...2: self = .important
        default: self = .urgent
        }
    }

    /// Sort order: the loudest first.
    public var rank: Int {
        switch self {
        case .urgent: 0
        case .important: 1
        case .normal: 2
        case .low: 3
        }
    }

    /// Whether the board draws a mark for it at all.
    ///
    /// `normal` does not. A chip on every row is a chip nobody reads, and the
    /// great majority of tasks are ordinary.
    public var isMarked: Bool { self != .normal }
}

/// What kind of work a task is.
///
/// Four, and they are the four a person sorts a backlog by. Free text would
/// have been kinder to the agent filing it and useless to the person reading
/// it: a filter over "feature | feat | enhancement | new" filters nothing.
public enum TaskKind: String, Codable, Sendable, CaseIterable, Hashable {
    case feature
    case fix
    case chore
    case research

    public var label: String { rawValue }

    /// The spellings an agent might reach for, folded onto the four.
    ///
    /// Generous on the way in and strict on the way out, which is the only
    /// way a vocabulary survives contact with a dozen orchestrators.
    public init?(loose raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "feature", "feat", "enhancement", "new": self = .feature
        case "fix", "bug", "bugfix", "defect", "hotfix": self = .fix
        case "chore", "task", "maintenance", "refactor", "docs", "build": self = .chore
        case "research", "spike", "investigation", "study", "explore": self = .research
        default: return nil
        }
    }
}

/// What one line of a task's history *is*.
///
/// The log has always carried a `kind`, and the ledger's own entries —
/// `created`, `claimed`, `status`, `completed`, `linked` — use it to say what
/// happened. These four are what an *agent* is allowed to say, and they are
/// the difference between a work log and a chat transcript: a decision is
/// something a later reader must not silently undo, evidence is something they
/// can go and check, and a risk is something nobody has dealt with yet.
public enum TaskNoteKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A choice was made, and this is what it was.
    case decision
    /// Something was checked, and here is where to look — see
    /// ``AuspexTaskLogEntry/ref``.
    case evidence
    /// Something that could still go wrong.
    case risk
    /// Everything else worth writing down.
    case note

    public var label: String { rawValue }

    /// Whether the entry is one an agent wrote rather than one the ledger
    /// recorded about itself.
    public static func isNote(_ kind: String) -> Bool {
        TaskNoteKind(rawValue: kind) != nil
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
    /// The milestone it hangs under, when it has one. A task without a
    /// milestone is the ordinary case — somebody filed one thing — and shows
    /// under its project with no sub-heading rather than in a lane of orphans.
    public let planID: Int64?
    public let title: String
    public let body: String?
    public let status: AuspexTaskStatus
    /// Higher sorts first within a column. Zero unless somebody set it.
    public let priority: Int
    public let projectID: Int64?
    /// The project this task is in, in the board's own key space — a git root,
    /// a working directory, a folder a person claimed, or a
    /// ``PseudoProject`` key for a harness that has no directory at all.
    ///
    /// Never `nil` for a task filed by this build: `tasks.create` resolves the
    /// caller's project before it writes the row, so there is no such thing as
    /// an unfiled task. It stays optional for the rows written before there
    /// was a project column and for a store whose migration could find no
    /// session to resolve one from.
    public let projectKey: String?
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
    /// What kind of work this is. `nil` when nobody said, which is most tasks
    /// — an inferred kind would be a chip that is wrong on half the board.
    public let kind: TaskKind?
    /// Free-text labels, in the order they were given. Deduplicated and capped
    /// on the way in; the vocabulary is the orchestrator's.
    public let labels: [String]
    /// The tasks that have to be closed before this one is ready to start.
    ///
    /// Ids rather than a graph object: a dependency is a fact about two rows,
    /// and the readers that care — "is this ready", "what is it waiting on" —
    /// both want the list rather than the closure.
    public let dependsOn: [Int64]
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
        projectKey: String? = nil,
        createdBy: SessionKey?,
        claimRole: String?,
        claimScope: String?,
        claimedBy: SessionKey?,
        claimedAt: Date?,
        completedAt: Date?,
        result: String?,
        source: String?,
        kind: TaskKind? = nil,
        labels: [String] = [],
        dependsOn: [Int64] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.kind = kind
        self.labels = labels
        self.dependsOn = dependsOn
        self.id = id
        self.planID = planID
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.projectID = projectID
        self.projectKey = projectKey
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

    /// The short handle a person reads and says out loud — `AUX-3f9k`.
    ///
    /// Derived from the id rather than stored, so it exists for every row the
    /// ledger has ever written and cannot drift from the row it names. See
    /// ``TaskShortID``.
    public var shortID: String { TaskShortID.forTask(id) }

    /// How much this matters, as the board draws it.
    public var importance: TaskImportance { TaskImportance(priority: priority) }

    /// Whether anybody is holding this task.
    public var isClaimed: Bool { claimedBy != nil || claimRole != nil }

    /// Whether every task this one waits on is closed.
    ///
    /// - Parameter closed: the ids of the tasks that are `done`. A dependency
    ///   on a task the ledger no longer holds is treated as *satisfied*: a
    ///   deleted row is not a reason to strand the work that referenced it.
    public func isReady(closed: Set<Int64>, known: Set<Int64>) -> Bool {
        dependsOn.allSatisfy { closed.contains($0) || !known.contains($0) }
    }

    /// The dependencies that are still open, in the order they were given.
    public func blockingDependencies(closed: Set<Int64>, known: Set<Int64>) -> [Int64] {
        dependsOn.filter { known.contains($0) && !closed.contains($0) }
    }

    /// The same task, in another column.
    ///
    /// For the optimistic redraw a drag needs: the person dropped the card on
    /// this frame and the board should show it on this frame, rather than one
    /// store round trip later.
    public func moved(to status: AuspexTaskStatus, at date: Date = Date()) -> AuspexTask {
        AuspexTask(
            id: id, planID: planID, title: title, body: body, status: status,
            priority: priority, projectID: projectID, projectKey: projectKey,
            createdBy: createdBy, claimRole: claimRole, claimScope: claimScope,
            claimedBy: claimedBy, claimedAt: claimedAt,
            // The stamp is when the *work* finished. Moving a card into Review
            // or Done does not restamp it, and moving it back out clears it —
            // the same rule the store applies.
            completedAt: status == .done || status == .review ? (completedAt ?? date) : nil,
            result: result, source: source, kind: kind, labels: labels,
            dependsOn: dependsOn, createdAt: createdAt, updatedAt: date
        )
    }

    /// The same task, with its dependencies filled in.
    ///
    /// The row decoder cannot fetch them — an edge lives in another table —
    /// so the repository decodes the row and then attaches, in one query for a
    /// whole page of tasks rather than one per row.
    public func withDependencies(_ ids: [Int64]) -> AuspexTask {
        AuspexTask(
            id: id, planID: planID, title: title, body: body, status: status,
            priority: priority, projectID: projectID, projectKey: projectKey,
            createdBy: createdBy, claimRole: claimRole, claimScope: claimScope,
            claimedBy: claimedBy, claimedAt: claimedAt, completedAt: completedAt,
            result: result, source: source, kind: kind, labels: labels,
            dependsOn: ids, createdAt: createdAt, updatedAt: updatedAt
        )
    }

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
    /// `created`, `claimed`, `status`, `completed`, `linked` — what the ledger
    /// recorded — or one of ``TaskNoteKind``'s four, which is what an agent
    /// wrote.
    public let kind: String
    /// The line itself.
    public let message: String?
    /// Where to go and check: a commit, a URL, a path.
    ///
    /// Carried on evidence most of the time and allowed on any note, because a
    /// decision worth recording usually has a diff behind it. Sanitized and
    /// capped like every other agent-supplied string.
    public let ref: String?

    public init(
        id: Int64,
        taskID: Int64,
        timestamp: Date,
        actor: SessionKey?,
        kind: String,
        message: String?,
        ref: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.actor = actor
        self.kind = kind
        self.message = message
        self.ref = ref
    }

    /// The note kind, when this entry is one an agent wrote.
    public var noteKind: TaskNoteKind? { TaskNoteKind(rawValue: kind) }
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
