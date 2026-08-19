import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// Everything the window renders, in one observable place.
///
/// ## The one consumer of the frame stream
///
/// ``SessionRegistry/boardSnapshots`` is a single-consumer `AsyncStream`, and
/// this is that consumer. Views never touch the registry, the store, or the
/// ingest pipeline; they read a ``BoardSnapshot`` that has already been
/// sorted and tallied. That is what keeps the board, the trace, and the menu
/// bar showing the same thing — three readers of one value cannot disagree.
///
/// ## How the trace stays live
///
/// The trace is the event log, which lives in SQLite, not in the snapshot. It
/// is refreshed by *reacting to the board*: every frame that changes the
/// selected session's `lastEventAt` schedules a re-read of
/// `recentEvents(key:limit:)`, debounced so a burst of twenty frames is one
/// query. Two things make this the right trade rather than a lazy one:
///
/// - The registry already batches its writes into one transaction per 250 ms,
///   so a second event source tapped off the stream would still be waiting on
///   the same commit. The trace cannot be fresher than the store is.
/// - A window of a few hundred rows is a single indexed range scan. Re-reading
///   it is cheaper than maintaining an incremental view that has to reconcile
///   with what bootstrap loaded.
///
/// The visible cost is that a row can appear up to a persist interval after
/// the board reacted to the same event. On a live tail that is a quarter of a
/// second, and it is bounded rather than drifting.
@MainActor
@Observable
final class LiveBoardModel {
    // MARK: Board

    /// The frame every view renders: the one the registry produced, with the
    /// person's own projects applied and the ignored sessions taken out.
    ///
    /// Views read this and never ``rawBoard``. That is the whole of how "an
    /// ignored session disappears everywhere" is true — the board, the scene,
    /// the crew, the sidebar's tree, the summary chips and the menu bar are
    /// six readers of this one value, and none of them knows a rule exists.
    ///
    /// Starts empty so the first render has something to draw before any event
    /// arrives.
    ///
    /// ## Who may read it, and who may not
    ///
    /// Every other observable property here is published only when it moves,
    /// because the `@Observable` macro compares an `Equatable` value against
    /// the one it is replacing and stays quiet when they match. This one can
    /// never match: a frame carries a fresh `generatedAt` and a fresh array of
    /// snapshots every time, so **every applied frame invalidates every view
    /// that read `board`** — eight times a second on a busy machine, whether
    /// or not anything those views draw has changed.
    ///
    /// That is affordable for the surfaces that are on screen one at a time —
    /// the scene, the crew wall, the Harnesses page — and ruinous for the ones
    /// that are always on screen. A `sample` of the live board with ~700
    /// sessions had the main thread busy 100 % of a three-second window, and
    /// 57.7 % of it inside `NSHostingView.minSize()`: AppKit re-asking the
    /// SwiftUI root for its minimum size, which is a `sizeThatFits` over the
    /// whole window, on every display cycle in which the graph was dirty.
    ///
    /// So the always-visible surfaces — the sidebar, the header, the trace
    /// pane — read the narrow values derived below instead: ``sessionCount``,
    /// ``selectedSession``, ``selectedParent``, ``selectedChildren``,
    /// ``selectedProjectName``. Reading `board` from one of them puts the
    /// whole window back on that treadmill.
    private(set) var board: BoardSnapshot = .empty

    /// How many sessions the current frame holds.
    ///
    /// The sidebar's "All sessions" row and the header's count. An `Int`, so
    /// its readers are invalidated when the number moves; `board.sessions.count`
    /// would read ``board`` and invalidate them on every frame instead.
    private(set) var sessionCount = 0

    /// The frame as it arrived, before the user layer.
    ///
    /// Kept because the header has to say how many rows the rules are hiding,
    /// and because turning "show ignored" on must not have to wait for the
    /// next frame to put them back.
    private(set) var rawBoard: BoardSnapshot = .empty

