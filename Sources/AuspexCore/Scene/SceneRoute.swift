import CoreGraphics
import Foundation

/// Which way somebody is facing while they walk.
///
/// Four, because that is what a character package draws: `walkDown`, `walkUp`,
/// and `walkRight` — with left being `walkRight` mirrored, which is what every
/// 3/4 pixel scene has done since the eighties and what stops a package author
/// from having to draw the same walk twice.
public enum SceneWalkDirection: String, Sendable, Hashable, CaseIterable {
    case up, down, left, right

    /// Whether the strip is drawn flipped. Only `left` is.
    public var isMirrored: Bool { self == .left }

    /// The pose whose strip plays for this direction.
    public var poseName: String {
        switch self {
        case .up: "walkUp"
        case .down: "walkDown"
        case .left, .right: "walkRight"
        }
    }
}

/// One straight stretch of a walk.
public struct SceneWalkLeg: Sendable, Equatable {
    public let from: CGPoint
    public let to: CGPoint
    public let direction: SceneWalkDirection

    public init(from: CGPoint, to: CGPoint, direction: SceneWalkDirection) {
        self.from = from
        self.to = to
        self.direction = direction
    }

    /// How far it is, in layout points.
    public var distance: CGFloat {
        abs(to.x - from.x) + abs(to.y - from.y)
    }
}

/// Getting from one seat to another without a pathfinder.
///
/// ## Why there is no A*
///
/// There is nothing to route around. The map is three strips with a gutter
/// down the left of it and a walkway through each strip, and every seat on it
/// faces one of those walkways. So a route is always the same three ideas —
/// step out to the walkway, follow it, step in to the seat — and between two
/// strips it is those three with a trip down the gutter in the middle.
///
/// Doing it this way is not only simpler, it is the only version that can be
/// animated for free: every leg is axis-aligned, so it is one `SKAction.move`
/// with one walk strip playing over it, and a walk of any length costs the
/// render loop the same as standing still. A diagonal path would need a facing
/// decided per frame, and a curved one would need a callback — which is
/// exactly the per-frame Swift the scene's budget is spent avoiding.
///
/// Coordinates are **layout space** throughout: y-down, the floor plan's own
/// space, the same space ``SceneFrame`` is in.
public enum SceneRoute {
    /// Where a walk turns.
    ///
    /// - Parameters:
    ///   - from: where the walker is now.
    ///   - to: the seat it is heading for.
    ///   - lanes: the walkway to leave by and the walkway to arrive on. The
    ///     same value for both means a walk inside one strip.
    ///   - trunk: the `x` of the gutter that joins the strips. Only used when
    ///     the two lanes differ.
    /// - Returns: `from`, every corner, and `to` — with anything that would be
    ///   a zero-length or dead-straight step already removed, so the count is
    ///   the number of corners and not an artefact of the arithmetic.
    public static func waypoints(
        from: CGPoint,
        to: CGPoint,
        lanes: (departure: CGFloat, arrival: CGFloat),
        trunk: CGFloat
    ) -> [CGPoint] {
        var points: [CGPoint] = [from]
        if abs(lanes.departure - lanes.arrival) < epsilon {
            // One strip: out to the walkway, along it, back in.
            let lane = lanes.departure
            points.append(CGPoint(x: from.x, y: lane))
            points.append(CGPoint(x: to.x, y: lane))
        } else {
            // Two strips: out to this walkway, along it to the gutter, down
            // the gutter, along the other walkway, back in.
            points.append(CGPoint(x: from.x, y: lanes.departure))
            points.append(CGPoint(x: trunk, y: lanes.departure))
            points.append(CGPoint(x: trunk, y: lanes.arrival))
            points.append(CGPoint(x: to.x, y: lanes.arrival))
        }
        points.append(to)
        return simplified(points)
    }

    /// The legs a walk is made of, each with the way the walker faces along it.
    public static func legs(_ waypoints: [CGPoint]) -> [SceneWalkLeg] {
        guard waypoints.count > 1 else { return [] }
        var legs: [SceneWalkLeg] = []
        legs.reserveCapacity(waypoints.count - 1)
        for index in 1..<waypoints.count {
            let from = waypoints[index - 1]
            let to = waypoints[index]
            legs.append(SceneWalkLeg(from: from, to: to, direction: direction(from: from, to: to)))
        }
        return legs
    }

    /// How long a walk takes at a constant speed, in seconds.
    ///
    /// Manhattan distance rather than straight-line, because the walk *is*
    /// Manhattan: a route that turned a corner would otherwise be timed as
    /// though it had cut across it.
    ///
    /// - Parameters:
    ///   - waypoints: the corners, as ``waypoints(from:to:lanes:trunk:)``
    ///     returns them.
    ///   - speed: layout points a second.
    ///   - limit: the longest a walk is allowed to take. A map that has grown
    ///     to forty projects can put two seats a very long way apart, and a
    ///     character that spends half a minute in transit is a character
    ///     nobody sees arrive; past the limit the whole walk is simply played
    ///     faster.
    public static func duration(
        of waypoints: [CGPoint],
        speed: CGFloat,
        limit: TimeInterval = 6
    ) -> TimeInterval {
        guard speed > 0 else { return 0 }
        let distance = length(of: waypoints)
        guard distance > 0 else { return 0 }
        return min(limit, TimeInterval(distance / speed))
    }

    /// The whole walk, in layout points.
    public static func length(of waypoints: [CGPoint]) -> CGFloat {
        guard waypoints.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<waypoints.count {
            total += abs(waypoints[index].x - waypoints[index - 1].x)
            total += abs(waypoints[index].y - waypoints[index - 1].y)
        }
        return total
    }

    /// The smallest rectangle a walk happens inside, for the cull.
    public static func bounds(of waypoints: [CGPoint]) -> CGRect {
        guard let first = waypoints.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for point in waypoints.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

    /// Which way somebody walking this leg faces.
    ///
    /// Layout space is y-down, so a leg with a larger `y` at the end of it is
    /// walking *towards* the reader, which is `walkDown`. Getting this
    /// backwards is invisible in a diff and obvious as an office full of
    /// people moonwalking.
    public static func direction(from: CGPoint, to: CGPoint) -> SceneWalkDirection {
        let dx = to.x - from.x
        let dy = to.y - from.y
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .down : .up
    }

    /// Drops the points that are not corners: a step that goes nowhere, and a
    /// middle point that its neighbours already walk straight through.
    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            guard let last = result.last else {
                result.append(point)
                continue
            }
            if abs(point.x - last.x) < epsilon, abs(point.y - last.y) < epsilon { continue }
            result.append(point)
        }
        guard result.count > 2 else { return result }
        var corners: [CGPoint] = [result[0]]
        for index in 1..<(result.count - 1) {
            let before = corners[corners.count - 1]
            let here = result[index]
            let after = result[index + 1]
            let straightX = abs(before.x - here.x) < epsilon && abs(here.x - after.x) < epsilon
            let straightY = abs(before.y - here.y) < epsilon && abs(here.y - after.y) < epsilon
            if straightX || straightY { continue }
            corners.append(here)
        }
        corners.append(result[result.count - 1])
        return corners
    }

    /// Closer than this and two points are the same point. A tenth of a layout
    /// point is a twentieth of an art pixel.
    private static let epsilon: CGFloat = 0.1
}
