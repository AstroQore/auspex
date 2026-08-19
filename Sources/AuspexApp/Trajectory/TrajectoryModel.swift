import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation

/// Which face of the inspector is showing.
enum TrajectoryTab: String, CaseIterable, Identifiable {
    /// The numbers: where the step came from, what it cost, how long it took.
    case summary
    /// The text: what was said, in full.
    case preview
    /// The original record, read back off disk.
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .preview: "Preview"
        case .raw: "Raw"
        }
    }
}

/// Everything the Trajectory mode draws, for one session.
///
/// ## Why it keeps a fold instead of re-reading
///
/// The trace column re-reads its window on every frame that moved the session,
/// because a few hundred rows are cheaper to re-render than to reconcile. A
/// trajectory is a different shape of problem: it can hold thousands of steps,
/// it is laid out geometrically, and it has a selection and a brush a reload
/// would throw away. So it keeps a ``TrajectoryBuilder`` and feeds it only the
/// events it has not seen — one indexed seek per refresh instead of a window
/// scan, and no work at all for the steps that have not changed.
///
/// ## Where the work happens
///
/// The read is a `Task.detached`; the fold, the layout, and the filter run on
/// the main actor because they are O(n) over values and the results are what
/// the views observe. Each of the three is invalidated separately —
/// re-filtering on a keystroke does not re-lay-out the timeline, and dragging
/// the brush does not re-fold anything — which is what keeps a five-thousand
/// step session interactive.
///
/// ## No clock
///
/// The timeline has no ticker behind it. Its axis ends at the later of the last
/// observed event and the instant the layout last ran, and the layout runs when
/// events arrive — which for a live session is the only clock that means
/// anything. A `Canvas` redrawn thirty times a second to move a cursor two
/// pixels is the kind of cost § 4.1 of `AGENTS.md` exists to refuse.
@MainActor
@Observable
final class TrajectoryModel {
    /// How many events one trajectory folds. Enough for a session that has
    /// been running all day; bounded so a runaway one cannot make the window
    /// unresponsive.
    static let eventWindow = 20_000

    // MARK: What is drawn

    /// The session this is about.
    private(set) var key: SessionKey?
    /// Every step, oldest first.
    private(set) var steps: [TrajectoryStep] = []
    private(set) var turns: [TrajectoryTurn] = []
    private(set) var requests: [TrajectoryRequest] = []
    /// One bar per step, in step order.
    private(set) var spans: [TrajectorySpan] = []
    private(set) var ticks: [TrajectoryTick] = []
    /// The rows the list draws: the steps the brush and the query kept.
    private(set) var rows: [TrajectoryStep] = []
    /// What the gutter draws beside each row, by step id.
    ///
    /// Derived with the rows rather than in the row's body, because it depends
    /// on the row *above* — and a `LazyVStack` builds its rows in whatever
    /// order the viewport asks for, so a row cannot see its neighbour.
    private(set) var markers: [TrajectoryStep.ID: TrajectoryRowMarker] = [:]
    /// The ids the query matched, so the timeline can light them. Empty when
    /// there is no query — which means "highlight nothing", not "match
    /// nothing".
    private(set) var matches: Set<Int64> = []
    /// Where the live cursor sits, `0...1`, or `nil` for a finished session.
    private(set) var cursor: Double?
    /// `true` while the first read for a session is in flight.
    private(set) var isLoading = false
    /// `true` when the session has more events than one trajectory folds.
    private(set) var isTruncated = false
    /// How many event rows have been folded in. The window is counted in
    /// *events* rather than in steps, because that is what the store is asked
    /// for and what the facts bar tells the reader it stopped at.
    private(set) var loadedEventCount = 0

    // MARK: What the reader controls

    /// What the axis measures.
    var scale: TrajectoryScale = .duration {
        didSet { if oldValue != scale { relayout() } }
    }

    /// The brushed range of the timeline, or `nil` for the whole session.
    var brush: ClosedRange<Double>? {
        didSet { if oldValue != brush { refilter() } }
    }

    /// The search field's contents.
    var query: String = "" {
        didSet { if oldValue != query { refilter() } }
    }

