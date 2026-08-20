import AuspexCore
import CoreGraphics
import Foundation
import Testing

/// What a walk promises: every leg is axis-aligned, every corner is a real
/// corner, and the walker faces the way it is going.
@Suite("Scene routes")
struct SceneRouteTests {
    private static let lane: CGFloat = 200
    private static let trunk: CGFloat = 14

    private static func route(
        from: CGPoint,
        to: CGPoint,
        departure: CGFloat = SceneRouteTests.lane,
        arrival: CGFloat = SceneRouteTests.lane
    ) -> [CGPoint] {
        SceneRoute.waypoints(
            from: from, to: to, lanes: (departure, arrival), trunk: trunk
        )
    }

    @Test("Every leg of a walk runs along one axis")
    func legsAreAxisAligned() {
        let points = Self.route(
            from: CGPoint(x: 80, y: 60),
            to: CGPoint(x: 620, y: 900),
            departure: 200,
            arrival: 840
        )
        for leg in SceneRoute.legs(points) {
            let straight = abs(leg.from.x - leg.to.x) < 0.001
                || abs(leg.from.y - leg.to.y) < 0.001
            #expect(straight)
        }
    }

    @Test("A walk starts where the walker is and ends on the seat")
    func endpointsAreKept() {
        let from = CGPoint(x: 80, y: 60)
        let to = CGPoint(x: 620, y: 900)
        let points = Self.route(from: from, to: to, departure: 200, arrival: 840)
        #expect(points.first == from)
        #expect(points.last == to)
    }

    @Test("Inside one strip a walk is out to the path, along it, and back in")
    func oneStripIsThreeLegs() {
        let points = Self.route(from: CGPoint(x: 60, y: 120), to: CGPoint(x: 400, y: 120))
        #expect(points.count == 4)
        #expect(points[1] == CGPoint(x: 60, y: Self.lane))
        #expect(points[2] == CGPoint(x: 400, y: Self.lane))
    }

    @Test("Between two strips the walk goes down the gutter")
    func twoStripsUseTheTrunk() {
        let points = Self.route(
            from: CGPoint(x: 300, y: 100),
            to: CGPoint(x: 500, y: 900),
            departure: 200,
            arrival: 840
        )
        #expect(points.contains(CGPoint(x: Self.trunk, y: 200)))
        #expect(points.contains(CGPoint(x: Self.trunk, y: 840)))
    }

    @Test("A step that goes nowhere is not a step")
    func degenerateWalksCollapse() {
        let here = CGPoint(x: 120, y: 200)
        #expect(Self.route(from: here, to: here) == [here])
        #expect(SceneRoute.legs([here]).isEmpty)
        #expect(SceneRoute.duration(of: [here], speed: 200) == 0)
    }

    @Test("A seat already on the path is walked to in a straight line")
    func alreadyOnTheLane() {
        let points = Self.route(
            from: CGPoint(x: 60, y: Self.lane), to: CGPoint(x: 400, y: Self.lane)
        )
        #expect(points == [CGPoint(x: 60, y: Self.lane), CGPoint(x: 400, y: Self.lane)])
    }

    @Test("A walker faces the way it is going, and down means towards the reader")
    func facing() {
        // Layout space is y-down, so a bigger y is nearer the reader.
        #expect(SceneRoute.direction(from: .zero, to: CGPoint(x: 0, y: 10)) == .down)
        #expect(SceneRoute.direction(from: CGPoint(x: 0, y: 10), to: .zero) == .up)
        #expect(SceneRoute.direction(from: .zero, to: CGPoint(x: 10, y: 0)) == .right)
        #expect(SceneRoute.direction(from: CGPoint(x: 10, y: 0), to: .zero) == .left)
    }

    @Test("Left is the right-facing strip, mirrored")
    func leftIsMirrored() {
        #expect(SceneWalkDirection.left.poseName == SceneWalkDirection.right.poseName)
        #expect(SceneWalkDirection.left.isMirrored)
        #expect(!SceneWalkDirection.right.isMirrored)
        #expect(SceneWalkDirection.up.poseName == "walkUp")
        #expect(SceneWalkDirection.down.poseName == "walkDown")
    }

    @Test("A walk is timed by the distance actually walked, corners included")
    func durationFollowsTheCorners() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)
        ]
        #expect(SceneRoute.length(of: points) == 700)
        #expect(SceneRoute.duration(of: points, speed: 100, limit: 60) == 7)
    }

    @Test("A walk across a very large map is played faster rather than watched")
    func durationIsCapped() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40_000, y: 0)]
        #expect(SceneRoute.duration(of: points, speed: 208, limit: 6) == 6)
    }

    @Test("A walk knows the rectangle it happens in")
    func boundsCoverTheWholeWalk() {
        let points = [
            CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 300), CGPoint(x: -20, y: 300)
        ]
        let bounds = SceneRoute.bounds(of: points)
        #expect(bounds.minX == -20)
        #expect(bounds.maxX == 100)
        #expect(bounds.minY == 40)
        #expect(bounds.maxY == 300)
    }
}
