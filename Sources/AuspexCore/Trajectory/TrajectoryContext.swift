import Foundation

/// How full the context window was, at one point in a trajectory.
///
/// Anchored to a *step index* rather than to a timestamp, and that is the whole
/// design decision. The waterfall's x axis is a clock under
/// ``TrajectoryScale/duration`` and a count under the other two, so a reading
/// placed by wall-clock time would land somewhere meaningless in two of the
/// three modes. Anchoring it to the last step that had actually happened when
/// the harness wrote the number down puts it in the right place in all three.
public struct TrajectoryContextReading: Hashable, Sendable {
    /// The index of the newest step at the moment of the reading.
    public let stepIndex: Int
    /// Tokens in the window.
    public let used: Int
    /// The window, when anything could say how big it is.
    public let window: Int?
    /// The source's own timestamp.
    public let at: Date
    /// `true` when the window was looked up from the model rather than
    /// recorded — see `ContextUsage.Source`.
    public let isDerived: Bool

    public init(stepIndex: Int, used: Int, window: Int?, at: Date, isDerived: Bool) {
        self.stepIndex = stepIndex
        self.used = used
        self.window = window
        self.at = at
        self.isDerived = isDerived
    }

    /// The fill, or `nil` when nothing said how big the window is. A reading
    /// with no denominator cannot be drawn on a lane whose height *is* the
    /// denominator.
    public var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return Double(used) / Double(window)
    }
}

/// The context lane, in unit coordinates: a step line and the compactions that
/// cut it.
///
/// Unit coordinates for the same reason ``TrajectorySpan`` uses them — the
/// layout is a pure function of the data, and the view multiplies by whatever
/// width and height it was given. A resize redraws without recomputing.
public struct TrajectoryContextLine: Hashable, Sendable {
    /// One reading, placed.
    public struct Point: Hashable, Sendable {
        /// Where along the timeline, `0...1`.
        public let x: Double
        /// How full, `0...1`. Clamped at 1: a fill that overran its own window
        /// is drawn at the top rather than outside the lane, and the number in
        /// the tooltip is the one that says so.
        public let fill: Double
        /// The raw counts, for the tooltip.
        public let used: Int
        public let window: Int?

        public init(x: Double, fill: Double, used: Int, window: Int?) {
            self.x = min(max(0, x), 1)
            self.fill = min(max(0, fill), 1)
            self.used = used
            self.window = window
        }
    }

    /// The readings, oldest first.
    public let points: [Point]
    /// Where each compaction cut the line, `0...1`. Drawn as a rule, because
    /// the drop beside it is not the model using fewer tokens — it is the
    /// harness throwing away what it had.
    public let compactions: [Double]
    /// `true` when every reading's window was looked up rather than recorded.
    /// The lane is drawn dashed when it is, for the same reason the card's
    /// gauge is.
    public let isDerived: Bool

    public var isEmpty: Bool { points.isEmpty }

    /// The fullest the window ever got, `0...1`.
    public var peak: Double { points.map(\.fill).max() ?? 0 }

    /// The newest reading, which is what a lane label says out loud.
    public var latest: Point? { points.last }

    public init(points: [Point], compactions: [Double], isDerived: Bool) {
        self.points = points
        self.compactions = compactions
        self.isDerived = isDerived
    }

    /// Nothing to draw. What every harness but three answers.
    public static let empty = TrajectoryContextLine(
        points: [], compactions: [], isDerived: false
    )
}

extension TrajectoryLayout {
    /// Places context readings and compaction markers against a laid-out
    /// waterfall.
    ///
    /// Pure and total, like everything else here: readings that name a step
    /// the spans do not have are dropped rather than clamped onto the nearest
    /// one, and a reading whose window nobody recorded is dropped too — a lane
    /// whose height is the window cannot draw a fill that has no denominator.
    /// Dropping all of them yields ``TrajectoryContextLine/empty``, and the
    /// view draws no lane at all, which is the right answer for the five
    /// harnesses that record nothing.
    ///
    /// - Parameters:
    ///   - readings: what the builder folded, in observation order.
    ///   - compactionSteps: the step index of each compaction.
    ///   - spans: the laid-out waterfall, one span per step in step order.
    public static func contextLine(
        readings: [TrajectoryContextReading],
        compactionSteps: [Int],
        spans: [TrajectorySpan]
    ) -> TrajectoryContextLine {
        guard !spans.isEmpty else { return .empty }
        var points: [TrajectoryContextLine.Point] = []
        points.reserveCapacity(readings.count)
        var everyWindowDerived = true

        for reading in readings {
            guard spans.indices.contains(reading.stepIndex),
                  let fraction = reading.fraction
            else { continue }
            // The end of the step, because the reading was taken after it: the
            // harness writes its token count once the model has answered.
            points.append(
                TrajectoryContextLine.Point(
                    x: spans[reading.stepIndex].end,
                    fill: fraction,
                    used: reading.used,
                    window: reading.window
                )
            )
            if !reading.isDerived { everyWindowDerived = false }
        }
        guard !points.isEmpty else { return .empty }

        let cuts = compactionSteps
            .filter { spans.indices.contains($0) }
            .map { spans[$0].start }

        return TrajectoryContextLine(
            points: points,
            compactions: cuts,
            isDerived: everyWindowDerived
        )
    }
}
