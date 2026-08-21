import AgentSessionLive
import CoreGraphics
import Foundation

/// What is under the pointer, answered from the floor plan.
///
/// ## Why the scene graph is the wrong place to ask
///
/// `SKScene.nodes(at:)` walks every node in the scene, allocates an array of
/// whatever it finds, and answers in the coordinate space of a camera that is
/// mid-flight. On a real day the office holds several hundred desks of a dozen
/// nodes each, and a trackpad delivers mouse-moved events far faster than the
/// scene is drawn — so hovering was measured spending around a ninth of the
/// main thread walking the same graph a hundred times a second to arrive at
/// the same answer.
///
/// The layout already knows where everything is, in a space that does not move
/// when the camera does. So the hit test is a lookup over rectangles: rooms
/// first, which are few, then only the desks of the room the pointer is in.
/// Nothing here allocates, nothing here touches SpriteKit, and the arithmetic
/// is testable without a window.
///
/// Coordinates are **layout space** throughout — y-down, the floor plan's own
/// space, which is also what a click on the scroll view's document view arrives
/// in.
public struct SceneHitIndex: Sendable, Equatable {
    /// One workstation's clickable area.
    public struct Desk: Sendable, Equatable {
        /// The desk, which outlives whoever is sitting at it.
        public let slotID: String
        /// Who is sitting there, when anybody is.
        public let session: SessionKey?
        /// The area a click on it lands in, in layout space.
        public let rect: CGRect

        public init(slotID: String, session: SessionKey?, rect: CGRect) {
            self.slotID = slotID
            self.session = session
            self.rect = rect
        }
    }

    /// The rooms, in drawing order.
    public let floors: [SceneFloor]
    /// The annexes, in drawing order.
    public let zones: [SceneZoneArea]
    /// Each room's desks, by the room's allocation index.
    private let desks: [Int: [Desk]]
    /// Each annex's chairs and benches, by the annex's id.
    private let seats: [String: [Desk]]
    /// How far outside its room a desk is allowed to reach. Half a desk, which
    /// is exactly how far the outermost one in a row can overhang.
    private let overhang: CGFloat

    /// An office with nothing in it.
    public static let empty = SceneHitIndex()

    private init() {
        self.floors = []
        self.zones = []
        self.desks = [:]
        self.seats = [:]
        self.overhang = 0
    }

    /// Reads the index off a laid-out office.
    ///
    /// - Parameters:
    ///   - frame: the floor plan.
    ///   - deskSize: the clickable area of one full-size workstation, in node
    ///     points — `DeskNode.hitSize`, so that what the index answers and what
    ///     the scene draws cannot drift apart.
    ///   - deskBaseline: how far that area reaches *below* a slot's anchor,
    ///     which is the point on the floor line the desk stands on.
    public init(frame: SceneFrame, deskSize: CGSize, deskBaseline: CGFloat) {
        self.floors = frame.floors
        self.zones = frame.zones
        self.overhang = deskSize.width / 2
        var byFloor: [Int: [Desk]] = [:]
        // A desk whose occupant has walked off is still a desk, but it is not
        // *them* — clicking it would select somebody who is visibly standing
        // somewhere else on the map. The seat they walked to carries the
        // session instead.
        for slot in frame.slots where slot.isOccupied {
            byFloor[slot.floorIndex, default: []].append(
                Desk(
                    slotID: slot.id,
                    session: slot.session,
                    rect: Self.deskRect(
                        anchor: slot.anchor,
                        scale: slot.scale,
                        size: deskSize,
                        baseline: deskBaseline
                    )
                )
            )
        }
        self.desks = byFloor

        var byZone: [String: [Desk]] = [:]
        let areas = frame.zones
        for seat in frame.seats where seat.session != nil {
            guard let area = areas.last(where: { $0.zone == seat.zone }) else { continue }
            // Chairs at a table are two thirds of a desk apart, so a desk-wide
            // click target would cover its neighbours. The seat's own spacing
            // is the honest width, and it is what the layout drew with.
            let width = min(deskSize.width, Self.width(of: seat.kind, metrics: frame.metrics))
            byZone[area.id, default: []].append(
                Desk(
                    slotID: seat.id,
                    session: seat.session,
                    rect: Self.deskRect(
                        anchor: seat.anchor,
                        scale: seat.scale,
                        size: CGSize(width: width, height: deskSize.height),
                        baseline: deskBaseline
                    )
                )
            )
        }
        self.seats = byZone
    }

    /// How wide a click on one kind of seat reaches.
    private static func width(of kind: SceneSeatKind, metrics: SceneMetrics) -> CGFloat {
        switch kind {
        case .desk: metrics.cellWidth
        case .tableHead, .tableNorth, .tableSouth: metrics.tableSeatSpacing
        case .call, .note, .bench, .doze: metrics.gardenSeatSpacing
        case .gate: metrics.gardenSeatSpacing * 0.4
        }
    }

    /// The area one workstation's click target covers, in layout space.
    ///
    /// The anchor is the middle of the desk on the floor line; the area reaches
    /// `baseline` points below it and the rest of its height above, which is
    /// where the chair, the monitor, and whoever is sitting at it are drawn.
    public static func deskRect(
        anchor: CGPoint,
        scale: CGFloat,
        size: CGSize,
        baseline: CGFloat
    ) -> CGRect {
        CGRect(
            x: anchor.x - size.width * scale / 2,
            y: anchor.y - (size.height - baseline) * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }

    /// The room a layout point is in.
    ///
    /// Last match wins, so the answer agrees with what is drawn on top when two
    /// rooms overlap — which they should not, but a hit test that silently
    /// disagrees with the picture is a bug nobody can see.
    public func floor(at point: CGPoint) -> SceneFloor? {
        floors.last { $0.frame.contains(point) }
    }

    /// The desk a layout point is on, if any.
    ///
    /// Rooms are searched from the front, and only the desks of a room the
    /// point could plausibly be in are looked at — which is what turns a walk
    /// over every desk in the building into a handful of rectangle tests.
    public func desk(at point: CGPoint) -> Desk? {
        for floor in floors.reversed() {
            guard floor.frame.insetBy(dx: -overhang, dy: -overhang).contains(point) else {
                continue
            }
            if let hit = desks[floor.index]?.last(where: { $0.rect.contains(point) }) {
                return hit
            }
        }
        for area in zones.reversed() {
            guard area.frame.insetBy(dx: -overhang, dy: -overhang).contains(point) else {
                continue
            }
            if let hit = seats[area.id]?.last(where: { $0.rect.contains(point) }) {
                return hit
            }
        }
        return nil
    }

    /// The annex a layout point is in.
    public func zone(at point: CGPoint) -> SceneZoneArea? {
        zones.last { $0.frame.contains(point) }
    }

    /// How many desks the index holds. For tests, and for nothing else.
    public var deskCount: Int { desks.values.reduce(0) { $0 + $1.count } }

    /// How many annex seats it holds. Likewise.
    public var seatCount: Int { seats.values.reduce(0) { $0 + $1.count } }
}
