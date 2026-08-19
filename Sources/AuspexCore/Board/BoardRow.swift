import AgentSessionKit
import AgentSessionLive
import Foundation

/// One session, reduced to the values a card actually draws.
///
/// ## Why the board does not render `SessionSnapshot`
///
/// A snapshot is the reducer's whole working state: an identity of fifteen
/// optionals, a pending set holding a dictionary of open tool calls and a set
/// of open children, and the list of every child ever spawned. It is the right
/// value to *fold events into* and the wrong one to hand to a view, because
/// SwiftUI compares view values to decide what to re-render — and comparing
/// two snapshots means walking that dictionary, that set, and those fifteen
/// optionals.
///
/// On a board with several hundred sessions that comparison is the single
/// most expensive thing the app does. A profile of the old board is
/// `SessionSnapshot.__derived_struct_equals` most of the way down.
///
/// So the model derives one of these per session per frame — a flat value of
/// scalars, small enums, and strings that were copied by reference out of the
/// snapshot — and the views hold only these. The derivation happens once, on
/// the frame stream, which is already coalesced to about eight frames a
/// second; the comparison then happens in a handful of instructions instead
/// of a tree walk.
///
/// ## What else it buys
///
/// Two questions a card asks used to be answered per card per body: *what is
/// my parent called* was a linear scan of every session on the board, and
/// *how many descendants do I have* was a tree lookup. Both are answered once
/// here, against an index built once per frame, which turns the board's
/// quadratic term into a linear one.
public struct BoardRow: Identifiable, Sendable, Equatable {
    /// Which session this is.
    public let key: SessionKey
    /// Which harness it belongs to.
    public let harness: Harness
    /// The card's headline.
    public let title: String
    /// The first eight characters of the session id.
    public let shortID: String
    /// The harness process, when one was recorded.
    public let pid: pid_t?
    /// The model the session is running, when one was recorded.
    public let modelName: String?
    /// What it is doing.
    public let state: SessionState
    /// Working, but silent for longer than the reducer's patience.
    public let isStale: Bool
    /// The project it groups under.
    public let project: String?
    /// The branch of the checkout it is working in.
    public let branch: String?
    /// Its working directory, already abbreviated to `~` where it can be.
    public let directory: String?
    /// What is happening, in the harness's own words. Never empty.
    public let activity: String
    public let turnCount: Int
    public let toolCallCount: Int
    public let tokensIn: Int
    public let tokensOut: Int
    /// When the interval the card's stopwatch measures began.
    public let elapsedSince: Date?
    /// When the session ended, which is what freezes that stopwatch.
    public let endedAt: Date?
    /// The most recent event, and the cheap thing a diff can key on.
    public let lastEventAt: Date?
    /// How many sessions are below this one, at any depth.
    public let descendantCount: Int
    /// The session that spawned this one, when the board still holds it.
    public let parent: Parent?
    /// How far below its root the tree grouping draws it. `0` everywhere else.
    public let depth: Int
    /// What the person asked this session to do — the first real instruction
    /// in its transcript. `nil` for a session whose store recorded none, or
    /// one Auspex met after the fact.
    public let assignedTask: String?
    /// The most recent instruction, when it says something ``title`` and
    /// ``assignedTask`` do not. `nil` when the assignment is still the whole
    /// story.
    public let latestPrompt: String?
    /// The last thing the model said in prose.
    public let latestAssistant: String?
    /// When a turn last closed. What "done · 12 min ago" is measured from.
    public let lastTurnEndedAt: Date?
    /// `true` when a turn closed after the card was last opened — see
    /// ``TaskLedger/isUnseenDone(state:lastTurnEndedAt:lastSeenAt:isChild:hasAssignment:)``.
    public let isUnseenDone: Bool

    public var id: SessionKey { key }

    /// `true` when the session is over.
    public var isEnded: Bool { state.isEnded }

    /// A link up the delegation chain: enough to draw a chip and to click it.
    public struct Parent: Sendable, Equatable {
        public let key: SessionKey
        public let title: String

        public init(key: SessionKey, title: String) {
            self.key = key
            self.title = title
        }
    }

