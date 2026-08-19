import AuspexCore
import CoreGraphics
import SwiftUI

/// The whole map, small enough to draw in a corner.
///
/// ## What the minimap is allowed to know
///
/// One rectangle per room, one for the window, and nothing else. No desks, no
/// characters, no motion: at the size this is drawn a desk is a third of a
/// pixel, and anything that moved in it would be noise beside a scene that is
/// already moving. What it answers is *how much office is there* and *which
/// part am I looking at* — the two questions a camera over a canvas larger
/// than the window makes unanswerable.
///
/// ## Coordinates
///
/// Layout space throughout — y-down, the same space ``SceneFrame`` is in and
/// the same space SwiftUI draws in — so the minimap needs no flip. The camera
/// arrives in SpriteKit's y-up world and is converted once, on the way in.
struct SceneOverview: Equatable {
    /// One project's room.
    struct Room: Equatable, Identifiable {
        let id: String
        /// Where the room is, in layout space.
        let rect: CGRect
        /// What is happening in it, as one colour.
        let tint: Color
        /// Whether the camera is bound to this project.
        let isFocused: Bool
        /// Whether somebody in it is waiting on a person. The one thing the
        /// minimap is allowed to shout about.
        let needsYou: Bool
    }

    /// The whole map, in layout space.
    var world: CGRect
    /// What the window is showing of it.
    var viewport: CGRect
    var rooms: [Room]
    /// The current zoom, for the toolbar's readout.
    var zoom: CGFloat

    static let empty = SceneOverview(world: .zero, viewport: .zero, rooms: [], zoom: 1)

    /// `true` when the window already shows the whole map, and an overview of
    /// it would be a picture of the thing next to it.
    var showsEverything: Bool {
        world.width > 0 && viewport.insetBy(dx: -1, dy: -1).contains(world)
    }

    /// Whether it is worth drawing at all.
    var isWorthDrawing: Bool {
        world.width > 0 && rooms.count > 1 && !showsEverything
    }

    /// Reads one off the laid-out office.
    init(
        frame: SceneFrame,
        counts: [Int: BoardSnapshot.Counts],
        camera: SceneViewport,
        focusedProject: String?
    ) {
        self.world = frame.contentRect
        self.viewport = SceneGeometry.layout(from: camera.visibleRect)
        self.zoom = camera.zoom
        self.rooms = frame.floors.map { floor in
            let tally = counts[floor.index] ?? BoardSnapshot.Counts()
            return Room(
                id: floor.id,
                rect: floor.frame,
                tint: Self.tint(for: tally),
                isFocused: focusedProject != nil && floor.projectKey == focusedProject,
                needsYou: tally.waitingPermission > 0
            )
        }
    }

    private init(world: CGRect, viewport: CGRect, rooms: [Room], zoom: CGFloat) {
        self.world = world
        self.viewport = viewport
        self.rooms = rooms
        self.zoom = zoom
    }

    /// The loudest thing happening in a room, as the one colour it gets.
    ///
    /// The order is the board's order of urgency, not a tally: a room with one
    /// blocked session and nine thinking ones is a room that needs somebody,
    /// and averaging that into blue would be the minimap lying to make itself
    /// prettier. Writing and tool calls share a colour here because the
    /// board's own tallies fold them together — both are "a tool is open".
    private static func tint(for counts: BoardSnapshot.Counts) -> Color {
        if counts.waitingPermission > 0 { return AuspexPalette.statePermission }
        if counts.delegating > 0 { return AuspexPalette.stateDelegating }
        if counts.tooling > 0 { return AuspexPalette.stateTool }
        if counts.thinking > 0 { return AuspexPalette.stateThinking }
        if counts.live > 0 { return AuspexPalette.stateIdle }
        return AuspexPalette.stateEnded
    }
}