    /// The sessions an ignore rule matched on the current frame — empty unless
    /// something is being hidden, and still filled while ``showsIgnored`` is
    /// on, so the rows it reveals can be drawn dimmed.
    private(set) var ignoredKeys: Set<SessionKey> = []

    /// How many sessions the rules are hiding. The number in the header's
    /// toggle.
    var ignoredCount: Int { ignoredKeys.count }

    /// Whether the ignored sessions are on the board, dimmed, rather than gone.
    var showsIgnored = false {
        didSet { if oldValue != showsIgnored { rebuildVisibleBoard() } }
    }

    /// The person's own projects, as an index the frame carries.
    private(set) var claims: ProjectClaims = .empty

    /// What not to show.
    private(set) var ignoreRules: IgnoreRules = .none

    /// How the live sessions are drawn: the grid of cards, or the scene.
    ///
    /// A mode rather than a destination, so switching keeps the selection, the
    /// grouping, the filters, and the trace beside it.
    var viewMode: BoardViewMode = .board {
        didSet {
            guard oldValue != viewMode else { return }
            guard viewMode.requiresSelection else {
                // Leaving the trajectory stops its reads. The fold is kept:
                // coming back to the same session should not re-read a
                // transcript the model already holds.
                trajectory.stop()
                return
            }
            modeBeforeTrajectory = oldValue
            guard selectedKey != nil else {
                viewMode = oldValue
                return
            }
            loadTrajectory()
        }
    }

    /// The mode to go back to when the trajectory is closed.
    ///
    /// Stored rather than assumed to be `.board`, because a person who opened
    /// a trajectory from the scene asked to look at one session, not to be
    /// moved to a different way of looking at all of them.
    private var modeBeforeTrajectory: BoardViewMode = .board

    /// The Trajectory mode's own state: the fold, the layout, the brush, and
    /// the inspector's selection.
    ///
    /// Held here rather than inside the view so that switching modes, or
    /// letting the window close, does not throw away a reader's place in a
    /// five-thousand-step session.
    let trajectory = TrajectoryModel()

    /// Opens the Trajectory on the selected session, from wherever the reader
    /// was. Does nothing with no session selected: there would be nothing to
    /// draw, and a mode that shows an empty column is worse than a segment
    /// that will not light up.
    func openTrajectory() {
        guard selectedKey != nil else { return }
        if viewMode == .trajectory {
            loadTrajectory()
        } else {
            viewMode = .trajectory
        }
    }

    /// Leaves the Trajectory for whichever mode it was opened from.
    func closeTrajectory() {
        guard viewMode == .trajectory else { return }
        viewMode = modeBeforeTrajectory
    }

    /// Whether the Trajectory segment can be pressed at all.
    var canOpenTrajectory: Bool { selectedKey != nil }

    private func loadTrajectory() {
        trajectory.open(
            key: selectedKey,
            repository: repository,
            isAlive: selectedSession?.isAlive ?? false
        )
    }

    /// How the grid is divided.
    ///
    /// By project, because that is the question a person opens the board with —
    /// *what is happening to my repositories* — and because a session's project
    /// is the one fact that stays true while its state changes six times a
    /// minute.
    var groupBy: BoardGroupBy = .project {
        didSet { if oldValue != groupBy { rebuildGroups() } }
    }

    /// Which harnesses to show. Empty means all of them.
    var harnessFilter: Set<Harness> = [] {
        didSet { if oldValue != harnessFilter { rebuildGroups() } }
    }

    /// The one project every surface is bound to, as the key
    /// ``BoardSnapshot/projectKey(for:)`` answers with. `nil` shows all of
    /// them.
    ///
    /// Set by clicking a project in the sidebar and cleared by clicking it
    /// again, by the crumb over the wall, or by Escape — which is why it is a
    /// single value rather than a set: the sidebar row is a place to *go*, and
    /// a multi-select there would need a control of its own to be discoverable
    /// at all.
    ///
    /// One property for every surface. The wall keeps that project's sections,
    /// the crew wall filters the same way, and the scene pans its camera to
    /// that room; three properties would be three chances for the sidebar and
    /// the scene to be looking at different projects.
    var focusedProjectKey: String? {
        didSet { if oldValue != focusedProjectKey { rebuildGroups() } }
    }