    public init(
        key: SessionKey,
        harness: Harness,
        title: String,
        shortID: String,
        pid: pid_t?,
        modelName: String?,
        state: SessionState,
        isStale: Bool,
        project: String?,
        branch: String?,
        directory: String?,
        activity: String,
        turnCount: Int,
        toolCallCount: Int,
        tokensIn: Int,
        tokensOut: Int,
        elapsedSince: Date?,
        endedAt: Date?,
        lastEventAt: Date?,
        descendantCount: Int,
        parent: Parent?,
        depth: Int,
        assignedTask: String? = nil,
        latestPrompt: String? = nil,
        latestAssistant: String? = nil,
        lastTurnEndedAt: Date? = nil,
        isUnseenDone: Bool = false
    ) {
        self.key = key
        self.harness = harness
        self.title = title
        self.shortID = shortID
        self.pid = pid
        self.modelName = modelName
        self.state = state
        self.isStale = isStale
        self.project = project
        self.branch = branch
        self.directory = directory
        self.activity = activity
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.elapsedSince = elapsedSince
        self.endedAt = endedAt
        self.lastEventAt = lastEventAt
        self.descendantCount = descendantCount
        self.parent = parent
        self.depth = depth
        self.assignedTask = assignedTask
        self.latestPrompt = latestPrompt
        self.latestAssistant = latestAssistant
        self.lastTurnEndedAt = lastTurnEndedAt
        self.isUnseenDone = isUnseenDone
    }
}

/// One section of the board, as rows.
public struct BoardRowGroup: Identifiable, Sendable, Equatable {
    /// Stable across frames, so SwiftUI keeps section state while the board
    /// churns underneath it.
    public let id: String
    public let title: String
    /// The harness this section is about, when grouping by harness — so a
    /// header can show its accent without re-deriving it from a row.
    public let harness: Harness?
    /// How many of its sessions are believed to be running.
    public let liveCount: Int
    public let rows: [BoardRow]

    public init(id: String, title: String, harness: Harness?, liveCount: Int, rows: [BoardRow]) {
        self.id = id
        self.title = title
        self.harness = harness
        self.liveCount = liveCount
        self.rows = rows
    }
}

/// Turns one frame into rows.
///
/// Built per frame and thrown away. The index it holds is what makes the
/// derivation linear: a card's parent used to be found by scanning every
/// session on the board, once per card, on every body evaluation.
public struct BoardRowBuilder: Sendable {
    private let board: BoardSnapshot
    private let bySession: [SessionKey: SessionSnapshot]
    /// When the person last opened each session. Auspex's own state, held in
    /// memory by the board model and passed in whole, so that deciding whether
    /// a card is unread is a dictionary lookup rather than a query per card.
    private let seenAt: [SessionKey: Date]
    /// Briefs rebuilt from the store, for sessions whose own is still empty.
    ///
    /// A dictionary rather than a lookup, and that is the whole design: a row
    /// is derived on the frame stream, several hundred times per frame, and a
    /// builder that could go to SQLite would be a query on the path that has to
    /// stay off it. The caller derives these once — ``BriefBackfill`` is what
    /// derives them — and passes the same map in every frame, so the cost here
    /// is one hash lookup for a session that has nothing else to show.
    ///
    /// Empty by default. A board whose sessions all carry their own brief never
    /// reads it.
    private let briefs: [SessionKey: SessionBrief]

    public init(
        board: BoardSnapshot,
        seenAt: [SessionKey: Date] = [:],
        briefs: [SessionKey: SessionBrief] = [:]
    ) {
        self.board = board
        var index: [SessionKey: SessionSnapshot] = [:]
        index.reserveCapacity(board.sessions.count)
        for session in board.sessions { index[session.key] = session }
        self.bySession = index
        self.seenAt = seenAt
        self.briefs = briefs
    }

    /// The row for one session.
    public func row(for session: SessionSnapshot, depth: Int = 0) -> BoardRow {
        let project = board.projectKey(for: session).map(BoardGrouping.projectName(forPath:))
        let brief = brief(for: session)
        let title = Self.title(for: session, project: project, brief: brief)
        return BoardRow(
            key: session.key,
            harness: session.key.harness,
            title: title,
            shortID: String(session.key.sessionID.prefix(8)),
            pid: session.identity.pid,
            modelName: session.identity.model,
            state: session.state,
            isStale: session.isStale,
            project: project,
            branch: session.identity.gitBranch,
            directory: session.identity.cwd ?? session.identity.gitRoot,
            activity: Self.activity(for: session),
            turnCount: session.turnCount,
            toolCallCount: session.toolCallCount,
            tokensIn: session.tokensIn,
            tokensOut: session.tokensOut,
            elapsedSince: Self.elapsedSince(for: session),
            endedAt: session.endedAt,
            lastEventAt: session.lastEventAt,
            descendantCount: board.tree.descendants(of: session.key).count,
            parent: parent(of: session),
            depth: depth,
            assignedTask: brief.firstPrompt,
            // The card already carries the assignment on its title line or
            // right under it. Repeating it as "asked:" spends a row of pixels
            // to say the same thing twice.
            latestPrompt: brief.latestPrompt == title ? nil : brief.followUpPrompt,
            latestAssistant: brief.latestAssistant,
            lastTurnEndedAt: brief.lastTurnEndedAt,
            isUnseenDone: TaskLedger.isUnseenDone(
                state: session.state,
                lastTurnEndedAt: brief.lastTurnEndedAt,
                lastSeenAt: seenAt[session.key],
                isChild: TaskLedger.isChild(session.identity),
                hasAssignment: brief.firstPrompt != nil
            )
        )
    }