    /// Whether the list scrolls to the newest step as steps arrive.
    var followsTail = true

    /// The step the inspector is about.
    var selectedID: TrajectoryStep.ID? {
        didSet { if oldValue != selectedID { selectionChanged() } }
    }

    /// Whether the inspector is on screen at all.
    var showsInspector = true

    var tab: TrajectoryTab = .summary {
        didSet { if tab == .raw { loadRaw() } }
    }

    /// The original record behind the selected step, once the Raw tab has
    /// asked for it.
    private(set) var raw: TrajectoryRawOutcome?
    private(set) var isLoadingRaw = false

    // MARK: Wiring

    private var builder = TrajectoryBuilder()
    private var repository: SessionRepository?
    private var isAlive = false
    private var loadTask: Task<Void, Never>?
    private var rawTask: Task<Void, Never>?
    /// Step id → index into ``steps``, so the selection is a lookup rather
    /// than a scan of five thousand values per render.
    private var indexByID: [TrajectoryStep.ID: Int] = [:]

    // MARK: - Selection

    var selectedStep: TrajectoryStep? {
        selectedID.flatMap { indexByID[$0] }.map { steps[$0] }
    }

    var selectedRequest: TrajectoryRequest? {
        guard let step = selectedStep, step.request > 0 else { return nil }
        return requests.first { $0.index == step.request }
    }

    var selectedTurn: TrajectoryTurn? {
        guard let step = selectedStep else { return nil }
        return turns.first { $0.index == step.turn }
    }

    /// Moves the selection down the visible rows, opening one if none is
    /// selected. Wrapping is deliberately not done: a list that jumps from the
    /// bottom back to the top loses a reader who was arrowing through a turn.
    func selectNext() {
        move(by: 1)
    }

    func selectPrevious() {
        move(by: -1)
    }

    private func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        guard let current = selectedID,
              let position = rows.firstIndex(where: { $0.id == current })
        else {
            selectedID = offset > 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = min(max(0, position + offset), rows.count - 1)
        selectedID = rows[next].id
    }

    private func selectionChanged() {
        raw = nil
        rawTask?.cancel()
        rawTask = nil
        if tab == .raw { loadRaw() }
    }

    // MARK: - Loading

    /// Points the trajectory at a session, throwing away everything about the
    /// previous one.
    func open(key: SessionKey?, repository: SessionRepository?, isAlive: Bool) {
        self.repository = repository
        self.isAlive = isAlive
        // Re-opening the same session is what entering the mode a second time
        // looks like: keep the fold, and ask only for whatever arrived while
        // the mode was off screen.
        guard key != self.key else { load(); return }
        self.key = key
        loadTask?.cancel()
        loadTask = nil
        rawTask?.cancel()
        rawTask = nil
        builder = TrajectoryBuilder()
        steps = []
        turns = []
        requests = []
        spans = []
        ticks = []
        rows = []
        markers = [:]
        matches = []
        indexByID = [:]
        brush = nil
        selectedID = nil
        raw = nil
        cursor = nil
        elapsed = nil
        errorCount = 0
        tokens = nil
        isTruncated = false
        loadedEventCount = 0
        followsTail = true
        isLoading = key != nil
        load()
    }

    /// Folds whatever has been written since the last read.
    ///
    /// Called from the board's frame loop, which already knows whether the
    /// session moved — so this does not check, it just asks for the tail, and
    /// an unchanged session costs one indexed seek that returns nothing.
    func refresh(isAlive: Bool) {
        self.isAlive = isAlive
        load()
    }

    private func load() {
        guard let key, let repository, !isTruncated else {
            if key == nil { isLoading = false }
            return
        }
        guard loadTask == nil else { return }

        let after = builder.lastEventID ?? 0
        let limit = Self.eventWindow - loadedEventCount
        guard limit > 0 else {
            isTruncated = true
            isLoading = false
            return
        }

        loadTask = Task { [weak self] in
            // Long enough to fold a whole turn's flush into one query, short
            // enough that opening the mode feels immediate.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }

            let events = await Task.detached(priority: .userInitiated) { () -> [StoredEvent] in
                (try? repository.events(key: key, after: after, limit: limit)) ?? []
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.key == key else { return }
                self.loadTask = nil
                self.isLoading = false
                guard !events.isEmpty else { return }
                self.loadedEventCount += events.count
                if self.loadedEventCount >= Self.eventWindow { self.isTruncated = true }
                self.builder.append(events)
                self.adopt()
            }
        }
    }

