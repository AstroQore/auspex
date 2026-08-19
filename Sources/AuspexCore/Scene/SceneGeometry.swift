import CoreGraphics
import Foundation

/// The one place the office's two coordinate spaces are told apart.
///
/// ``SceneLayout`` works in **layout space**: origin at the top left of the
/// building, `y` increasing downward, the way a floor plan is read. SpriteKit
/// works in **scene space**, which is the same thing with `y` up. The flip is
/// one negation, and the only reason it is a named function rather than a
/// `-` scattered through the renderer is that a sign error here is invisible
/// in a diff and obvious only as an office drawn upside down.
public enum SceneGeometry {
    /// A layout-space point in SpriteKit's world.
    public static func scene(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: -point.y)
    }

    /// A layout-space rectangle in SpriteKit's world.
    public static func scene(from rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }

    /// A scene-space point back on the floor plan.
    public static func layout(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: -point.y)
    }

    /// A scene-space rectangle back on the floor plan.
    public static func layout(from rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The mapping between the whole map and the small picture of it in the
/// corner.
///
/// ## What a minimap is for here
///
/// Once the office is bigger than the window — which is any day with more than
/// a handful of repositories open — the camera can be pointed at a room with
/// no way to tell how much building is off to the left. The minimap answers
/// two questions and no others: *how much is there* and *where am I in it*.
/// So it draws one rectangle per room and one for the viewport, and clicking
/// it moves the camera. It is not a second scene: no desks, no characters, no
/// motion.
///
/// ## Coordinates
///
/// Both sides of this mapping are y-down — the map in layout space, the
/// minimap in the drawing space of the overlay that holds it — so nothing is
/// flipped here. Callers holding a scene-space rectangle (the camera's
/// viewport) convert it with ``SceneGeometry/layout(from:)-8dtqk`` first.
///
/// The world is fitted into the frame with one scale on both axes and centred
/// in whatever is left over, so a tall office stays tall and a wide one stays
/// wide. A minimap that stretched the map to fill its box would be a picture
/// of a different building.
public struct SceneMinimap: Sendable, Equatable {
    /// The map, in layout space.
    public let world: CGRect
    /// The box the minimap is drawn in, in its own space.
    public let frame: CGRect
    /// Points of frame per point of world.
    public let scale: CGFloat
    /// Where the world's origin lands inside ``frame``.
    public let origin: CGPoint

    /// Fits `world` inside `frame`.
    public init(world: CGRect, in frame: CGRect) {
        self.world = world
        self.frame = frame
        guard world.width > 0, world.height > 0, frame.width > 0, frame.height > 0 else {
            self.scale = 1
            self.origin = frame.origin
            return
        }
        let scale = min(frame.width / world.width, frame.height / world.height)
        self.scale = scale
        self.origin = CGPoint(
            x: frame.minX + (frame.width - world.width * scale) / 2 - world.minX * scale,
            y: frame.minY + (frame.height - world.height * scale) / 2 - world.minY * scale
        )
    }

    /// Where a point of the map lands on the minimap.
    public func point(_ worldPoint: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + worldPoint.x * scale, y: origin.y + worldPoint.y * scale)
    }

    /// Where a rectangle of the map lands on the minimap.
    public func rect(_ worldRect: CGRect) -> CGRect {
        CGRect(
            x: origin.x + worldRect.minX * scale,
            y: origin.y + worldRect.minY * scale,
            width: worldRect.width * scale,
            height: worldRect.height * scale
        )
    }

    /// Where a click on the minimap points the camera.
    public func worldPoint(_ point: CGPoint) -> CGPoint {
        guard scale > 0 else { return CGPoint(x: world.midX, y: world.midY) }
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    /// The box a minimap of `world` should be drawn in, no larger than
    /// `maximum` on either side and never thinner than `minimum`.
    ///
    /// The overlay is sized to the map rather than fixed, so a wide office
    /// gets a wide strip and a tall one a tall panel — a fixed square would
    /// spend most of its area on nothing and shrink the part that matters.
    public static func frame(
        for world: CGRect,
        maximum: CGSize,
        minimum: CGFloat = 44
    ) -> CGRect {
        guard world.width > 0, world.height > 0 else { return .zero }
        let scale = min(maximum.width / world.width, maximum.height / world.height)
        return CGRect(
            x: 0,
            y: 0,
            width: max(minimum, world.width * scale),
            height: max(minimum, world.height * scale)
        )
    }
}