    /// Rows for a run of sessions, in the order given.
    public func rows(for sessions: [SessionSnapshot]) -> [BoardRow] {
        sessions.map { row(for: $0) }
    }

    /// What this session was asked to do: its own brief, or the one rebuilt
    /// from what the store already held when it has none.
    ///
    /// Only an *empty* brief is substituted. A session the pipeline is folding
    /// events for knows more than any reconstruction can, and a fallback that
    /// second-guessed it would show a stale assignment on a live card.
    func brief(for session: SessionSnapshot) -> SessionBrief {
        guard session.brief.isEmpty, let derived = briefs[session.key] else { return session.brief }
        return derived
    }

    /// The parent's chip, when the board still holds the parent.
    ///
    /// `nil` when it does not: a chip naming a card that is not there would be
    /// a dead link.
    private func parent(of session: SessionSnapshot) -> BoardRow.Parent? {
        guard let key = session.identity.parent, let snapshot = bySession[key] else { return nil }
        if let title = snapshot.identity.title, !title.isEmpty {
            return BoardRow.Parent(key: key, title: title)
        }
        return BoardRow.Parent(key: key, title: String(key.sessionID.prefix(10)))
    }

    /// The headline: what the harness called this session, or what it was
    /// asked to do, or the project it is in, or its own id.
    ///
    /// The assignment sits above the project on purpose. A harness title is a
    /// name somebody — or something — chose for this session; the first
    /// instruction is the closest thing to one when nobody did. A project name
    /// is neither: on a board where five sessions share a checkout it is the
    /// same headline five times, which is a wall a person cannot read.
    ///
    /// Never invented. A session whose store recorded none of the three shows
    /// its own id, which at least identifies it.
    public static func title(for session: SessionSnapshot, project: String?) -> String {
        title(for: session, project: project, brief: session.brief)
    }

    /// The headline, against a brief that may have been rebuilt rather than
    /// folded — see ``brief(for:)``.
    ///
    /// The overload exists so the title and the "asked:" line below it are read
    /// off the *same* brief. A card whose headline came from the session's own
    /// empty brief and whose body came from a reconstructed one would show the
    /// assignment twice, which is the one thing
    /// ``SessionBrief/followUpPrompt`` exists to prevent.
    public static func title(
        for session: SessionSnapshot,
        project: String?,
        brief: SessionBrief
    ) -> String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let task = brief.firstPrompt, !task.isEmpty { return task }
        if let project { return project }
        return String(session.key.sessionID.prefix(12))
    }

    /// What is happening, in the harness's own words.
    static func activity(for session: SessionSnapshot) -> String {
        switch session.state {
        case .toolCalling(let name):
            if let target = session.pending.mostRecentOpenToolCall?.target {
                return "\(name)  \(target)"
            }
            return name
        case .writingFile(let path):
            return path ?? "file"
        case .delegating(let children):
            return children == 1 ? "1 child session" : "\(children) child sessions"
        case .waitingPermission(let tool):
            // A harness that names the tool is asking about *that* call.
            // Grok Bot's roster carries a flag and no tool name, and "a tool"
            // would be inventing one — its bot is waiting on an answer, not on
            // an approval.
            return tool ?? "an answer"
        case .ended(let reason):
            return "exited · \(reason.rawValue)"
        case .idle:
            return "quiet"
        case .thinking:
            return "reasoning"
        }
    }

    /// When the current state began, as precisely as the snapshot allows.
    ///
    /// An open tool call records its own start, which is exact. Everything
    /// else uses the last event, which is exact too — a state change is always
    /// caused by an event — except while a session keeps emitting events that
    /// do not change its state, where it reads as "time since anything
    /// happened". That is the more useful number of the two anyway.
    static func elapsedSince(for session: SessionSnapshot) -> Date? {
        switch session.state {
        case .toolCalling, .writingFile:
            session.pending.mostRecentOpenToolCall?.startedAt ?? session.lastEventAt
        case .ended:
            session.startedAt ?? session.lastEventAt
        default:
            session.lastEventAt ?? session.startedAt
        }
    }
}