    /// The one ledger bucket the board is showing, set by clicking a summary
    /// chip and cleared by clicking it again. `nil` shows everything.
    ///
    /// A chip is a count and a filter at once, which is the cheapest way to
    /// make a number actionable: reading "3 done unseen" and then hunting for
    /// which three is the work this saves.
    var bucketFilter: TaskLedger.Bucket? {
        didSet { if oldValue != bucketFilter { rebuildGroups() } }
    }

    /// When the person last opened each session — Auspex's own record, and the
    /// other half of "done, and you have not looked at it".
    ///
    /// Held in memory and written through to the store, rather than read per
    /// card: the answer changes only when somebody clicks, and a card must not
    /// go to SQLite to find out whether it is unread.
    private(set) var seenAt: [SessionKey: Date] = [:]

    /// Briefs rebuilt from the store, for sessions the pipeline never folded
    /// one for — see ``BriefBackfill``.
    ///
    /// A card reads one of these only when its own brief is empty. The map is
    /// built once, off the main actor, and handed over whole; the row builder
    /// then costs one hash lookup rather than a query it must never make.
    private(set) var derivedBriefs: [SessionKey: SessionBrief] = [:]

    /// Hands the board the briefs a backfill rebuilt, and redraws.
    ///
    /// Sessions the registry already holds get theirs through
    /// ``SessionRegistry/applyBriefs(_:)``; this covers the ones it does not —
    /// bootstrap loads the most recent few hundred, and a session past that
    /// limit is seeded from its next event with a brief the store already knows
    /// better than.
    func setDerivedBriefs(_ briefs: [SessionKey: SessionBrief]) {
        guard !briefs.isEmpty else { return }
        derivedBriefs = briefs
        rebuildGroups()
    }

    /// The card the detail pane is about.
    var selectedKey: SessionKey? {
        didSet {
            guard oldValue != selectedKey else { return }
            refreshSelection()
            if let selectedKey { markSeen(selectedKey) }
            trace = []
            traceItems = []
            expandedRows = []
            followsTail = true
            lastTraceEventAt = nil
            reloadTrace()
            if viewMode == .trajectory {
                if selectedKey == nil { closeTrajectory() } else { loadTrajectory() }
            }
        }
    }

    /// The sections the grid draws, in display order, as rows.
    ///
    /// Stored rather than computed, and made of ``BoardRow`` rather than of
    /// snapshots. Both are performance properties and both are load-bearing:
    ///
    /// - A SwiftUI body may run many times for one change, and grouping walks
    ///   every session and tallies every group. At eight frames a second with
    ///   a few hundred sessions that is work redone for an answer that only
    ///   changes when the board, the axis, or the filter does.
    /// - SwiftUI compares view values to decide what to re-render, so anything
    ///   a view holds gets compared. A `SessionSnapshot` carries a dictionary
    ///   of open tool calls, a set of open children, and fifteen optionals of
    ///   identity; comparing a few hundred of those is the most expensive
    ///   thing the old board did, and a profile of it was
    ///   `SessionSnapshot.__derived_struct_equals` most of the way down.
    ///
    /// So the derivation happens here, once per applied frame, and the views
    /// hold flat values of scalars and strings.
    private(set) var rowGroups: [BoardRowGroup] = []

    /// The same sections as snapshots, for the crew wall.
    ///
    /// The board does not read this and must not: it is an array of
    /// `SessionSnapshot`, which is the value whose equality this whole
    /// arrangement exists to keep out of the render loop. The crew wall draws
    /// avatars from fields the row model does not carry and is only built
    /// while its mode is on screen, so it keeps the snapshots for now — one
    /// mode's cost rather than the board's.
    private(set) var groups: [BoardGroup] = []

