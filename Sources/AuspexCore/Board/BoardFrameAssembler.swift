import AgentSessionKit
import AgentSessionLive
import Foundation

/// Everything that shapes a frame except the frame itself.
///
/// The board's derivation has two inputs and they arrive from opposite
/// directions: the pipeline pushes a ``BoardSnapshot`` eight times a second,
/// and the person changes a filter, focuses a project, or opens a card once in
/// a while. Bundling the second kind into one value is what lets both go down
/// the same path — a click re-derives from the frame already in hand, using the
/// same code the next frame will use, so there is no second derivation to keep
/// in step with the first.
///
/// A value type, and every field is one, because this crosses to another
/// executor. Nothing here is a reference into the model that produced it.
public struct BoardFrameInputs: Sendable, Equatable {
    /// The person's own projects.
    public var claims: ProjectClaims
    /// What not to show.
    public var rules: IgnoreRules
    /// How far back the board reaches. Older sessions stay in the store and
    /// out of the picture — see ``SessionWindow``.
    public var window: SessionWindow
    /// Whether the ignored sessions are drawn dimmed rather than removed.
    public var showsIgnored: Bool
    /// How the grid is divided.
    public var groupBy: BoardGroupBy
    /// Which harnesses to show. Empty means all of them.
    public var harnessFilter: Set<Harness>
    /// The one project every surface is bound to, or `nil` for all of them.
    public var focusedProjectKey: String?
    /// The one ledger bucket the board is showing, or `nil` for all of them.
    public var bucketFilter: TaskLedger.Bucket?
    /// When the person last opened each session — Auspex's own record.
    public var seenAt: [SessionKey: Date]
    /// When the person last cleared each session's attention: opened its card,
    /// dismissed the call, or marked everything seen.
    ///
    /// Separate from ``seenAt`` because they answer different questions. Seen
    /// is *the transcript was on screen*; acknowledged is *the signal has been
    /// dealt with*, which a dismissal performs without anybody reading a word.
    public var acknowledgedAt: [SessionKey: Date]
    /// Briefs rebuilt from the store, for sessions the pipeline folded none for.
    public var derivedBriefs: [SessionKey: SessionBrief]
    /// Project display names by root path, from `projects.name`.
    public var projectNames: [String: String]
    /// What agents called `auspex.notify` about, by session.
    public var notices: [SessionKey: AgentNotice]
    /// What agents said they are doing, by session.
    public var reports: [SessionKey: AgentReport]
    /// What has been filed: the tasks, the links, the milestones.
    ///
    /// Read whole when the ledger changes and passed in unchanged on every
    /// frame after that. It is what turns a wall of sessions into a wall of
    /// tasks — see ``TaskUnitBuilder`` — and it is the one input here whose
    /// absence costs nothing: with an empty ledger every unit is implicit and
    /// the wall still folds every delegation family into one card.
    public var ledger: TaskLedgerFrame
    /// Whether the reader has asked to see the sessions inside each task.
    ///
    /// Here rather than in the view because it changes what the *sidebar's*
    /// tree contains, which is derived with the frame. See
    /// ``TaskUnitGrouping/expandsMembers(_:)``.
    public var showsSubagents: Bool

    public init(
        claims: ProjectClaims = .empty,
        rules: IgnoreRules = .none,
        window: SessionWindow = .standard,
        showsIgnored: Bool = false,
        groupBy: BoardGroupBy = .project,
        harnessFilter: Set<Harness> = [],
        focusedProjectKey: String? = nil,
        bucketFilter: TaskLedger.Bucket? = nil,
        seenAt: [SessionKey: Date] = [:],
        acknowledgedAt: [SessionKey: Date] = [:],
        derivedBriefs: [SessionKey: SessionBrief] = [:],
        projectNames: [String: String] = [:],
        notices: [SessionKey: AgentNotice] = [:],
        reports: [SessionKey: AgentReport] = [:],
        ledger: TaskLedgerFrame = .empty,
        showsSubagents: Bool = false
    ) {
        self.ledger = ledger
        self.showsSubagents = showsSubagents
        self.claims = claims
        self.rules = rules
        self.window = window
        self.showsIgnored = showsIgnored
        self.groupBy = groupBy
        self.harnessFilter = harnessFilter
        self.focusedProjectKey = focusedProjectKey
        self.bucketFilter = bucketFilter
        self.seenAt = seenAt
        self.acknowledgedAt = acknowledgedAt
        self.derivedBriefs = derivedBriefs
        self.projectNames = projectNames
        self.notices = notices
        self.reports = reports
    }
}

