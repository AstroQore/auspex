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

    /// The current frame. Starts empty so the first render has something to
    /// draw before any event arrives.
    private(set) var board: BoardSnapshot = .empty

    /// How the live sessions are drawn: the grid of cards, or the scene.
    ///
    /// A mode rather than a destination, so switching keeps the selection, the
    /// grouping, the filters, and the trace beside it.
    var viewMode: BoardViewMode = .board

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

    /// The one project the wall is showing, as the key
    /// ``BoardSnapshot/projectKey(for:)`` answers with. `nil` shows all of
    /// them.
    ///
    /// Set by clicking a project in the sidebar and cleared by clicking it
    /// again, which is why it is a single value rather than a set: the sidebar
    /// row is a place to *go*, and a multi-select there would need a control of
    /// its own to be discoverable at all.
    var projectFilter: String? {
        didSet { if oldValue != projectFilter { rebuildGroups() } }
    }

    /// The card the detail pane is about.
    var selectedKey: SessionKey? {
        didSet {
            guard oldValue != selectedKey else { return }
            trace = []
            traceItems = []
            expandedRows = []
            followsTail = true
            lastTraceEventAt = nil
            reloadTrace()
        }
    }

    /// The sections the grid draws, in display order.
    ///
    /// Stored rather than computed. A SwiftUI body may run many times for one
    /// change, and grouping walks every session and tallies every group; at
    /// twenty frames a second with a few hundred sessions that is work done
    /// over and over for an answer that only changes when the board, the axis,
    /// or the filter does.
    private(set) var groups: [BoardGroup] = []

    /// The finished sessions the collapsed section at the bottom draws from,
    /// most recently finished first.
    ///
    /// Held apart from ``groups`` rather than filtered out in the view, because
    /// keeping them out of the grid is the board's main performance property —
    /// see ``EndedSessions`` — and a policy that lived in a view body would be
    /// one refactor away from being lost.
    private(set) var endedSessions: [SessionSnapshot] = []

    /// Whether the reader has asked for every finished session rather than the
    /// most recent handful.
    var showsAllEnded = false

    /// The four numbers across the top of the board.
    private(set) var summary = BoardSummary(counts: BoardSnapshot.Counts())

    /// The finished rows actually drawn, and how many are left out.
    var visibleEndedSessions: [SessionSnapshot] {
        EndedSessions.visible(endedSessions, showingAll: showsAllEnded)
    }

    var hiddenEndedCount: Int {
        EndedSessions.hiddenCount(endedSessions, showingAll: showsAllEnded)
    }

    private func rebuildGroups() {
        groups = BoardGrouping.groups(
            for: board,
            groupBy: groupBy,
            harnessFilter: harnessFilter,
            projectFilter: projectFilter,
            includesEnded: false
        )
        let kept = BoardGrouping.filtered(
            board.sessions,
            harnessFilter: harnessFilter,
            projectFilter: projectFilter,
            in: board
        )
        endedSessions = EndedSessions.mostRecentFirst(EndedSessions.split(kept).ended)
        summary = BoardSummary(counts: BoardSnapshot.Counts(sessions: kept))
    }

    /// Turns the project filter on, or off if it is already on this project.
    func toggleProjectFilter(_ key: String) {
        projectFilter = projectFilter == key ? nil : key
    }

    /// What the filtered project is called, for the bar over the wall.
    var projectFilterName: String? {
        projectFilter.map(BoardGrouping.projectName(forPath:))
    }

    /// The selected session's live snapshot, when the board still has one.
    var selectedSession: SessionSnapshot? {
        selectedKey.flatMap { board.session(for: $0) }
    }

    /// The parent of the selected session, when it has one and the board
    /// knows it. Drives the "spawned by" link in the trace header.
    var selectedParent: SessionSnapshot? {
        selectedSession?.identity.parent.flatMap { board.session(for: $0) }
    }

    /// What the selected session spawned, direct children only, in board
    /// order.
    ///
    /// Taken from the frame's own forest rather than from
    /// ``SessionSnapshot/children``, because that list is what the *adapter*
    /// recorded — it has no way to know about a `codex exec` the process table
    /// linked up three seconds ago, and the header should show both kinds of
    /// child the same way.
    var selectedChildren: [SessionSnapshot] {
        guard let key = selectedKey else { return [] }
        return board.tree.node(for: key)?.children.compactMap { board.session(for: $0.key) } ?? []
    }

    /// How many sessions the selected one has below it, at any depth.
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
    }

    /// Records something the ingest pipeline reported.
    func record(notice: String) {
        notices.append(notice)
        if notices.count > 24 { notices.removeFirst(notices.count - 24) }
    }

    /// Applies one frame.
    private func apply(_ frame: BoardSnapshot) {
        board = frame
        rebuildGroups()
        if !frame.sessions.isEmpty { hasEverSeenSession = true }

        if autoSelectsFirstSession, selectedKey == nil, let first = frame.sessions.first {
            selectedKey = first.key
            return  // the `didSet` already scheduled the load
        }

        // A frame that did not move the selected session cannot have added a
        // row to its trace, and re-reading on every tick would query four
        // times a second for a session nobody is touching.
        guard let key = selectedKey, let session = frame.session(for: key) else { return }
        guard session.lastEventAt != lastTraceEventAt else { return }
        lastTraceEventAt = session.lastEventAt
        reloadTrace()
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