    /// The finished sessions the collapsed section at the bottom draws from,
    /// most recently finished first.
    ///
    /// Held apart from ``rowGroups`` rather than filtered out in the view,
    /// because keeping them out of the grid is the board's main performance
    /// property — see ``EndedSessions`` — and a policy that lived in a view
    /// body would be one refactor away from being lost.
    private(set) var endedRows: [BoardRow] = []

    /// Whether the reader has asked for every finished session rather than the
    /// most recent handful.
    var showsAllEnded = false

    /// The four numbers across the top of the board.
    private(set) var summary = BoardSummary(counts: BoardSnapshot.Counts())

    /// Called after each applied frame, so the sidebar's tree is rebuilt once
    /// per frame rather than once per body.
    var onFrame: ((BoardSnapshot) -> Void)?

    /// The finished rows actually drawn, and how many are left out.
    var visibleEndedRows: [BoardRow] {
        showsAllEnded ? endedRows : Array(endedRows.prefix(EndedSessions.collapsedLimit))
    }

    var hiddenEndedCount: Int {
        showsAllEnded ? 0 : max(0, endedRows.count - EndedSessions.collapsedLimit)
    }

    private func rebuildGroups() {
        // One builder for the whole frame: it holds the index that turns "what
        // is my parent called" from a scan of every session on the board, once
        // per card, into a lookup.
        var index: [SessionKey: SessionSnapshot] = [:]
        index.reserveCapacity(board.sessions.count)
        for session in board.sessions { index[session.key] = session }
        sessionIndex = index

        let builder = BoardRowBuilder(board: board, seenAt: seenAt, briefs: derivedBriefs)
        let groups = BoardGrouping.groups(
            for: board,
            groupBy: groupBy,
            harnessFilter: harnessFilter,
            projectFilter: focusedProjectKey,
            includesEnded: false
        )
        self.groups = groups
        // Assigned every frame and *published* only when it moved: the
        // `@Observable` macro compares an `Equatable` value against the one it
        // is replacing and stays quiet when they match. That is the whole
        // reason a row is a flat value — a frame arrives whenever any session
        // changed, most of those changes never reach the wall, and the
        // comparison that decides is a scan of scalars rather than a re-layout
        // of the grid.
        rowGroups = groups.map { group in
            // A delegation tree keeps its own order: the shape *is* the
            // information, and re-sorting it by urgency would draw a child
            // above the parent that spawned it. Everything else is ordered by
            // the ledger — what needs a person, then what finished while they
            // were elsewhere.
            let rows = group.roots.map { Self.flatten($0, builder: builder) }
                ?? TaskLedger.sorted(builder.rows(for: group.sessions))
            return BoardRowGroup(
                id: group.id,
                title: group.title,
                harness: group.harness,
                liveCount: group.counts.live,
                rows: bucketFilter.map { bucket in TaskLedger.rows(rows, in: bucket) } ?? rows
            )
        }
        // A section header with nothing under it is a filter's leftovers. Only
        // possible while a bucket filter is on; the grouping never produces an
        // empty group of its own.
        .filter { !$0.rows.isEmpty }

        let kept = BoardGrouping.filtered(
            board.sessions,
            harnessFilter: harnessFilter,
            projectFilter: focusedProjectKey,
            in: board
        )
        // `EndedSessions.split` and not `mostRecentFirst`: the ledger's order
        // is total and supersedes it, and sorting four hundred finished rows
        // twice per frame is exactly the kind of redundant work the board's
        // budget is spent avoiding.
        let ended = EndedSessions.split(kept).ended
        let endedRows = TaskLedger.sorted(builder.rows(for: ended))
        self.endedRows = bucketFilter.map { TaskLedger.rows(endedRows, in: $0) } ?? endedRows
        // Counted before the bucket filter, on purpose: a chip that zeroed the
        // others when clicked would leave no way back to them.
        summary = BoardSummary(sessions: kept, seenAt: seenAt)
        sessionCount = board.sessions.count
        refreshSelection()
    }

