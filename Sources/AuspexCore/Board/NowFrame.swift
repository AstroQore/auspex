import AgentSessionKit
import AgentSessionLive
import Foundation

/// The Now screen, as values: four short lists, an idle count, and the few
/// captions the stage hangs over the office.
///
/// ## Why it is derived here, once
///
/// The screen asks four questions of every session on the board — does it
/// want me, might it want me, is it running, did it finish unread — and the
/// answers depend on each other: a session that is waiting on a person is not
/// also listed as working, and a family of subagents is one row rather than
/// six. Asked from a view body, that is a sort and four filters over every row
/// on every render. Asked here, it is one pass per assembled frame on the
/// assembler's executor, and the main actor receives four short arrays of
/// ``BoardRow``s it can compare in a handful of instructions.
///
/// Nothing new is derived about a session. Every item carries the row the
/// wall already built for it; this only decides which list it goes in and
/// what the list's line about it is.
///
/// ## The buckets, and which one wins
///
/// Each live delegation root lands in exactly one of them, in this order:
///
/// 1. **Needs you** — explicit and only explicit: an agent's `auspex.notify`
///    asking for a person, a harness's permission wait, or a filed task a
///    person marked blocked. The same rule ``AttentionState`` follows.
/// 2. **May need you** — a ``WatchSignal`` about that one session. Observed,
///    allowed to be wrong, and never folded into the first bucket. A signal
///    about several sessions at once — two tasks in one checkout — is listed
///    here too, but claims none of them: they are still running.
/// 3. **Done, unseen** — the agent said it finished and nobody has opened it.
/// 4. **Working** — the root, or something it delegated to, is active.
/// 5. **Idle** — everything else that is still alive, counted rather than
///    listed.
///
/// A subagent is folded into its root's working row as `↳N`, but an explicit
/// signal from a subagent is listed on its own: the agent that asked is the
/// one the person has to answer.
public struct NowFrame: Sendable, Equatable {
    /// Which list an item is in. Also the caption's colour on the stage.
    public enum Tone: String, Sendable, Equatable, Hashable, CaseIterable {
        case needsYou
        case mayNeedYou
        case working
        case done
        case idle
    }

    /// Why an item is in its list — the line the row prints.
    ///
    /// Structure rather than a sentence: the words belong to the app, and the
    /// same reason is printed one way in a row and another in a caption.
    public enum Reason: Sendable, Equatable, Hashable {
        /// The harness is waiting for permission to run `tool`, aimed at
        /// `target`. `tool` is `nil` for a harness that only says *somebody
        /// is needed*.
        case permission(tool: String?, target: String?)
        /// The agent called for a person, in its own words.
        case notice(message: String)
        /// A filed task a person or an agent marked blocked.
        case blockedTask
        /// An observed condition that may want a look.
        case watch(kind: WatchSignal.Kind, message: String)
        /// The agent reported finishing, in its own words.
        case done(summary: String)
        /// Running. The line is the item's ``Item/activity``.
        case working
        /// Alive and quiet.
        case idle
    }

    /// What a session is doing, split into the part that is a name and the
    /// part that is its argument — `WebSearch` and `OpenAI Dots API`.
    public struct Activity: Sendable, Equatable, Hashable {
        /// The tool, when the state is about one.
        public let tool: String?
        /// The tool's argument, or the whole of the activity when there is no
        /// tool. Never empty when ``tool`` is `nil`.
        public let detail: String?

        public init(tool: String?, detail: String?) {
            self.tool = tool
            self.detail = detail
        }

        /// The activity a row describes.
        public init(row: BoardRow) {
            switch row.state {
            case .toolCalling(let name):
                self.init(tool: name, detail: row.toolTarget)
            case .waitingPermission(let tool):
                self.init(tool: tool, detail: row.toolTarget)
            case .writingFile(let path):
                self.init(tool: "Write", detail: path)
            default:
                self.init(tool: nil, detail: row.activity)
            }
        }
    }

