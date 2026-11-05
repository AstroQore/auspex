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
    /// Which flavour of its harness this is, in one word, when that is
    /// something a reader needs — `auto review`, `cli`, `ide`. `nil` for the
    /// great majority of sessions; see ``SessionVariantLabel``.
    public let variantLabel: String?
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
    /// What the open tool call is aimed at — the command, the path, the query
    /// — while the session is calling a tool or waiting for permission to.
    ///
    /// Its own field rather than read back out of ``activity``, because a
    /// permission wait's activity is the tool's name alone and the one thing a
    /// person deciding whether to get up wants is *which* `Bash`.
    public let toolTarget: String?
    public let turnCount: Int
    public let toolCallCount: Int
    public let tokensIn: Int
    public let tokensOut: Int
    /// How full the context window is, for the harnesses whose stores record
    /// it. `nil` for the five that record nothing — see ``ContextGauge``.
    ///
    /// A *level*, unlike the two counters above it, which is the reason it is
    /// a value of its own rather than two more `Int`s: the card draws a fill
    /// against a window, and a total has no window to be a fraction of.
    public let context: ContextGauge?
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
    /// When a turn last closed. What "replied · 12 min ago" is measured from.
    public let lastTurnEndedAt: Date?
    /// `true` when the session is idle, the agent spoke last, and nobody has
    /// opened the card since — see
    /// ``TaskLedger/isQuietReply(state:lastTurnEndedAt:lastSeenAt:isChild:hasAssignment:)``.
    ///
    /// A dot on this card and nothing more. It is inferred, so it is counted
    /// nowhere and notified never; the two buckets a header counts come from
    /// ``attention``.
    public let isQuietReply: Bool
    /// Whether a person has something to do about this session, and why.
    ///
    /// Derived once per frame from every explicit source at once — the agent's
    /// `auspex.notify`, a `PermissionRequest` hook, a harness's own permission
    /// wait — so the card, the chip that counts it, and the seat it takes in
    /// the scene cannot disagree.
    public let attention: AttentionState
    /// What the agent itself said it needs, when it called for a person
    /// through `auspex.notify`.
    ///
    /// The only field on a row an *agent* wrote. Everything else is observed,
    /// and the card marks the difference — because "Auspex thinks this session
    /// is idle" and "this session says it is waiting for you" are different
    /// claims and a person acts on them differently.
    public let notice: RowNotice?
    /// The line the agent wrote about what it is doing, while it is still the
    /// most recent thing it said.
    ///
    /// Overrides the observed "said" line. `nil` once the session has spoken
    /// in prose again, because an observation newer than a report is better
    /// than the report.
    public let reportedFocus: String?
    /// When the active self-report was written.
    ///
    /// Kept beside the flattened line so catch-up can distinguish a semantic
    /// report from ordinary transcript churn without reaching back into the
    /// report store on every frame.
    public let reportedFocusAt: Date?

    public var id: SessionKey { key }

    /// Whether a person has to do something before this session moves.
    public var needsPerson: Bool { attention.wantsPerson }

    /// Whether an agent has reported finishing something here.
    public var isDoneReported: Bool { attention.isDoneReported }

    /// One agent's call for a person, flattened for the card.
    public struct RowNotice: Sendable, Equatable {
        public let kind: AgentNoticeKind
        public let message: String
        public let urgency: AgentNoticeUrgency
        public let at: Date

        public init(kind: AgentNoticeKind, message: String, urgency: AgentNoticeUrgency, at: Date) {
            self.kind = kind
            self.message = message
            self.urgency = urgency
            self.at = at
        }

        public init(_ notice: AgentNotice) {
            self.init(
                kind: notice.kind,
                message: notice.message,
                urgency: notice.urgency,
                at: notice.createdAt
            )
        }
    }

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
        variantLabel: String? = nil,
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
        isQuietReply: Bool = false,
        attention: AttentionState = .none,
        notice: RowNotice? = nil,
        reportedFocus: String? = nil,
        reportedFocusAt: Date? = nil,
        context: ContextGauge? = nil,
        toolTarget: String? = nil
    ) {
        self.toolTarget = toolTarget
        self.variantLabel = variantLabel
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
        self.isQuietReply = isQuietReply
        self.attention = attention
        self.notice = notice
        self.reportedFocus = reportedFocus
        self.reportedFocusAt = reportedFocusAt
        self.context = context
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
    /// What agents have called for, by session. The only agent-authored input
    /// to a row; passed in whole for the same reason `seenAt` is.
    private let notices: [SessionKey: AgentNotice]
    /// What agents said they are doing.
    private let reports: [SessionKey: AgentReport]
    /// When the person last cleared each session's attention — opened its
    /// card, dismissed the call, or marked everything seen.
    private let acknowledgedAt: [SessionKey: Date]
    /// The instant every row's attention is derived against, so the age-out is
    /// a property of the frame rather than of the wall clock.
    private let now: Date

    public init(
        board: BoardSnapshot,
        seenAt: [SessionKey: Date] = [:],
        briefs: [SessionKey: SessionBrief] = [:],
        notices: [SessionKey: AgentNotice] = [:],
        reports: [SessionKey: AgentReport] = [:],
        acknowledgedAt: [SessionKey: Date] = [:],
        now: Date? = nil
    ) {
        self.board = board
        self.acknowledgedAt = acknowledgedAt
        self.now = now ?? board.generatedAt
        var index: [SessionKey: SessionSnapshot] = [:]
        index.reserveCapacity(board.sessions.count)
        for session in board.sessions { index[session.key] = session }
        self.bySession = index
        self.seenAt = seenAt
        self.briefs = briefs
        self.notices = notices
        self.reports = reports
    }

    /// The row for one session.
    public func row(for session: SessionSnapshot, depth: Int = 0) -> BoardRow {
        // The chip under the title says *where*: the project, or Projectless.
        // A scratch thread's folder — `zhe` — is not a project and not a
        // heading; it is the row's directory, which the row carries anyway.
        let key = board.projectKey(for: session)
        let project = key.map(BoardGrouping.projectName(forPath:))
        let brief = brief(for: session)
        let title = Self.title(
            for: session,
            // "Projectless" is a section, not a name for what a session did:
            // a row titled with it would say its heading again.
            project: key.map(PseudoProject.isProjectless) == true ? nil : project,
            brief: brief,
            now: now
        )
        let notice = notices[session.key]
        // A report is a claim about *now*. Once the session has spoken in
        // prose again, the observation is newer than the claim and wins.
        let report = reports[session.key]
            .flatMap { $0.isSuperseded(byAssistantAt: brief.lastAssistantAt) ? nil : $0 }
        return BoardRow(
            key: session.key,
            harness: session.key.harness,
            title: title,
            shortID: String(session.key.sessionID.prefix(8)),
            pid: session.identity.pid,
            modelName: session.identity.model,
            variantLabel: SessionVariantLabel.label(for: session.identity),
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
            isQuietReply: TaskLedger.isQuietReply(
                state: session.state,
                lastTurnEndedAt: brief.lastTurnEndedAt,
                lastSeenAt: seenAt[session.key],
                isChild: TaskLedger.isChild(session.identity),
                hasAssignment: brief.firstPrompt != nil
            ),
            attention: attention(for: session, brief: brief, notice: notice),
            notice: notice.map(BoardRow.RowNotice.init),
            reportedFocus: report?.line,
            reportedFocusAt: report?.createdAt,
            context: ContextGauge(
                usage: session.contextUsage, compactions: session.compactions
            ),
            toolTarget: Self.toolTarget(for: session)
        )
    }

    /// Rows for a run of sessions, in the order given.
    public func rows(for sessions: [SessionSnapshot]) -> [BoardRow] {
        sessions.map { row(for: $0) }
    }

    /// What one session is signalling, if anything.
    ///
    /// Public so the assembler can answer for every session on the frame
    /// without building a row for each — a row walks the delegation forest to
    /// count descendants, which is the expensive half — while still going
    /// through *this* builder, so the map and the cards it is drawn beside
    /// cannot disagree about which brief they read.
    public func attention(for session: SessionSnapshot) -> AttentionState {
        attention(for: session, brief: brief(for: session), notice: notices[session.key])
    }

    private func attention(
        for session: SessionSnapshot,
        brief: SessionBrief,
        notice: AgentNotice?
    ) -> AttentionState {
        AttentionState.derive(
            state: session.state,
            notice: notice,
            acknowledgedAt: acknowledgedAt[session.key],
            // The brief the *card* is drawing, not the session's own: a row
            // rebuilt from the store has to agree with the line above it about
            // when the person last spoke here.
            lastPromptAt: brief.lastPromptAt,
            lastEventAt: session.lastEventAt,
            now: now
        )
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
        // The parent's own headline, by the same ladder its card climbs — a
        // chip naming a session by its id names nothing a reader can find.
        let projectKey = board.projectKey(for: snapshot)
        let project = projectKey.map(PseudoProject.isProjectless) == true
            ? nil : projectKey.map(BoardGrouping.projectName(forPath:))
        let title = Self.title(for: snapshot, project: project, brief: brief(for: snapshot), now: now)
        return BoardRow.Parent(key: key, title: title)
    }

    /// The headline: what the harness called this session, or the first line
    /// of what it was asked to do, or the project it is in, or which harness
    /// it is and when it started.
    ///
    /// The assignment sits above the project on purpose. A harness title is a
    /// name somebody — or something — chose for this session; the first
    /// instruction is the closest thing to one when nobody did. A project name
    /// is neither: on a board where five sessions share a checkout it is the
    /// same headline five times, which is a wall a person cannot read.
    ///
    /// **Never an id.** A harness that titles a thread with its own UUID has
    /// not named it, so such a title is skipped like an empty one — see
    /// ``isIdentifier(_:of:)``. A session with nothing at all to go on is
    /// "Codex · 14:32": which harness, and when it started, which together
    /// find it in a list in a way `01a18c9c-92c` never did. The id is still
    /// on the card and in the trace header, where it is a fact rather than a
    /// headline.
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
    ///
    /// - Parameter now: the frame's instant, which decides whether the last
    ///   rung needs a date beside its time. `nil` always writes the date.
    public static func title(
        for session: SessionSnapshot,
        project: String?,
        brief: SessionBrief,
        now: Date? = nil
    ) -> String {
        if let title = session.identity.title, !title.isEmpty, !isIdentifier(title, of: session) {
            return title
        }
        if let headline = headline(of: brief.firstPrompt) { return headline }
        if let project, !project.isEmpty { return project }
        return fallbackTitle(
            harness: session.key.harness,
            at: session.startedAt ?? session.lastEventAt,
            now: now
        )
    }

    /// The longest prompt headline, in characters, before it is cut.
    public static let headlineLimit = 60

    /// The first line of a prompt with anything in it, cut to
    /// ``headlineLimit`` characters — `nil` for a prompt that is all
    /// whitespace or absent.
    ///
    /// One pass that stops as soon as the headline is known, because it runs
    /// for every row on every frame and a prompt can be a pasted file: what it
    /// costs is bounded by the headline, not by the prompt.
    public static func headline(of prompt: String?) -> String? {
        guard let prompt, !prompt.isEmpty else { return nil }
        var line = ""
        var kept = 0
        var looked = 0
        for character in prompt {
            looked += 1
            // A prompt that opens with this much blank space has no headline
            // worth the scan.
            if looked > 4_096 { break }
            if character.isNewline {
                if kept > 0 { break }
                continue
            }
            if kept == 0, character.isWhitespace { continue }
            line.append(character)
            kept += 1
            if kept > headlineLimit { break }
        }
        guard kept > 0 else { return nil }
        guard kept > headlineLimit else { return trimmingTrailingSpace(line) }
        return trimmingTrailingSpace(String(line.prefix(headlineLimit - 1))) + "…"
    }

    private static func trimmingTrailingSpace(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    /// Whether a title is an identifier rather than a name: the session's own
    /// id or a prefix of it, or anything shaped like a UUID or a bare hex id.
    ///
    /// Codex titles a thread nobody named with the thread's id, and a board
    /// that took that at its word drew a column of `01a18c9c-92c…`. Asked of
    /// every titled row on every frame, so it allocates nothing and stops at
    /// the first character a name would have and an id would not.
    public static func isIdentifier(_ title: String, of session: SessionSnapshot) -> Bool {
        let id = session.key.sessionID
        if title == id { return true }
        if title.utf8.count >= 6, id.hasPrefix(title) { return true }
        return looksLikeIdentifier(title)
    }

    /// A UUID or a prefix of one (`01a18c9c-92c`), or sixteen or more hex
    /// digits in a row.
    static func looksLikeIdentifier(_ text: String) -> Bool {
        var group = 0
        var firstGroup: Int?
        var digits = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "a")...UInt8(ascii: "f"),
                 UInt8(ascii: "A")...UInt8(ascii: "F"):
                group += 1
                digits += 1
            case UInt8(ascii: "-"):
                guard group > 0 else { return false }
                if firstGroup == nil { firstGroup = group }
                group = 0
            default:
                return false
            }
        }
        guard group > 0 else { return false }
        guard let firstGroup else { return digits >= 16 }
        return firstGroup == 8
    }

    /// The last rung of the ladder: "Codex · 14:32", or "Codex · 11-05 14:32"
    /// for a session that did not start on the frame's day.
    ///
    /// When the session *started*, not how long ago: a title is compared on
    /// every frame and must not change while the session sits still, and a
    /// board with nothing happening on it is not republished — so "5 min ago"
    /// would be the wrong number by the time anybody read it. Digits only, so
    /// the line reads the same in every language the app speaks.
    public static func fallbackTitle(
        harness: Harness,
        at: Date?,
        now: Date?,
        timeZone: TimeZone = .current
    ) -> String {
        guard let at else { return harness.displayName }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: at)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if let now, calendar.isDate(now, inSameDayAs: at) {
            return "\(harness.displayName) · \(time)"
        }
        let day = String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
        return "\(harness.displayName) · \(day) \(time)"
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

    /// What the open call is aimed at, while the state is about one.
    ///
    /// A permission wait names its tool and not its call, so the call is found
    /// by name: the most recent open call to *that* tool. Another tool that
    /// happens to be open in parallel is not what the prompt is about, and
    /// showing its argument would put the wrong command beside "allow?".
    static func toolTarget(for session: SessionSnapshot) -> String? {
        let target: String?
        switch session.state {
        case .toolCalling:
            target = session.pending.mostRecentOpenToolCall?.target
        case .waitingPermission(let tool?):
            target = session.pending.openToolCalls.values
                .filter { $0.name == tool }
                .max { lhs, rhs in
                    if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                    return lhs.id < rhs.id
                }?
                .target
        default:
            target = nil
        }
        guard let target else { return nil }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