/// One frame, fully derived: everything the window draws, as values.
///
/// The point of the type is that the main actor's whole job becomes assigning
/// these fields. Nothing here has to be computed, sorted, filtered or counted
/// after it arrives, so a frame costs the main thread a handful of `==`
/// comparisons — which is the only work SwiftUI actually needs from it.
public struct AssembledBoardFrame: Sendable, Equatable {
    /// Which request produced it. Monotonic per assembler; a consumer applies
    /// frames in order and drops anything older than the one it holds.
    public let sequence: UInt64
    /// The frame with the user layer applied — what every surface renders.
    public let board: BoardSnapshot
    /// The sessions an ignore rule matched, drawn dimmed or not drawn at all.
    public let ignoredKeys: Set<SessionKey>
    /// ``board``'s sessions by key, for the lookups the selection makes.
    public let sessionIndex: [SessionKey: SessionSnapshot]
    /// The sections as snapshots, for the crew wall.
    public let groups: [BoardGroup]
    /// The sections as rows, for the sidebar and anything session-shaped.
    public let rowGroups: [BoardRowGroup]
    /// The wall: one card per piece of work, subagents folded into it.
    public let unitGroups: [TaskUnitGroup]
    /// The units whose sessions have all stopped with nothing outstanding.
    public let endedUnits: [TaskUnit]
    /// Every unit on the frame by id, for the surfaces that look one up —
    /// the task detail page, the command palette, a drop target.
    public let unitIndex: [String: TaskUnit]
    /// Which unit each session is folded into, so selecting a card and
    /// selecting a session are the same gesture seen from two ends.
    public let unitBySession: [SessionKey: String]
    /// The finished sessions, most urgent first.
    public let endedRows: [BoardRow]
    /// The numbers across the top.
    public let summary: BoardSummary
    /// The sidebar's tree.
    public let tree: ProjectTree

    /// How many sessions the frame holds.
    public var sessionCount: Int { board.sessions.count }

    /// What every session on the frame is signalling, if anything.
    ///
    /// Derived once, here, and carried whole: the scene needs to know *which*
    /// sessions to put on the waiting bench, the crew wall needs to know which
    /// card wears a ring, and the menu bar sorts by it. Three surfaces
    /// re-deriving it is three chances to draw a board that disagrees with its
    /// own header.
    ///
    /// Only the sessions that are actually saying something are in it. On a
    /// quiet machine it is empty, which is the common case and costs nothing.
    public let attention: [SessionKey: AttentionState]

    /// How many sessions the recency window left out of this frame.
    ///
    /// Carried rather than recomputed because the number is the only trace the
    /// hidden sessions leave: the board they were removed from cannot be asked
    /// how many it used to hold.
    public let olderHidden: Int

    /// Which version of ``board`` this frame carries. Bumped only when the
    /// board said something new.
    ///
    /// A number rather than a comparison, because the comparison is the thing
    /// being avoided: `BoardSnapshot` carries every `SessionSnapshot` on the
    /// machine, and a consumer that asked "did the board move" by comparing
    /// two of them would be doing several hundred deep struct comparisons on
    /// the main actor once a frame — which is the profile this whole
    /// arrangement exists to keep off it. The assembler answers on its own
    /// executor and stamps the answer here.
    public let boardRevision: UInt64