    /// One line in one of the lists.
    public struct Item: Identifiable, Sendable, Equatable {
        /// Stable across frames, so a list keeps its rows while it churns.
        public let id: String
        public let tone: Tone
        public let reason: Reason
        /// The session the line is about, and the one a click selects.
        public let row: BoardRow
        /// What it is doing — or, for a working family whose root is quiet,
        /// what its busiest subagent is doing.
        public let activity: Activity
        /// What the trailing stopwatch measures from: the wait, the report,
        /// the tool call, the silence. `nil` when the line has no stopwatch.
        public let since: Date?
        /// Live subagents folded under this row. `0` everywhere but Working.
        public let subagents: Int
        /// How many sessions a signal is about. `1` for every line but a
        /// collision, where it is the `×N`.
        public let sessionCount: Int
        /// The task the session is part of — what a finished line is titled
        /// by, and what a blocked line opens.
        public let unitID: String
        public let unitTitle: String
        /// Whether the unit has a session at all. A blocked task nobody has
        /// picked up opens its page rather than a trace.
        public let hasSession: Bool
        /// Reserved for a classifier's confidence on a may-need-you line.
        /// `nil` until one is wired in; the deterministic signals carry none.
        public let score: Double?

        public init(
            id: String,
            tone: Tone,
            reason: Reason,
            row: BoardRow,
            activity: Activity,
            since: Date?,
            subagents: Int = 0,
            sessionCount: Int = 1,
            unitID: String,
            unitTitle: String,
            hasSession: Bool = true,
            score: Double? = nil
        ) {
            self.id = id
            self.tone = tone
            self.reason = reason
            self.row = row
            self.activity = activity
            self.since = since
            self.subagents = subagents
            self.sessionCount = sessionCount
            self.unitID = unitID
            self.unitTitle = unitTitle
            self.hasSession = hasSession
            self.score = score
        }

        /// The session a click selects.
        public var key: SessionKey { row.key }
    }

    /// One balloon over one person on the stage.
    public struct Caption: Identifiable, Sendable, Equatable {
        /// The desk it hangs over — the session the office seats, which is
        /// the lead of the work this line is part of. See ``SceneUnits``.
        public let deskKey: SessionKey
        /// The session the line is about.
        public let sessionKey: SessionKey
        public let tone: Tone
        public let harness: Harness
        public let reason: Reason
        public let activity: Activity
        public let since: Date?

        public var id: SessionKey { deskKey }

        public init(
            deskKey: SessionKey,
            sessionKey: SessionKey,
            tone: Tone,
            harness: Harness,
            reason: Reason,
            activity: Activity,
            since: Date?
        ) {
            self.deskKey = deskKey
            self.sessionKey = sessionKey
            self.tone = tone
            self.harness = harness
            self.reason = reason
            self.activity = activity
            self.since = since
        }
    }

    public let needsYou: [Item]
    public let mayNeedYou: [Item]
    public let working: [Item]
    public let done: [Item]
    /// Alive and quiet, in project order — drawn only when the idle line is
    /// opened.
    public let idle: [Item]
    /// The balloons, most urgent first, at most ``captionLimit``.
    public let captions: [Caption]
    /// Live delegation roots on the frame: what "14 live" counts.
    public let liveCount: Int

    public var idleCount: Int { idle.count }
    public var workingCount: Int { working.count }

    /// The numbers alone, for the surfaces that count rather than list.
    ///
    /// The header's pills and the sidebar's badge read these, not the lists:
    /// a list moves whenever any row on it does — a stopwatch's anchor, a tool
    /// call — and a badge that re-rendered the sidebar for every one of those
    /// would be paying for a number that did not change.
    public struct Counts: Sendable, Equatable, Hashable {
        public var needsYou = 0
        public var mayNeedYou = 0
        public var done = 0
        public var working = 0
        public var idle = 0
        public var live = 0

        public init() {}

        /// What asks for the reader: the badge on the sidebar's Now row.
        public var asking: Int { needsYou + mayNeedYou }
    }

    public var counts: Counts {
        var counts = Counts()
        counts.needsYou = needsYou.count
        counts.mayNeedYou = mayNeedYou.count
        counts.done = done.count
        counts.working = working.count
        counts.idle = idle.count
        counts.live = liveCount
        return counts
    }

    /// Whether every list is empty.
    public var isEmpty: Bool {
        needsYou.isEmpty && mayNeedYou.isEmpty && working.isEmpty && done.isEmpty && idle.isEmpty
    }

    public static let empty = NowFrame(
        needsYou: [], mayNeedYou: [], working: [], done: [], idle: [], captions: [], liveCount: 0
    )

    /// How many people on the stage carry a balloon.
    ///
    /// Six. More than that and the balloons cover the room they are meant to
    /// annotate; and six is also the most text the scene re-sets per tick.
    public static let captionLimit = 6

