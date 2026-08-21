import CoreGraphics
import Testing

@testable import AuspexCore

/// The waterfall's hover tooltip is the one piece of chrome in the app that is
/// positioned by hand, and the thing directly under it is the inspector's
/// header. These pin the rule that made that safe: whatever the pointer is
/// over, the bubble stays inside the timeline's own band.
@Suite("Trajectory · the hover tooltip stays in the timeline")
struct TrajectoryTooltipTests {
    /// The geometry the timeline actually draws with.
    private static let laneHeight: Double = 22
    private static let laneGap: Double = 5
    private static let axisHeight: Double = 16
    private static let lanes = 3
    private static var plotHeight: Double {
        Double(lanes) * laneHeight + Double(lanes - 1) * laneGap
    }
    private static var band: Double { plotHeight + axisHeight }

    private static let plot = CGSize(width: 582, height: plotHeight)

    private func band(_ index: Int) -> ClosedRange<Double> {
        TrajectoryLayout.laneBand(
            index: index,
            laneHeight: Self.laneHeight,
            laneGap: Self.laneGap
        )
    }

    @Test("the lanes tile the plot without overlapping")
    func laneBandsTile() {
        #expect(band(0) == 0...22)
        #expect(band(1) == 27...49)
        #expect(band(2) == 54...76)
        #expect(band(2).upperBound == Self.plotHeight)
    }

    /// The whole point. Three lanes, three tooltip heights, every pointer
    /// position across the plot — and the bubble never crosses the band's
    /// bottom edge, which is where the facts strip and the inspector begin.
    @Test("no lane, height or pointer puts the bubble below the timeline")
    func neverLeavesTheBand() {
        for lane in 0..<Self.lanes {
            for height in [38.0, 52.0, 64.0] {
                for pointer in stride(from: 0.0, through: 582, by: 17) {
                    let size = CGSize(width: 300, height: height)
                    let origin = TrajectoryLayout.tooltipOrigin(
                        pointer: pointer,
                        tooltip: size,
                        plot: Self.plot,
                        band: Self.band,
                        lane: band(lane)
                    )
                    #expect(origin.y >= 0)
                    #expect(origin.y + height <= Self.band)
                    #expect(origin.x >= 0)
                    #expect(origin.x + size.width <= Self.plot.width)
                }
            }
        }
    }

    @Test("a bar in the top lane is described from underneath")
    func topLaneHangsBelow() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 200,
            tooltip: CGSize(width: 300, height: 46),
            plot: Self.plot,
            band: Self.band,
            lane: band(0)
        )
        #expect(origin.y == 26)
    }

    /// The bottom lane has no room underneath it inside the band, so the
    /// bubble flips above the bar rather than hanging off the timeline.
    @Test("a bar in the bottom lane flips above itself")
    func bottomLaneFlipsAbove() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 200,
            tooltip: CGSize(width: 300, height: 46),
            plot: Self.plot,
            band: Self.band,
            lane: band(2)
        )
        #expect(origin.y == 4)
        #expect(origin.y + 46 < band(2).lowerBound)
    }

    @Test("the bubble is offset left of the pointer, but never off the left edge")
    func offsetLeftOfPointer() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 200,
            tooltip: CGSize(width: 300, height: 46),
            plot: Self.plot,
            band: Self.band,
            lane: band(0)
        )
        #expect(origin.x == 160)

        let atEdge = TrajectoryLayout.tooltipOrigin(
            pointer: 3,
            tooltip: CGSize(width: 300, height: 46),
            plot: Self.plot,
            band: Self.band,
            lane: band(0)
        )
        #expect(atEdge.x == 0)
    }

    @Test("the right-hand edge pins the bubble instead of letting it hang over")
    func clampedAtTheRightEdge() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 582,
            tooltip: CGSize(width: 300, height: 46),
            plot: Self.plot,
            band: Self.band,
            lane: band(1)
        )
        #expect(origin.x == 282)
    }

    /// A plot narrower than the bubble cannot be satisfied. It pins to the left
    /// rather than to a negative x, which would take the bubble off screen
    /// entirely — the trace column at its narrowest is exactly this case.
    @Test("a plot narrower than the bubble pins it left rather than off screen")
    func narrowerThanTheBubble() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 40,
            tooltip: CGSize(width: 300, height: 46),
            plot: CGSize(width: 180, height: Self.plotHeight),
            band: Self.band,
            lane: band(0)
        )
        #expect(origin.x == 0)
    }

    /// And a bubble taller than the whole band still starts at the top of it,
    /// which is the least-wrong answer: it covers lanes, never the inspector.
    @Test("a bubble taller than the band starts at the top of it")
    func tallerThanTheBand() {
        let origin = TrajectoryLayout.tooltipOrigin(
            pointer: 100,
            tooltip: CGSize(width: 300, height: 400),
            plot: Self.plot,
            band: Self.band,
            lane: band(2)
        )
        #expect(origin.y == 0)
    }
}