    /// Re-derives the four things the trace pane draws about the selection.
    ///
    /// The pane asks four questions of the frame — which session is selected,
    /// what spawned it, what it spawned, and what its project is called — and
    /// it used to ask them from its own body, through computed properties over
    /// ``board`` and ``sessionIndex``. Both of those are replaced wholesale on
    /// every applied frame, so the pane was invalidated on every applied frame:
    /// a header, a tab bar and a two-thousand-row waterfall re-laid out eight
    /// times a second because some other session on the machine had said
    /// something.
    ///
    /// Answered here instead, once per frame, into four `Equatable` properties
    /// the pane can read without seeing the frame. Each is compared by the
    /// `@Observable` macro before it notifies, so the pane is invalidated when
    /// *its* session moves and not when anything else does.
    private func refreshSelection() {
        let session = selectedKey.flatMap { sessionIndex[$0] }
        selectedSession = session
        selectedParent = session?.identity.parent.flatMap { sessionIndex[$0] }

        // Taken from the frame's own forest rather than from
        // `SessionSnapshot.children`, because that list is what the *adapter*
        // recorded — it has no way to know about a `codex exec` the process
        // table linked up three seconds ago, and the header should show both
        // kinds of child the same way.
        selectedChildren = selectedKey
            .flatMap { board.tree.node(for: $0) }?
            .children.compactMap { sessionIndex[$0.key] } ?? []

        selectedProjectName = session
            .flatMap { board.projectKey(for: $0) }
            .map(BoardGrouping.projectName(forPath:))
    }

    /// Turns the bucket filter on, or off if it is already on this bucket.
    func toggleBucketFilter(_ bucket: TaskLedger.Bucket) {
        bucketFilter = bucketFilter == bucket ? nil : bucket
    }

    // MARK: What has been read

    /// Records that the person has now looked at a session.
    ///
    /// Called when a card is selected, which is the only way its trace opens —
    /// so "seen" means "the transcript was on screen" rather than "the card
    /// was on the wall". The write goes through the store off the main actor;
    /// the in-memory map is updated first so the dot clears on the same frame
    /// as the click rather than a persist interval later.
    func markSeen(_ key: SessionKey, at date: Date = Date()) {
        if let existing = seenAt[key], existing >= date { return }
        seenAt[key] = date
        rebuildGroups()
        guard let repository else { return }
        Task.detached(priority: .utility) {
            try? repository.markSeen(key: key, at: date)
        }
    }

    /// Reloads what has already been read, so a relaunch does not mark a
    /// week of finished sessions unread.
    func loadSeen() {
        guard let repository else { return }
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { () -> [SessionKey: Date] in
                (try? repository.allLastSeen()) ?? [:]
            }.value
            guard let self, !stored.isEmpty else { return }
            for (key, date) in stored where (self.seenAt[key] ?? .distantPast) < date {
                self.seenAt[key] = date
            }
            self.rebuildGroups()
        }
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

    /// Binds every surface to a project, or unbinds if it is already bound to
    /// this one.
    func toggleFocusedProject(_ key: String) {
        focusedProjectKey = focusedProjectKey == key ? nil : key
    }

    /// Binds to the project a session is in — what selecting a session row in
    /// the sidebar does, so the card, the trace and the wall all end up in the
    /// same place.
    func focusProject(of key: SessionKey) {
        guard let session = sessionIndex[key] else { return }
        focusedProjectKey = board.projectKey(for: session)
    }

    /// What the focused project is called, for the crumb over the wall.
    var focusedProjectName: String? {
        focusedProjectKey.map(board.projectDisplayName(forKey:))
    }

    /// Every session on the current frame, by key.
    ///
    /// Rebuilt with the frame. `BoardSnapshot.session(for:)` is a linear scan,
    /// and the selection lookups below would otherwise be a scan per child per
    /// body on a board of several hundred sessions.
    ///
    /// Deliberately not observed. It is a lookup table, not something anybody
    /// draws, and it is replaced wholesale on every applied frame — so a view
    /// that read it would be invalidated on every applied frame. What views
    /// read is the four properties below, derived from it once per frame and
    /// published only when they move.
    @ObservationIgnored private var sessionIndex: [SessionKey: SessionSnapshot] = [:]

