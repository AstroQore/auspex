import Foundation

/// What the waterfall's horizontal axis measures.
///
/// The three answers are genuinely different questions, which is why this is a
/// mode and not a zoom:
///
/// - **Duration** is the truth about *time*. A session that spent four minutes
///   in one `swift build` looks like one long bar and a scatter of slivers,
///   because that is what happened.
/// - **Turns** gives every turn the same width. The question it answers is
///   *what is the shape of each turn* — which is unreadable in Duration the
///   moment one turn is fifty times longer than its neighbours.
/// - **Calls** gives every step the same width. It is the sequence, with time
///   taken out entirely: what happened, in order, and how much of it there was.
public enum TrajectoryScale: String, CaseIterable, Identifiable, Sendable, Codable {
    case duration
    case turns
    case calls

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .duration: "Duration"
        case .turns: "Turns"
        case .calls: "Calls"
        }
    }

    /// What the axis is measuring, for the tooltip.
    public var axisDescription: String {
        switch self {
        case .duration: "proportional to elapsed time"
        case .turns: "one equal column per turn"
        case .calls: "one equal column per step"
        }
    }
}

/// One bar on the waterfall, in unit coordinates.
///
/// `start` and `end` are fractions of the timeline's width, so the layout is a
/// pure function of the data and the view multiplies by whatever width it got.
/// That split is what lets the layout be tested without a window and lets the
/// `Canvas` be redrawn on a resize without recomputing anything.
public struct TrajectorySpan: Identifiable, Hashable, Sendable {
    /// The step's id, so a bar and a row agree about what they are.
    public let id: Int64
    /// The step's position in the trajectory. ``TrajectoryLayout/spans(for:scale:now:)``
    /// returns one span per step in step order, so this is also the index into
    /// both arrays.
    public let index: Int
    public let lane: TrajectoryLane
    public let role: TrajectoryRole
    /// Left edge, `0...1`.
    public let start: Double
    /// Right edge, `0...1`. Never less than ``start``.
    public let end: Double
    public let isError: Bool

    public var width: Double { end - start }

    public init(
        id: Int64,
        index: Int,
        lane: TrajectoryLane,
        role: TrajectoryRole,
        start: Double,
        end: Double,
        isError: Bool
    ) {
        self.id = id
        self.index = index
        self.lane = lane
        self.role = role
        self.start = min(max(0, start), 1)
        self.end = min(max(self.start, end), 1)
        self.isError = isError
    }

    /// Whether this bar is inside — or crosses — a brushed range.
    public func intersects(_ range: ClosedRange<Double>) -> Bool {
        start <= range.upperBound && end >= range.lowerBound
    }
}

/// A mark on the time axis.
public struct TrajectoryTick: Identifiable, Hashable, Sendable {
    /// Where the mark sits, `0...1`.
    public let position: Double
    /// What it says. Short: the axis is 20 points tall.
    public let label: String
    /// Whether it divides two columns rather than measuring a distance. A
    /// division is drawn as a full-height rule; a measurement is not.
    public let isDivider: Bool

    public var id: Double { position }

    public init(position: Double, label: String, isDivider: Bool = false) {
        self.position = position
        self.label = label
        self.isDivider = isDivider
    }
}

/// Turns steps into bars, ticks, and the answer to "what did the reader just
/// select".
///
/// Every function here is pure and total: an empty trajectory yields no bars,
/// a session whose events all share one timestamp falls back to equal columns
/// rather than dividing by zero, and a brush outside the data selects nothing.
public enum TrajectoryLayout {
    /// One span per step, in step order.
    ///
    /// - Parameters:
    ///   - steps: the trajectory, oldest first.
    ///   - scale: what the axis measures.
    ///   - now: the instant a live session's timeline runs up to. Pass `nil`
    ///     for a finished session, and the axis ends at its last event instead
    ///     of at the wall clock.
    public static func spans(
        for steps: [TrajectoryStep],
        scale: TrajectoryScale,
        now: Date? = nil
    ) -> [TrajectorySpan] {
        guard !steps.isEmpty else { return [] }
        switch scale {
        case .duration: return durationSpans(steps, now: now)
        case .turns: return turnSpans(steps, now: now)
        case .calls: return callSpans(steps)
        }
    }

    // MARK: Duration

    private static func durationSpans(_ steps: [TrajectoryStep], now: Date?) -> [TrajectorySpan] {
        let bounds = self.bounds(of: steps, now: now)
        let total = bounds.end.timeIntervalSince(bounds.start)
        // Everything in one instant. Equal columns are the only honest
        // drawing: a proportional one would be a division by zero, and a
        // single stacked bar would claim the steps overlapped.
        guard total > 0 else { return callSpans(steps) }

        return steps.enumerated().map { index, step in
            let close = closing(step, at: index, in: steps, fallback: bounds.end)
            return TrajectorySpan(
                id: step.id,
                index: index,
                lane: step.role.lane,
                role: step.role,
                start: step.start.timeIntervalSince(bounds.start) / total,
                end: close.timeIntervalSince(bounds.start) / total,
                isError: step.isError
            )
        }
    }

    // MARK: Turns