    /// `true` when this frame draws exactly what the one before it drew.
    ///
    /// Also an answer rather than a question, and for the same reason: a
    /// consumer that worked it out itself would compare every row, every
    /// group, and the whole session index on the main actor before deciding
    /// it had nothing to do.
    public let isRepeat: Bool

    public init(
        sequence: UInt64,
        board: BoardSnapshot,
        ignoredKeys: Set<SessionKey>,
        sessionIndex: [SessionKey: SessionSnapshot],
        groups: [BoardGroup],
        rowGroups: [BoardRowGroup],
        unitGroups: [TaskUnitGroup] = [],
        endedUnits: [TaskUnit] = [],
        unitIndex: [String: TaskUnit] = [:],
        unitBySession: [SessionKey: String] = [:],
        endedRows: [BoardRow],
        summary: BoardSummary,
        tree: ProjectTree,
        attention: [SessionKey: AttentionState] = [:],
        olderHidden: Int = 0,
        boardRevision: UInt64 = 1,
        isRepeat: Bool = false
    ) {
        self.unitGroups = unitGroups
        self.endedUnits = endedUnits
        self.unitIndex = unitIndex
        self.unitBySession = unitBySession
        self.sequence = sequence
        self.board = board
        self.ignoredKeys = ignoredKeys
        self.sessionIndex = sessionIndex
        self.groups = groups
        self.rowGroups = rowGroups
        self.endedRows = endedRows
        self.summary = summary
        self.tree = tree
        self.attention = attention
        self.olderHidden = olderHidden
        self.boardRevision = boardRevision
        self.isRepeat = isRepeat
    }

    /// The same frame, holding `previous`'s value for everything the two have
    /// in common.
    ///
    /// ## Why a frame is worth reconciling against the last one
    ///
    /// `@Observable` compares before it publishes: assigning a property a value
    /// equal to the one it holds notifies nobody. That is what makes the board
    /// affordable at all — most of what a frame carries is unchanged — but the
    /// comparison itself happens *in the setter*, on the main actor, and for
    /// `groups` it is a deep comparison of every `SessionSnapshot` on the
    /// board. `SessionSnapshot.__derived_struct_equals` most of the way down is
    /// exactly the profile ``BoardRow`` exists to have got rid of, and it came
    /// back through the assignment rather than through the render.
    ///
    /// So the comparison happens here, on the assembler's own executor, and
    /// what the main actor receives is the value it *already holds* — the same
    /// array, the same dictionary, the same instance. Every `==` it then does
    /// hits the identity fast path and answers in a few instructions.
    ///
    /// It costs one deep comparison per frame off the main thread to save one
    /// on it, which is the whole trade this type was built to make. Every
    /// comparison it does is done *once*: the two answers a consumer would
    /// otherwise have to work out for itself — did the board move, and is this
    /// frame a repeat — fall out of the same pass and are stamped on the
    /// result.
    public func sharing(
        _ previous: AssembledBoardFrame,
        boardRevision: UInt64
    ) -> AssembledBoardFrame {
        var isRepeat = true
        func kept<T: Equatable>(_ new: T, _ old: T) -> T {
            if new == old { return old }
            isRepeat = false
            return new
        }
        let boardMoved = !board.saysTheSameAs(previous.board)
        if boardMoved { isRepeat = false }
        let shared = AssembledBoardFrame(
            sequence: sequence,
            board: boardMoved ? board : previous.board,
            ignoredKeys: kept(ignoredKeys, previous.ignoredKeys),
            sessionIndex: kept(sessionIndex, previous.sessionIndex),
            groups: kept(groups, previous.groups),
            rowGroups: kept(rowGroups, previous.rowGroups),
            unitGroups: kept(unitGroups, previous.unitGroups),
            endedUnits: kept(endedUnits, previous.endedUnits),
            unitIndex: kept(unitIndex, previous.unitIndex),
            unitBySession: kept(unitBySession, previous.unitBySession),
            endedRows: kept(endedRows, previous.endedRows),
            summary: kept(summary, previous.summary),
            tree: kept(tree, previous.tree),
            attention: kept(attention, previous.attention),
            olderHidden: olderHidden,
            boardRevision: boardMoved ? boardRevision &+ 1 : previous.boardRevision,
            isRepeat: isRepeat && olderHidden == previous.olderHidden
        )
        return shared
    }
}