    /// One session's live snapshot, when the current frame still has it.
    ///
    /// A lookup into the per-frame index, for the handful of places that need
    /// the whole snapshot rather than the row derived from it — a resume
    /// command needs the session id, the variant, and the working directory,
    /// none of which a card carries. Those places are context menus and sheets,
    /// built when they are opened rather than with the board, which is why an
    /// unobserved index is enough for them.
    func session(for key: SessionKey) -> SessionSnapshot? {
        sessionIndex[key]
    }

    /// The selected session's live snapshot, when the board still has one.
    private(set) var selectedSession: SessionSnapshot?

    /// The parent of the selected session, when it has one and the board
    /// knows it. Drives the "spawned by" link in the trace header.
    private(set) var selectedParent: SessionSnapshot?

    /// What the selected session spawned, direct children only, in board
    /// order.
    private(set) var selectedChildren: [SessionSnapshot] = []

    /// What the selected session's project is called, for the trace header.
    private(set) var selectedProjectName: String?

    /// The directory a session is actually working in, unabbreviated.
    ///
    /// ``BoardRow/directory`` is shortened to `~` for the card; a rule needs
    /// the path the session reported, and the worktree before the repository
    /// because that is the directory a person pointing at this row means.
    func directoryPath(of key: SessionKey) -> String? {
        guard let identity = sessionIndex[key]?.identity else { return nil }
        return identity.worktreePath ?? identity.gitRoot ?? identity.cwd
    }

    /// How many sessions the given one has below it, at any depth.
    ///
    /// The board's cards carry this on their row, worked out once per frame.
    /// This is for the crew wall, which still asks per card.
    func descendantCount(of key: SessionKey) -> Int {
        board.tree.descendants(of: key).count
    }

    /// Whether any session has ever been seen. Distinguishes "watching, and
    /// nothing is running" from "just launched".
    private(set) var hasEverSeenSession = false

    /// Selects the first session on the board the next time one appears.
    ///
    /// Off in a live run: opening an inspector onto whichever session a
    /// person's machine happened to write to first is presumptuous. On in the
    /// demo, where the point is to show the whole app at once.
    var autoSelectsFirstSession = false

    // MARK: Trace

    /// The selected session's events, oldest first.
    private(set) var trace: [TraceEntry] = []

    /// ``trace`` with the filter applied and turn separators interleaved —
    /// precomputed so the `List` body does no work per frame.
    private(set) var traceItems: [TraceListItem] = []

    /// Which categories are shown. All of them, until a chip is switched off.
    var traceFilter: Set<TraceEntry.Category> = Set(TraceEntry.Category.allCases) {
        didSet { rebuildTraceItems() }
    }

    /// Rows the reader has opened.
    var expandedRows: Set<Int64> = []

    /// Whether the trace scrolls to the newest row as rows arrive. Turned off
    /// when the reader scrolls up, so reading history is not fought with.
    var followsTail = true

    /// `true` while the first load for a session is in flight.
    private(set) var isLoadingTrace = false

    // MARK: Search