    private static func turnSpans(_ steps: [TrajectoryStep], now: Date?) -> [TrajectorySpan] {
        // Column order is the order turns appear in the steps, which is the
        // order they happened — not `Set` order, which would shuffle the axis
        // between two renders of the same data.
        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for (index, step) in steps.enumerated() {
            if members[step.turn] == nil {
                members[step.turn] = []
                order.append(step.turn)
            }
            members[step.turn, default: []].append(index)
        }
        let columns = Double(order.count)
        var spans = [TrajectorySpan?](repeating: nil, count: steps.count)

        for (column, turn) in order.enumerated() {
            let indices = members[turn] ?? []
            let left = Double(column) / columns
            let width = 1 / columns
            let group = indices.map { steps[$0] }
            let bounds = self.bounds(of: group, now: nil)
            let total = bounds.end.timeIntervalSince(bounds.start)

            for (ordinal, index) in indices.enumerated() {
                let step = steps[index]
                let fraction: (Double, Double)
                if total > 0 {
                    let close = closing(step, at: index, in: steps, fallback: bounds.end)
                    fraction = (
                        step.start.timeIntervalSince(bounds.start) / total,
                        min(1, close.timeIntervalSince(bounds.start) / total)
                    )
                } else {
                    let slot = 1 / Double(indices.count)
                    fraction = (Double(ordinal) * slot, Double(ordinal + 1) * slot)
                }
                spans[index] = TrajectorySpan(
                    id: step.id,
                    index: index,
                    lane: step.role.lane,
                    role: step.role,
                    start: left + fraction.0 * width,
                    end: left + fraction.1 * width,
                    isError: step.isError
                )
            }
        }
        return spans.compactMap { $0 }
    }

    // MARK: Calls

    private static func callSpans(_ steps: [TrajectoryStep]) -> [TrajectorySpan] {
        let width = 1 / Double(steps.count)
        return steps.enumerated().map { index, step in
            TrajectorySpan(
                id: step.id,
                index: index,
                lane: step.role.lane,
                role: step.role,
                start: Double(index) * width,
                end: Double(index + 1) * width,
                isError: step.isError
            )
        }
    }

    // MARK: Shared geometry

    /// The interval a set of steps covers.
    ///
    /// The end is the latest thing observed — a recorded close, a start, or the
    /// wall clock for a session that is still running — so a live timeline
    /// grows to the right instead of pinning itself to its last event.
    static func bounds(of steps: [TrajectoryStep], now: Date?) -> (start: Date, end: Date) {
        guard let first = steps.first else {
            let instant = now ?? Date()
            return (instant, instant)
        }
        var start = first.start
        var end = first.end ?? first.start
        for step in steps {
            start = min(start, step.start)
            end = max(end, step.end ?? step.start)
        }
        if let now { end = max(end, now) }
        return (start, max(start, end))
    }

    /// When a step's bar stops.
    ///
    /// A recorded close where the log has one. Otherwise the next step's start
    /// — which is not a guess about the step's duration but the plain fact of
    /// when the next thing happened, and is what makes a model generation read
    /// as an interval rather than as a hairline.
    private static func closing(
        _ step: TrajectoryStep,
        at index: Int,
        in steps: [TrajectoryStep],
        fallback: Date
    ) -> Date {
        if let end = step.end { return max(step.start, end) }
        let next = steps.indices.contains(index + 1) ? steps[index + 1].start : fallback
        return max(step.start, min(next, fallback))
    }

    // MARK: Ticks

    /// The axis's marks, at most `count` of them.
    public static func ticks(
        for steps: [TrajectoryStep],
        scale: TrajectoryScale,
        now: Date? = nil,
        count: Int = 6
    ) -> [TrajectoryTick] {
        guard !steps.isEmpty, count > 1 else { return [] }
        switch scale {
        case .duration:
            let bounds = self.bounds(of: steps, now: now)
            let total = bounds.end.timeIntervalSince(bounds.start)
            guard total > 0 else { return [] }
            return (0..<count).map { step in
                let fraction = Double(step) / Double(count - 1)
                return TrajectoryTick(
                    position: fraction,
                    label: step == 0 ? "0s" : DurationFormat.short(total * fraction)
                )
            }
        case .turns:
            var order: [Int] = []
            var seen: Set<Int> = []
            for step in steps where seen.insert(step.turn).inserted { order.append(step.turn) }
            let columns = Double(order.count)
            let stride = Swift.max(1, Int((columns / Double(count)).rounded(.up)))
            return order.enumerated().compactMap { column, turn in
                guard column.isMultiple(of: stride) else { return nil }
                return TrajectoryTick(
                    position: Double(column) / columns,
                    label: turn == 0 ? "pre" : "T\(turn)",
                    isDivider: true
                )
            }
        case .calls:
            let total = Double(steps.count)
            let stride = Swift.max(1, Int((total / Double(count)).rounded(.up)))
            return Swift.stride(from: 0, to: steps.count, by: stride).map { index in
                TrajectoryTick(
                    position: Double(index) / total,
                    label: "#\(index + 1)",
                    isDivider: true
                )
            }
        }
    }

    // MARK: Brushing

    /// The steps a brushed range selects.
    ///
    /// `spans` must be the array ``spans(for:scale:now:)`` returned for the
    /// same `steps`, which is why they are taken as a pair rather than
    /// recomputed here: a filter that laid the timeline out a second time
    /// could disagree with the bars the reader actually dragged over.
    public static func steps(
        _ steps: [TrajectoryStep],
        in brush: ClosedRange<Double>?,
        spans: [TrajectorySpan]
    ) -> [TrajectoryStep] {
        guard let brush else { return steps }
        guard spans.count == steps.count else { return steps }
        return zip(steps, spans).compactMap { step, span in
            span.intersects(brush) ? step : nil
        }
    }

    /// Where "now" sits on the axis, for the live cursor.
    ///
    /// Only Duration has a place to put it: the other two scales have taken
    /// time off the axis, so a cursor on them would be pointing at nothing.
    public static func cursor(
        for steps: [TrajectoryStep],
        scale: TrajectoryScale,
        now: Date?
    ) -> Double? {
        guard scale == .duration, let now, !steps.isEmpty else { return nil }
        let bounds = self.bounds(of: steps, now: now)
        let total = bounds.end.timeIntervalSince(bounds.start)
        guard total > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(bounds.start) / total))
    }
}
