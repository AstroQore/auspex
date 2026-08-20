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
    /// Briefs rebuilt from the store, for sessions the pipeline folded none for.
    public var derivedBriefs: [SessionKey: SessionBrief]
    /// Project display names by root path, from `projects.name`.
    public var projectNames: [String: String]
    /// What agents called `auspex.notify` about, by session.
    public var notices: [SessionKey: AgentNotice]
    /// What agents said they are doing, by session.
    public var reports: [SessionKey: AgentReport]

    public init(
        claims: ProjectClaims = .empty,
        rules: IgnoreRules = .none,
        showsIgnored: Bool = false,
        groupBy: BoardGroupBy = .project,
        harnessFilter: Set<Harness> = [],
        focusedProjectKey: String? = nil,
        bucketFilter: TaskLedger.Bucket? = nil,
        seenAt: [SessionKey: Date] = [:],
        derivedBriefs: [SessionKey: SessionBrief] = [:],
        projectNames: [String: String] = [:],
        notices: [SessionKey: AgentNotice] = [:],
        reports: [SessionKey: AgentReport] = [:]
    ) {
        self.claims = claims
        self.rules = rules
        self.showsIgnored = showsIgnored
        self.groupBy = groupBy
        self.harnessFilter = harnessFilter
        self.focusedProjectKey = focusedProjectKey
        self.bucketFilter = bucketFilter
        self.seenAt = seenAt
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
    /// The sections as rows, for the board.
    public let rowGroups: [BoardRowGroup]
    /// The finished sessions, most urgent first.
    public let endedRows: [BoardRow]
    /// The numbers across the top.
    public let summary: BoardSummary
    /// The sidebar's tree.
    public let tree: ProjectTree

    /// How many sessions the frame holds.
    public var sessionCount: Int { board.sessions.count }

    public init(
        sequence: UInt64,
        board: BoardSnapshot,
        ignoredKeys: Set<SessionKey>,
        sessionIndex: [SessionKey: SessionSnapshot],
        groups: [BoardGroup],
        rowGroups: [BoardRowGroup],
        endedRows: [BoardRow],
        summary: BoardSummary,
        tree: ProjectTree
    ) {
        self.sequence = sequence
        self.board = board
        self.ignoredKeys = ignoredKeys
        self.sessionIndex = sessionIndex
        self.groups = groups
        self.rowGroups = rowGroups
        self.endedRows = endedRows
        self.summary = summary
        self.tree = tree
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

    /// Derives one frame.
    public func assemble(
        board: BoardSnapshot,
        inputs: BoardFrameInputs,
        sequence: UInt64
    ) -> AssembledBoardFrame {
        assembledCount += 1
        return Self.frame(board: board, inputs: inputs, sequence: sequence)
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
        // The user layer first: which sessions are on the board at all, and
        // which project each of them is in, are questions everything below
        // asks and neither can be answered afterwards.
        let visible = BoardFilter.apply(
            to: raw,
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
            reports: inputs.reports
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
        // `EndedSessions.split` and not `mostRecentFirst`: the ledger's order
        // is total and supersedes it, and sorting four hundred finished rows
        // twice per frame is exactly the kind of redundant work the board's
        // budget is spent avoiding.
        let ended = EndedSessions.split(kept).ended
        let endedRows = TaskLedger.sorted(builder.rows(for: ended))

        return AssembledBoardFrame(
            sequence: sequence,
            board: board,
            ignoredKeys: visible.ignored,
            sessionIndex: index,
            groups: groups,
            rowGroups: rowGroups,
            endedRows: inputs.bucketFilter.map { TaskLedger.rows(endedRows, in: $0) } ?? endedRows,
            // Counted before the bucket filter, on purpose: a chip that zeroed
            // the others when clicked would leave no way back to them.
            summary: BoardSummary(sessions: kept, seenAt: inputs.seenAt, notices: inputs.notices),
            // A builder of its own, deliberately. The sidebar's rows have never
            // carried the seen-at map or the backfilled briefs, so sharing the
            // one above would quietly change what the tree's rows are titled on
            // a live machine. Unifying them is a decision about what the
            // sidebar says, not about where the derivation runs, and it belongs
            // to whoever makes it — the second index costs one hash per session
            // and is no longer on the main thread either way.
            tree: ProjectTree.build(
                board: board,
                names: inputs.projectNames,
                builder: BoardRowBuilder(board: board)
            )
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