    /// Takes the fold's current answer and re-derives everything downstream.
    private func adopt() {
        steps = builder.steps
        turns = builder.turns
        requests = builder.requests
        indexByID = Dictionary(
            steps.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, latest in latest }
        )
        summarise()
        relayout()
    }

    /// Re-lays the timeline out. The one place the scale, the data, and the
    /// clock meet.
    private func relayout() {
        let now = isAlive ? Date() : nil
        spans = TrajectoryLayout.spans(for: steps, scale: scale, now: now)
        ticks = TrajectoryLayout.ticks(for: steps, scale: scale, now: now)
        cursor = TrajectoryLayout.cursor(for: steps, scale: scale, now: now)
        refilter()
    }

    /// Applies the brush and the query. Both are O(rows) and neither touches
    /// the fold, which is why a keystroke does not re-read the store.
    private func refilter() {
        let brushed = TrajectoryLayout.steps(steps, in: brush, spans: spans)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            rows = brushed
            matches = []
        } else {
            rows = brushed.filter { $0.matches(lowercasedQuery: needle) }
            matches = Set(steps.lazy.filter { $0.matches(lowercasedQuery: needle) }.map(\.id))
        }
        remark()
        // A selection the filter just hid would leave the inspector describing
        // a row nobody can see.
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// Works out what the gutter says beside each visible row.
    ///
    /// Against the *visible* rows rather than every step, so a brush that
    /// starts mid-turn still labels its first row with the turn it is in
    /// rather than leaving the reader to guess.
    private func remark() {
        var markers: [TrajectoryStep.ID: TrajectoryRowMarker] = [:]
        markers.reserveCapacity(rows.count)
        var previous: TrajectoryStep?
        for step in rows {
            if previous?.turn != step.turn {
                markers[step.id] = .turn(step.turn)
            } else if step.isError {
                markers[step.id] = .request(isError: true)
            } else if let previous, previous.request != step.request, step.request > 0 {
                markers[step.id] = .request(isError: false)
            }
            previous = step
        }
        self.markers = markers
    }

    /// The id the list scrolls to while following the tail.
    var tailID: TrajectoryStep.ID? { rows.last?.id }

    // MARK: - The raw record

    /// Reads the transcript line behind the selected step, once.
    func loadRaw() {
        guard raw == nil, !isLoadingRaw else { return }
        guard let step = selectedStep else { return }
        guard let ref = step.raw else {
            raw = .unavailable("Auspex recorded no source location for this event.")
            return
        }
        isLoadingRaw = true
        rawTask?.cancel()
        rawTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                TrajectoryRawReader.read(ref)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.selectedID == step.id else { return }
                self.isLoadingRaw = false
                self.raw = outcome
                self.rawTask = nil
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        rawTask?.cancel()
        loadTask = nil
        rawTask = nil
    }

    // MARK: - Facts for the header

    /// Whether the list is showing less than the whole session.
    var isFiltered: Bool {
        brush != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The whole session's span. Stored rather than computed: a SwiftUI body
    /// may run many times for one change, and a header that walked five
    /// thousand steps per render would be the most expensive thing on screen.
    private(set) var elapsed: TimeInterval?
    private(set) var errorCount = 0
    private(set) var tokens: TrajectoryTokens?

    private func summarise() {
        guard let first = steps.first else {
            elapsed = nil
            errorCount = 0
            tokens = nil
            return
        }
        var last = first.start
        var errors = 0
        for step in steps {
            last = max(last, step.end ?? step.start)
            if step.isError { errors += 1 }
        }
        let span = last.timeIntervalSince(first.start)
        elapsed = span > 0 ? span : nil
        errorCount = errors
        tokens = turns.compactMap(\.tokens).reduce(nil) { total, next in
            (total ?? TrajectoryTokens()).adding(next)
        }
    }
}