    public init(
        needsYou: [Item],
        mayNeedYou: [Item],
        working: [Item],
        done: [Item],
        idle: [Item],
        captions: [Caption],
        liveCount: Int
    ) {
        self.needsYou = needsYou
        self.mayNeedYou = mayNeedYou
        self.working = working
        self.done = done
        self.idle = idle
        self.captions = captions
        self.liveCount = liveCount
    }

    // MARK: - Derivation

    /// Sorts one frame's units and watch signals into the screen's lists.
    ///
    /// Pure and total: the same units and signals always produce the same
    /// frame, in the same order. Every ordering ends on a session key, so a
    /// list does not reshuffle under the reader when nothing changed.
    ///
    /// - Parameters:
    ///   - units: every unit on the frame, as the assembler derived them.
    ///   - signals: the frame's watch signals.
    public static func derive(units: [TaskUnit], signals: [WatchSignal]) -> NowFrame {
        var rowByKey: [SessionKey: BoardRow] = [:]
        var unitByKey: [SessionKey: TaskUnit] = [:]
        for unit in units where unit.hasSessions {
            for member in unit.members {
                rowByKey[member.key] = member
                unitByKey[member.key] = unit
            }
        }

        // 1. Needs you: every session saying so, root or not, ended or not —
        //    the signal is explicit, and the agent that asked is the one to
        //    answer. Then the filed tasks marked blocked that no session in
        //    them is already shouting about.
        var needsYou: [Item] = []
        var claimed: Set<SessionKey> = []
        for unit in units where unit.hasSessions {
            for row in unit.members {
                guard case .needsYou(let message, let source) = row.attention else { continue }
                let reason: Reason = source == .harness
                    ? permissionReason(row, fallback: message)
                    : .notice(message: message)
                needsYou.append(Item(
                    id: "needs:\(row.key.description)",
                    tone: .needsYou,
                    reason: reason,
                    row: row,
                    activity: Activity(row: row),
                    since: source == .agent
                        ? (row.notice?.at ?? row.lastEventAt)
                        : (row.elapsedSince ?? row.lastEventAt),
                    unitID: unit.id,
                    unitTitle: unit.title
                ))
                claimed.insert(row.key)
            }
        }
        for unit in units where unit.origin.taskID != nil && unit.status == .blocked {
            guard !unit.members.contains(where: { $0.attention.wantsPerson }) else { continue }
            needsYou.append(Item(
                id: "blocked:\(unit.id)",
                tone: .needsYou,
                reason: .blockedTask,
                row: unit.lead,
                activity: Activity(row: unit.lead),
                since: unit.updatedAt ?? unit.lastEventAt,
                unitID: unit.id,
                unitTitle: unit.title,
                hasSession: unit.hasSessions
            ))
            if unit.hasSessions { claimed.insert(unit.lead.key) }
        }
        needsYou.sort(by: needsYouPrecedes)

        // 2. May need you: one line per signal, at most one per session, and
        //    never about a session that already asked outright.
        var mayNeedYou: [Item] = []
        var watched: Set<SessionKey> = []
        for signal in signals {
            let keys = signal.sessionKeys
            if keys.count == 1, let key = keys.first {
                guard !claimed.contains(key), !watched.contains(key),
                      let row = rowByKey[key], let unit = unitByKey[key]
                else { continue }
                watched.insert(key)
                mayNeedYou.append(Item(
                    id: "may:\(signal.id)",
                    tone: .mayNeedYou,
                    reason: .watch(kind: signal.kind, message: signal.message),
                    row: row,
                    activity: Activity(row: row),
                    since: watchSince(signal.kind, row: row),
                    unitID: unit.id,
                    unitTitle: unit.title
                ))
            } else {
                // A collision is about several sessions and claims none of
                // them; the line opens the first one that is still here and
                // is not already listed above it.
                let present = keys.filter { rowByKey[$0] != nil }
                guard let key = present.first(where: { !claimed.contains($0) }) ?? present.first,
                      let row = rowByKey[key], let unit = unitByKey[key]
                else { continue }
                mayNeedYou.append(Item(
                    id: "may:\(signal.id)",
                    tone: .mayNeedYou,
                    reason: .watch(kind: signal.kind, message: signal.message),
                    row: row,
                    activity: Activity(row: row),
                    since: nil,
                    sessionCount: keys.count,
                    unitID: unit.id,
                    unitTitle: unit.title
                ))
            }
        }
        claimed.formUnion(watched)

        // 3. Done, unseen: the receipts, root or not, from sessions no line
        //    above is already about.
        var done: [Item] = []
        for unit in units where unit.hasSessions {
            for row in unit.members where !claimed.contains(row.key) {
                guard case .doneReported(let summary, _) = row.attention else { continue }
                done.append(Item(
                    id: "done:\(row.key.description)",
                    tone: .done,
                    reason: .done(summary: summary),
                    row: row,
                    activity: Activity(row: row),
                    since: row.notice?.at ?? row.lastTurnEndedAt ?? row.lastEventAt,
                    unitID: unit.id,
                    unitTitle: unit.title
                ))
                claimed.insert(row.key)
            }
        }
        done.sort { lhs, rhs in
            let left = lhs.since ?? .distantPast
            let right = rhs.since ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }

        // 4 and 5. Every live root that is left: working when anything in its
        //    family is, idle otherwise.
        var working: [Item] = []
        var idle: [Item] = []
        var liveCount = 0
        for unit in units where unit.hasSessions {
            for family in families(in: unit) {
                liveCount += 1
                let root = family.root
                guard !claimed.contains(root.key) else { continue }
                let busiest = root.state.isActive
                    ? root
                    : family.subagents
                        .filter(\.state.isActive)
                        .max { lhs, rhs in
                            let left = lhs.lastEventAt ?? .distantPast
                            let right = rhs.lastEventAt ?? .distantPast
                            if left != right { return left < right }
                            return lhs.key.description > rhs.key.description
                        }
                if let busiest {
                    working.append(Item(
                        id: "working:\(root.key.description)",
                        tone: .working,
                        reason: .working,
                        row: root,
                        activity: Activity(row: busiest),
                        since: busiest.elapsedSince,
                        subagents: family.subagents.count,
                        unitID: unit.id,
                        unitTitle: unit.title
                    ))
                } else {
                    idle.append(Item(
                        id: "idle:\(root.key.description)",
                        tone: .idle,
                        reason: .idle,
                        row: root,
                        activity: Activity(row: root),
                        since: root.lastEventAt,
                        subagents: family.subagents.count,
                        unitID: unit.id,
                        unitTitle: unit.title
                    ))
                }
            }
        }
        working.sort(by: projectOrder)
        idle.sort(by: projectOrder)

        return NowFrame(
            needsYou: needsYou,
            mayNeedYou: mayNeedYou,
            working: working,
            done: done,
            idle: idle,
            captions: captions(
                needsYou: needsYou,
                mayNeedYou: mayNeedYou,
                working: working,
                leadOf: { unitByKey[$0]?.lead.key }
            ),
            liveCount: liveCount
        )
    }