/// Where the board's frame is derived: off the main actor, one at a time.
///
/// ## Why this is not a function the model calls
///
/// Everything the window draws is a function of one ``BoardSnapshot`` and one
/// ``BoardFrameInputs``, and deriving it means copying a few hundred snapshots,
/// hashing their keys into three dictionaries, walking a delegation forest, and
/// sorting the result twice. That is a few milliseconds on a real store, eight
/// times a second while ingest is busy — and it used to run on the main actor,
/// where it was the largest remaining item in a `sample` of the live app.
///
/// It is not work the main thread has any reason to do. Nothing in it touches
/// AppKit, none of it can be observed halfway through, and its result is a
/// value. So it happens here, on the actor's own executor, and the main actor's
/// share of a frame is reduced to assigning the fields of one
/// ``AssembledBoardFrame``.
///
/// ## Ordering
///
/// An actor serialises, so two assemblies never overlap and each finishes
/// before the next begins. What an actor does *not* promise is that its callers
/// resume in the order they suspended, so every frame is stamped with
/// ``AssembledBoardFrame/sequence`` and the consumer drops anything older than
/// what it already holds. The stamp is the guard; the serialisation is only
/// what makes it cheap.
///
/// Coalescing lives with the consumer rather than here, because the consumer is
/// the one that knows the *latest* inputs: a burst of fifty snapshots should
/// produce one assembly of the fiftieth, not fifty assemblies thrown away.
///
/// ## Measured
///
/// Release builds, live against the real store, the two launched alternately so
/// that whatever else the machine was doing — several agents' sessions writing
/// transcripts, and another copy of this app — landed on both arms; five runs
/// each, `top -l 4 -s 5` plus three `sample <pid> 3` per run.
///
/// | | derivation samples on the main thread | process CPU |
/// | --- | --- | --- |
/// | on the main actor (what this replaces) | 0–304 per run | 20.6–39.1 % |
/// | here | 0 in every run | 8.3–35.1 % |
///
/// The first column is the result. In the busiest three-second window of the
/// old arm, one frame inside `rebuildGroups` held 23 % of every sample the main
/// thread took; in the new arm the derivation does not appear on that thread at
/// all, and the same stacks show up on a cooperative one. Process CPU is quoted
/// because the budget asks for it, but the two ranges overlap and neither is
/// worth a conclusion: this moves work rather than removing it, and what it
/// removes — the frames a burst no longer derives because the newest one wins —
/// is exactly what a five-run sample on a loaded machine cannot separate from
/// the machine.
///
/// What is left on the main thread is *not* this: both arms spend their busiest
/// windows inside AppKit's constraint pass over the SwiftUI graph — see
/// ``BoardSnapshot`` and the note on `LiveBoardModel.board` — which every
/// applied frame dirties and which nothing here touches.
public actor BoardFrameAssembler {
    public init() {}

    /// How many frames have actually been derived.
    ///
    /// Diagnostic, and what the suite reads to assert that a burst of frames
    /// costs far fewer than a burst of assemblies.
    public private(set) var assembledCount = 0

    /// The frame this assembler last handed out.
    ///
    /// Kept so the next one can be reconciled against it — see
    /// ``AssembledBoardFrame/sharing(_:)``. It is the one piece of state the
    /// assembler has, and it is what turns "the main actor compares every
    /// session on the board" into "the main actor compares two pointers".
    private var previous: AssembledBoardFrame?

    /// Derives one frame.
    public func assemble(
        board: BoardSnapshot,
        inputs: BoardFrameInputs,
        sequence: UInt64
    ) -> AssembledBoardFrame {
        assembledCount += 1
        var frame = Self.frame(board: board, inputs: inputs, sequence: sequence)
        if let previous {
            frame = frame.sharing(previous, boardRevision: previous.boardRevision)
        }
        previous = frame
        return frame
    }

    /// The derivation itself: pure, total, and independent of any actor.
    ///
    /// Static so the same function answers for the live board and for a test
    /// that wants the frame without an executor between it and the answer. The
    /// same pair of arguments always produces the same frame — every ordering
    /// below is total — which is what stops the board reshuffling under a
    /// reader's cursor when nothing has changed.
    public static func frame(
        board raw: BoardSnapshot,
        inputs: BoardFrameInputs,
        sequence: UInt64 = 0
    ) -> AssembledBoardFrame {
        // The window first, and for two reasons. It is the largest cut — a
        // week of bootstrapped sessions against a working day of them — so
        // everything below walks the smaller array; and it is measured from
        // the frame's own `generatedAt`, which keeps the derivation a pure
        // function of its arguments rather than of the clock.
        let windowed = SessionRecency.apply(
            to: raw,
            window: inputs.window,
            now: raw.generatedAt
        )

        // Then the user layer: which sessions are on the board at all, and
        // which project each of them is in, are questions everything below
        // asks and neither can be answered afterwards.
        let visible = BoardFilter.apply(
            to: windowed.board,
            claims: inputs.claims,
            rules: inputs.rules,
            showsIgnored: inputs.showsIgnored
        )
        let board = visible.board

        var index: [SessionKey: SessionSnapshot] = [:]
        index.reserveCapacity(board.sessions.count)
        for session in board.sessions { index[session.key] = session }

        // One builder for the whole frame: it holds the index that turns "what
        // is my parent called" from a scan of every session on the board, once
        // per card, into a lookup.
        let builder = BoardRowBuilder(
            board: board,
            seenAt: inputs.seenAt,
            briefs: inputs.derivedBriefs,
            notices: inputs.notices,
            reports: inputs.reports,
            acknowledgedAt: inputs.acknowledgedAt,
            // The frame's own instant rather than the wall clock, so the
            // age-out is replayable and a test can hand it a board from last
            // week without half the assertions expiring.
            now: raw.generatedAt
        )
        let groups = BoardGrouping.groups(
            for: board,
            groupBy: inputs.groupBy,
            harnessFilter: inputs.harnessFilter,
            projectFilter: inputs.focusedProjectKey,
            includesEnded: false
        )
        let rowGroups = groups.map { group in
            // A delegation tree keeps its own order: the shape *is* the
            // information, and re-sorting it by urgency would draw a child
            // above the parent that spawned it. Everything else is ordered by
            // the ledger — what needs a person, then what finished while they
            // were elsewhere.
            let rows = group.roots.map { flatten($0, builder: builder) }
                ?? TaskLedger.sorted(builder.rows(for: group.sessions))
            return BoardRowGroup(
                id: group.id,
                title: group.title,
                harness: group.harness,
                liveCount: group.counts.live,
                rows: inputs.bucketFilter.map { TaskLedger.rows(rows, in: $0) } ?? rows
            )
        }
        // A section header with nothing under it is a filter's leftovers. Only
        // possible while a bucket filter is on; the grouping never produces an
        // empty group of its own.
        .filter { !$0.rows.isEmpty }

        let kept = BoardGrouping.filtered(
            board.sessions,
            harnessFilter: inputs.harnessFilter,
            projectFilter: inputs.focusedProjectKey,
            in: board
        )

        // The wall, as units. Derived over the same sessions the sections were
        // built from — filters applied first, so a focused project's wall and
        // its header count the same work — and in one pass: every session is
        // assigned to a unit by dictionary lookup, and no view ever walks the
        // delegation forest again.
        let allUnits = TaskUnitBuilder.units(
            sessions: kept,
            board: board,
            ledger: inputs.ledger,
            builder: builder,
            now: raw.generatedAt
        )
        let unitSplit = TaskUnitGrouping.split(allUnits)
        let liveUnits = inputs.bucketFilter.map { bucket in
            unitSplit.live.filter { $0.bucket == bucket }
        } ?? unitSplit.live
        let unitGroups = TaskUnitGrouping.groups(
            for: liveUnits,
            board: board,
            groupBy: inputs.groupBy
        )
        var unitIndex: [String: TaskUnit] = [:]
        unitIndex.reserveCapacity(allUnits.count)
        var unitBySession: [SessionKey: String] = [:]
        unitBySession.reserveCapacity(kept.count)
        for unit in allUnits {
            unitIndex[unit.id] = unit
            for member in unit.members { unitBySession[member.key] = unit.id }
        }
        // `EndedSessions.split` and not `mostRecentFirst`: the ledger's order
        // is total and supersedes it, and sorting four hundred finished rows
        // twice per frame is exactly the kind of redundant work the board's
        // budget is spent avoiding.
        let ended = EndedSessions.split(kept).ended
        let endedRows = TaskLedger.sorted(builder.rows(for: ended))

        // The same question the rows already answered, kept as the answers
        // rather than as a count: the scene has to know *which* sessions sit on
        // the waiting bench, and the crew wall which card wears a ring. Derived
        // over `kept` — the sessions this frame is actually about — and only
        // the ones saying something are stored, so a quiet machine carries an
        // empty dictionary.
        var attention: [SessionKey: AttentionState] = [:]
        for session in kept {
            let state = builder.attention(for: session)
            guard state.isSignalling else { continue }
            attention[session.key] = state
        }

        return AssembledBoardFrame(
            sequence: sequence,
            board: board,
            ignoredKeys: visible.ignored,
            sessionIndex: index,
            groups: groups,
            rowGroups: rowGroups,
            unitGroups: unitGroups,
            endedUnits: inputs.bucketFilter == nil
                ? unitSplit.ended
                : unitSplit.ended.filter { $0.bucket == inputs.bucketFilter },
            unitIndex: unitIndex,
            unitBySession: unitBySession,
            endedRows: inputs.bucketFilter.map { TaskLedger.rows(endedRows, in: $0) } ?? endedRows,
            // Over units, and counted before the bucket filter, on purpose: the
            // wall's cards and the header's numbers have to be about the same
            // thing, and a chip that zeroed the others when clicked would leave
            // no way back to them.
            summary: BoardSummary(units: allUnits),
            tree: ProjectTree.build(
                board: board,
                names: inputs.projectNames,
                // Its own builder, deliberately, and told only about what the
                // sidebar draws. The seen-at map and the backfilled briefs are
                // withheld because they change what a tree row is *titled*, and
                // unifying that is a decision about what the sidebar says. The
                // notices are not: a project drawn in red because one of its
                // sessions is asking is the sidebar's whole job at that width.
                builder: BoardRowBuilder(
                    board: board,
                    notices: inputs.notices,
                    acknowledgedAt: inputs.acknowledgedAt,
                    now: raw.generatedAt
                )
            ),
            attention: attention,
            olderHidden: windowed.hidden
        )
    }

    /// A delegation forest as a flat run of rows carrying their depth.
    ///
    /// Flat rather than nested: the shape is carried by ``BoardRow/depth``, and
    /// a flat array is what a `LazyVStack` can be lazy about.
    private static func flatten(
        _ roots: [BoardTreeNode],
        builder: BoardRowBuilder
    ) -> [BoardRow] {
        var rows: [BoardRow] = []
        func walk(_ node: BoardTreeNode) {
            rows.append(builder.row(for: node.session, depth: node.depth))
            for child in node.children { walk(child) }
        }
        for root in roots { walk(root) }
        return rows
    }
}