    /// The toolbar's query.
    var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            scheduleSearch()
        }
    }

    /// The current hits, best match first.
    private(set) var searchHits: [SearchHit] = []

    /// `true` once a query long enough to answer has been run and returned
    /// nothing — so the results popover can say so instead of staying blank.
    private(set) var searchDidRun = false

    // MARK: Diagnostics

    /// What the ingest pipeline has said about itself, newest last. Shown in
    /// the empty state, which is the only place a person can act on it.
    private(set) var notices: [String] = []

    // MARK: Wiring

    private var repository: SessionRepository?
    private var consumeTask: Task<Void, Never>?
    private var traceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastTraceEventAt: Date?

    /// How many events the trace holds. Enough for a long session, bounded so
    /// a runaway one cannot make the window unresponsive.
    private static let traceWindow = 2_000

    /// Starts consuming `registry`'s frames.
    ///
    /// - Parameters:
    ///   - registry: the live set. Its frame stream is consumed here and
    ///     nowhere else.
    ///   - repository: where the trace and the search index are read from.
    ///     `nil` when the store could not be opened — the board still works,
    ///     it just has no history behind it.
    func start(registry: SessionRegistry, repository: SessionRepository?) {
        self.repository = repository
        loadSeen()
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            // The registry publishes up to 20 frames a second; a wall of a few
            // hundred cards cannot lay out that often without owning the main
            // thread. Frames are coalesced to `frameInterval` — the newest one
            // wins, nothing is queued — which is invisible on a live board and
            // is what keeps ingest and rendering from fighting.
            var lastApplied = ContinuousClock.now - Self.frameInterval
            var pending: BoardSnapshot?
            var flush: Task<Void, Never>?
            for await frame in registry.boardSnapshots {
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                if now - lastApplied >= Self.frameInterval {
                    flush?.cancel(); flush = nil; pending = nil
                    lastApplied = now
                    self?.apply(frame)
                } else {
                    pending = frame
                    if flush == nil {
                        let wait = Self.frameInterval - (now - lastApplied)
                        flush = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: wait)
                            guard !Task.isCancelled, let latest = pending else { return }
                            pending = nil; flush = nil
                            lastApplied = ContinuousClock.now
                            self?.apply(latest)
                        }
                    }
                }
            }
        }
    }

    /// Minimum spacing between two applied frames (8 Hz).
    private static let frameInterval: Duration = .milliseconds(120)

    /// Stops consuming. Called when the app is shutting down.
    func stop() {
        consumeTask?.cancel()
        traceTask?.cancel()
        searchTask?.cancel()
        consumeTask = nil
        traceTask = nil
        searchTask = nil
        trajectory.stop()
    }

    /// Records something the ingest pipeline reported.
    func record(notice: String) {
        notices.append(notice)
        if notices.count > 24 { notices.removeFirst(notices.count - 24) }
    }

    /// Replaces the user layer — the projects a person has made and the rules
    /// they have written — and redraws from the frame already in hand.
    ///
    /// Called when the catalog changes, which is when somebody edits a project
    /// or a rule. Redrawing from ``rawBoard`` rather than waiting for the next
    /// frame is what makes adding a rule feel like a switch instead of a
    /// request.
    func setUserLayer(claims: ProjectClaims, rules: IgnoreRules, showsIgnored: Bool) {
        guard claims != self.claims || rules != ignoreRules || showsIgnored != self.showsIgnored
        else { return }
        self.claims = claims
        ignoreRules = rules
        if self.showsIgnored != showsIgnored {
            self.showsIgnored = showsIgnored  // the `didSet` rebuilds
        } else {
            rebuildVisibleBoard()
        }
    }

    /// Turns the frame in hand into the one the views draw.
    ///
    /// One pass per applied frame, next to the row derivation that was already
    /// happening there. The fast path when nothing is claimed and no rule is
    /// on is a pointer copy: ``BoardFilter`` hands back the frame it was given.
    private func rebuildVisibleBoard() {
        let visible = BoardFilter.apply(
            to: rawBoard,
            claims: claims,
            rules: ignoreRules,
            showsIgnored: showsIgnored
        )
        board = visible.board
        ignoredKeys = visible.ignored
        rebuildGroups()
        onFrame?(board)
    }

    /// Applies one frame.
    ///
    /// Internal rather than private so the suite can hand it a frame: the only
    /// other way in is a live `SessionRegistry` and a real event stream, which
    /// would make a test of "what does the board do with this frame" a test of
    /// the pipeline's timing.
    func apply(_ frame: BoardSnapshot) {
        rawBoard = frame
        rebuildVisibleBoard()
        if !board.sessions.isEmpty { hasEverSeenSession = true }

        if autoSelectsFirstSession, selectedKey == nil, let first = board.sessions.first {
            selectedKey = first.key
            return  // the `didSet` already scheduled the load
        }

        // A frame that did not move the selected session cannot have added a
        // row to its trace, and re-reading on every tick would query four
        // times a second for a session nobody is touching.
        guard let key = selectedKey, let session = board.session(for: key) else { return }
        guard session.lastEventAt != lastTraceEventAt else { return }
        lastTraceEventAt = session.lastEventAt
        reloadTrace()
        if viewMode == .trajectory { trajectory.refresh(isAlive: session.isAlive) }
    }

    // MARK: Trace loading

    /// Re-reads the selected session's events, coalescing bursts.
    private func reloadTrace() {
        guard let key = selectedKey, let repository else {
            trace = []
            traceItems = []
            return
        }
        if trace.isEmpty { isLoadingTrace = true }

        traceTask?.cancel()
        traceTask = Task { [weak self] in
            // Long enough to fold a flush of a whole turn into one query,
            // short enough that a click feels immediate.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }

            let limit = Self.traceWindow
            let events = await Task.detached(priority: .userInitiated) { () -> [StoredEvent] in
                (try? repository.recentEvents(key: key, limit: limit)) ?? []
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.selectedKey == key else { return }
                self.isLoadingTrace = false
                self.trace = TraceEntry.entries(from: events)
                self.rebuildTraceItems()
            }
        }
    }

    /// Rebuilds the flattened list the trace renders: the filtered rows, with
    /// a separator inserted wherever the turn number changes.
    ///
    /// Done here rather than in the view because it is O(rows) and a SwiftUI
    /// body may run many times per second; the inputs only change when the
    /// trace or the filter does.
    private func rebuildTraceItems() {
        var items: [TraceListItem] = []
        items.reserveCapacity(trace.count + 8)
        var currentTurn: Int?
        for entry in trace where traceFilter.contains(entry.category) {
            if entry.turnIndex != currentTurn {
                currentTurn = entry.turnIndex
                if entry.turnIndex > 0 {
                    items.append(.turnSeparator(turn: entry.turnIndex, at: entry.timestamp))
                }
            }
            items.append(.row(entry))
        }
        traceItems = items
    }

    /// The row of the permission prompt nobody has answered, when there is
    /// one.
    ///
    /// Answered here rather than in the row, because a row cannot tell the
    /// difference between "Bash wants to run this" and "Bash was allowed to
    /// run this" — both are permission rows with no duration — and outlining
    /// both in red would make the highlight mean "something to do with
    /// permissions" instead of "this is what the board is waiting on".
    var pendingPermissionRowID: TraceEntry.ID? {
        guard let session = selectedSession,
              case .waitingPermission = session.state
        else { return nil }
        return trace.last { $0.glyph == .permission }?.id
    }

    /// The id of the last row, for the auto-scroll to aim at.
    var traceTailID: TraceListItem.ID? {
        traceItems.last?.id
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard let repository,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count
                  >= SessionRepository.minimumSearchLength
        else {
            searchHits = []
            searchDidRun = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
                (try? repository.search(query: query, limit: 40)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.searchQuery == query else { return }
                self.searchHits = hits
                self.searchDidRun = true
            }
        }
    }

    /// Selects the session a search hit belongs to and clears the query, so
    /// the results popover closes onto the thing it was pointing at.
    func openSearchHit(_ hit: SearchHit) {
        selectedKey = hit.session
        searchQuery = ""
        searchHits = []
        searchDidRun = false
    }
}

/// One entry in the flattened trace list: a row, or the rule between turns.
///
/// A separate type rather than a nil-able row so the `List` can be a single
/// `ForEach` over one identifiable collection — which is what keeps two
/// thousand rows scrolling smoothly.
enum TraceListItem: Identifiable, Hashable {
    case turnSeparator(turn: Int, at: Date)
    case row(TraceEntry)

    var id: String {
        switch self {
        case .turnSeparator(let turn, _): "turn-\(turn)"
        case .row(let entry): "row-\(entry.id)"
        }
    }
}