    // MARK: - Pieces

    /// A live root and the live sessions under it.
    struct Family {
        let root: BoardRow
        let subagents: [BoardRow]
    }

    /// A unit's live sessions, grouped under the topmost live ancestor each
    /// one has inside the unit.
    ///
    /// *Live* ancestor, on purpose: a subagent whose orchestrator has exited
    /// is still running, and folding it under a row that says "exited" would
    /// hide the only work in the family. It becomes a root of its own.
    static func families(in unit: TaskUnit) -> [Family] {
        let live = unit.members.filter { !$0.isEnded }
        guard !live.isEmpty else { return [] }
        var liveByKey: [SessionKey: BoardRow] = [:]
        for row in live { liveByKey[row.key] = row }

        func rootKey(of row: BoardRow) -> SessionKey {
            var key = row.key
            var parent = row.parent?.key
            var steps = 0
            // Bounded: a cycle in a delegation forest is a bug somewhere
            // upstream, and it must not become a hang here.
            while let next = parent, let ancestor = liveByKey[next], steps < 64 {
                key = next
                parent = ancestor.parent?.key
                steps += 1
            }
            return key
        }

        var order: [SessionKey] = []
        var children: [SessionKey: [BoardRow]] = [:]
        for row in live {
            let root = rootKey(of: row)
            if root == row.key {
                order.append(root)
            } else {
                children[root, default: []].append(row)
            }
        }
        return order.compactMap { key in
            liveByKey[key].map { Family(root: $0, subagents: children[key] ?? []) }
        }
    }

    /// A harness's wait, with the call it is about when the store recorded
    /// one.
    private static func permissionReason(_ row: BoardRow, fallback: String) -> Reason {
        if case .waitingPermission(let tool) = row.state {
            return .permission(tool: tool, target: row.toolTarget)
        }
        // Derived as a harness wait but no longer in that state — the frame's
        // own attention is the authority, so keep it, with its sentence.
        return .notice(message: fallback)
    }

    /// What a watch line's stopwatch measures.
    private static func watchSince(_ kind: WatchSignal.Kind, row: BoardRow) -> Date? {
        switch kind {
        case .staleSession: row.lastEventAt
        case .longTool: row.elapsedSince
        case .contextPressure, .sharedDirectory, .sharedBranch, .orphanedClaim: nil
        }
    }

    /// A harness's permission wait first — it is the one that will not move
    /// on its own — then an agent's call, then a blocked task; the longest
    /// waiting first within each.
    private static func needsYouPrecedes(_ lhs: Item, _ rhs: Item) -> Bool {
        let left = needsRank(lhs.reason)
        let right = needsRank(rhs.reason)
        if left != right { return left < right }
        let leftSince = lhs.since ?? .distantFuture
        let rightSince = rhs.since ?? .distantFuture
        if leftSince != rightSince { return leftSince < rightSince }
        return lhs.id < rhs.id
    }

    private static func needsRank(_ reason: Reason) -> Int {
        switch reason {
        case .permission: 0
        case .notice: 1
        default: 2
        }
    }

    /// By project, then by session: a running list whose rows stay where they
    /// are while their states change several times a minute.
    private static func projectOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        let left = (lhs.row.project ?? "").lowercased()
        let right = (rhs.row.project ?? "").lowercased()
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    /// The balloons: everything that needs a person, then what may, then the
    /// most recently active of what is running — one per desk, six at most.
    static func captions(
        needsYou: [Item],
        mayNeedYou: [Item],
        working: [Item],
        leadOf: (SessionKey) -> SessionKey?
    ) -> [Caption] {
        var captions: [Caption] = []
        var desks: Set<SessionKey> = []
        let busiestFirst = working.sorted { lhs, rhs in
            let left = lhs.row.lastEventAt ?? .distantPast
            let right = rhs.row.lastEventAt ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        let single = mayNeedYou.filter { $0.sessionCount == 1 }
        for item in needsYou + single + busiestFirst {
            guard captions.count < captionLimit else { break }
            guard item.hasSession, let desk = leadOf(item.row.key),
                  desks.insert(desk).inserted
            else { continue }
            captions.append(Caption(
                deskKey: desk,
                sessionKey: item.row.key,
                tone: item.tone,
                harness: item.row.harness,
                reason: item.reason,
                activity: item.activity,
                since: item.since
            ))
        }
        return captions
    }

    // MARK: - Durations

    /// A stopwatch reading as short as it can be and still be read:
    /// `40s`, `4m12s`, `18m`, `1h04m`, `3d`.
    ///
    /// Seconds only while they matter. Under ten minutes a person is deciding
    /// whether to wait; past it, `18m` and `18m37s` are the same answer and
    /// the second one changes every second for nothing.
    public static func compactDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        switch total {
        case ..<60:
            return "\(total)s"
        case ..<600:
            return String(format: "%dm%02ds", total / 60, total % 60)
        case ..<3_600:
            return "\(total / 60)m"
        case ..<86_400:
            return String(format: "%dh%02dm", total / 3_600, (total % 3_600) / 60)
        default:
            return "\(total / 86_400)d"
        }
    }

    /// How long ``compactDuration(_:)`` goes on printing the same reading for
    /// a stopwatch that has run `interval` — the seconds until its words
    /// change.
    ///
    /// What lets a balloon ask for a frame only when it has something new to
    /// say: past ten minutes a reading holds for up to a minute, past a day
    /// for up to a day, and a clock that redrew it every second would be
    /// drawing the same word fifty-nine times out of sixty.
    public static func compactDurationHold(_ interval: TimeInterval) -> TimeInterval {
        let elapsed = max(0, interval)
        let unit: TimeInterval
        switch elapsed {
        case ..<600: unit = 1
        case ..<86_400: unit = 60
        default: unit = 86_400
        }
        let next = ((elapsed / unit).rounded(.down) + 1) * unit
        return next - elapsed
    }
}
