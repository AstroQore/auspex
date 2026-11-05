import AgentSessionLive
import CoreGraphics
import Foundation

/// Now's stage, composed: the rooms with people in them, packed into the strip
/// and ordered by what wants the reader.
///
/// ## Why the stage is not a window onto the aviary
///
/// The aviary is a map. It holds every desk for as long as its session is on
/// the board, keeps a room the size it was, and leaves the camera to the
/// reader — all of which is right for a picture a person learns the shape of.
/// A strip 380 points tall over the lists is a different picture: it is
/// glanced at, and what a glance has to find is *who is doing something and
/// who wants me*. Pointed at the map, the strip showed whatever corner of the
/// building the camera happened to be on — rows of empty desks whose owners
/// had walked to a lounge the strip cut off, the one person working half under
/// its top edge, a queue at a door frozen in mid-stride.
///
/// So the stage composes its own frame from the same board:
///
/// - **Only people.** A session is on the stage when it is alive and not over,
///   or when it is explicitly asking for a person. A room is drawn when it has
///   somebody in it, with one desk per person and no vacancies.
/// - **No annexes.** Everybody sits at their own desk — the pose, the screen
///   and the balloon already say what the meeting room and the garden say on
///   the map — so nobody walks anywhere and nothing waits at a door.
/// - **Subagents fold.** A session whose parent is on the stage is not a
///   second person: it is the `↳N` on its parent's desk, and its balloon, if
///   it has one, hangs over that parent. See ``deskFor``.
/// - **Urgency first.** Rooms run from the top left in the order *needs you →
///   may need you → working → idle*, and so do the people inside each room,
///   so when the strip cannot hold everyone the ones it drops are the ones
///   with nothing to say.
/// - **Framed to fit.** The whole composition is laid out for the strip's own
///   size at the closest zoom that holds it — 1× when it can, ½× when it must
///   — and what still does not fit folds into a `+N rooms` tile in the bottom
///   right.
///
/// Pure, like ``SceneLayout``: the same board, size and signals always give
/// the same composition. Unlike it, it keeps no allocation table — a desk is
/// keyed by its session rather than by a seat, so a person whose room moves
/// up the strip slides there rather than being re-seated.
public struct StageComposition: Sendable, Equatable {
    /// The frame to draw: floors and desks only.
    public let frame: SceneFrame
    /// The zoom the frame was laid out for. The strip's camera sits at exactly
    /// this, which is what makes ``SceneFrame/contentRect`` the strip itself.
    public let zoom: CGFloat
    /// How many rooms with people in them did not fit.
    public let hiddenRooms: Int
    /// Where the `+N rooms` tile stands, in layout space, when any did not.
    public let overflowTile: CGRect?
    /// Which drawn desk each folded subagent belongs to: a balloon about the
    /// subagent hangs over the person it is folded into.
    public let deskFor: [SessionKey: SessionKey]

    public init(
        frame: SceneFrame,
        zoom: CGFloat,
        hiddenRooms: Int,
        overflowTile: CGRect?,
        deskFor: [SessionKey: SessionKey]
    ) {
        self.frame = frame
        self.zoom = zoom
        self.hiddenRooms = hiddenRooms
        self.overflowTile = overflowTile
        self.deskFor = deskFor
    }

    public static let empty = StageComposition(
        frame: .empty, zoom: 1, hiddenRooms: 0, overflowTile: nil, deskFor: [:]
    )
}

/// Builds a ``StageComposition``.
public enum StageComposer {
    /// What a person on the stage is doing, as far as ordering goes. Lower
    /// comes first.
    public enum Tone: Int, Sendable, Comparable, CaseIterable {
        case needsYou = 0
        case mayNeedYou
        case working
        case idle

        public static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Room the strip's own chrome takes, in view points.
    ///
    /// The top band is the view's tag and hint on the left and its fold
    /// chevron on the right; the bottom band is the legend. A room under
    /// either is a room whose nameplate, or whose people, are covered by
    /// something that never moves.
    public struct Insets: Sendable, Equatable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static let none = Insets(top: 0, left: 0, bottom: 0, right: 0)
        /// Now's stage: the tag row above, the legend below.
        public static let stage = Insets(top: 44, left: 14, bottom: 40, right: 14)
    }

    /// The zooms a composition may be laid out at, closest first. Both are
    /// rungs of ``SceneViewport/zoomLadder``, so the art stays whole.
    public static let zooms: [CGFloat] = [1, 0.5]

    /// The narrowest a room is drawn, in desks: one desk and the air either
    /// side of it. Rooms grow in half-desk steps from there — as wide as
    /// their people, and as wide as their name (see
    /// ``nameplateWidth(_:zoom:)``) — because whole desks of empty floor
    /// beside a single person is what pushed a board of nine one-person rooms
    /// off 1× and down to ½×.
    public static let minimumRoomUnits: CGFloat = 1.5

    /// How wide a room has to be for its nameplate to show, in layout points.
    ///
    /// The office draws a room's name at a constant size on the screen — up
    /// to twice its size on the map once the camera is pulled back — and
    /// hides it when the room is narrower than the name (see the aviary's
    /// floor nameplate). A stage at ½× full of two-desk rooms was a stage of
    /// rooms with no names, so a room is made wide enough for its name at the
    /// zoom it is laid out for. An estimate on the generous side: condensed
    /// capitals at twelve points, their tracking, and the nameplate's insets.
    static func nameplateWidth(_ title: String, zoom: CGFloat) -> CGFloat {
        let scale = min(2, max(1, 1 / zoom))
        return (CGFloat(title.count) * 8.5 + 24) * scale
    }

    /// How tall the `+N rooms` tile is, in view points, and how wide.
    public static let overflowTileSize = CGSize(width: 104, height: 26)

    /// Composes the stage.
    ///
    /// - Parameters:
    ///   - board: the reduced board the office draws — one session per piece
    ///     of work, see ``SceneUnits``.
    ///   - attention: what each session is explicitly signalling.
    ///   - watched: sessions a single-session watch signal is about — Now's
    ///     *may need you* list.
    ///   - viewSize: the strip, in view points.
    ///   - insets: what of the strip its chrome covers.
    ///   - metrics: the floor plan's dimensions, shared with the aviary so a
    ///     desk here is a desk there.
    public static func compose(
        board: BoardSnapshot,
        attention: [SessionKey: AttentionState] = [:],
        watched: Set<SessionKey> = [],
        viewSize: CGSize,
        insets: Insets = .stage,
        metrics: SceneMetrics = .standard
    ) -> StageComposition {
        guard viewSize.width > 0, viewSize.height > 0 else { return .empty }
        let rooms = Self.rooms(board: board, attention: attention, watched: watched)
        guard !rooms.isEmpty else { return .empty }

        // The closest zoom that holds everybody; failing that the furthest,
        // with whatever it cannot hold folded away.
        var chosen: Packing?
        for zoom in zooms {
            let packing = pack(rooms, zoom: zoom, viewSize: viewSize, insets: insets, metrics: metrics)
            if packing.hidden == 0, packing.truncated == 0 {
                chosen = packing
                break
            }
        }
        let packing: Packing
        if let chosen {
            packing = chosen
        } else {
            // At the furthest zoom, cut short what has to be; reserve the
            // tile only when whole rooms are left over to count on it.
            let far = zooms[zooms.count - 1]
            let plain = pack(rooms, zoom: far, viewSize: viewSize, insets: insets, metrics: metrics)
            packing = plain.hidden == 0
                ? plain
                : pack(
                    rooms, zoom: far, viewSize: viewSize, insets: insets, metrics: metrics,
                    reservingTile: true
                )
        }

        var deskFor: [SessionKey: SessionKey] = [:]
        for room in rooms {
            for person in room.people {
                for child in person.folded { deskFor[child] = person.key }
            }
        }
        return StageComposition(
            frame: packing.frame,
            zoom: packing.zoom,
            hiddenRooms: packing.hidden,
            overflowTile: packing.tile,
            deskFor: deskFor
        )
    }

    // MARK: - Who is on the stage

    /// One person at one desk.
    struct Person: Equatable {
        let key: SessionKey
        /// The most urgent of this person and everybody folded into them.
        let tone: Tone
        /// Subagents drawn as this person's `↳N`.
        let folded: [SessionKey]
    }

    /// One project's room.
    struct Room: Equatable {
        let id: String
        let projectKey: String?
        let title: String
        let people: [Person]
        var tone: Tone { people.map(\.tone).min() ?? .idle }
    }

    /// Whether a session is a person on the stage at all.
    static func isOnStage(_ session: SessionSnapshot, attention: AttentionState?) -> Bool {
        (session.isAlive && !session.state.isEnded) || attention?.wantsPerson == true
    }

    /// What one session, on its own, is doing.
    static func tone(
        of session: SessionSnapshot,
        attention: AttentionState?,
        watched: Set<SessionKey>
    ) -> Tone {
        if attention?.wantsPerson == true { return .needsYou }
        if case .waitingPermission = session.state { return .needsYou }
        if watched.contains(session.key) { return .mayNeedYou }
        return session.state.isActive ? .working : .idle
    }

    /// The people on the stage, folded and grouped into rooms, in the order
    /// they are drawn.
    static func rooms(
        board: BoardSnapshot,
        attention: [SessionKey: AttentionState],
        watched: Set<SessionKey>
    ) -> [Room] {
        let onStage = board.sessions.filter { isOnStage($0, attention: attention[$0.key]) }
        guard !onStage.isEmpty else { return [] }
        var byKey: [SessionKey: SessionSnapshot] = [:]
        for session in onStage { byKey[session.key] = session }

        // The topmost ancestor that is itself on the stage. Bounded, because
        // a cycle in a delegation forest is a bug upstream and must not be a
        // hang here.
        func lead(of session: SessionSnapshot) -> SessionKey {
            var key = session.key
            var parent = session.identity.parent
            var steps = 0
            while let next = parent, next != key, let above = byKey[next], steps < 64 {
                key = next
                parent = above.identity.parent
                steps += 1
            }
            return key
        }

        var folded: [SessionKey: [SessionKey]] = [:]
        var leads: [SessionSnapshot] = []
        for session in onStage {
            let top = lead(of: session)
            if top == session.key {
                leads.append(session)
            } else {
                folded[top, default: []].append(session.key)
            }
        }

        var grouped: [String: (projectKey: String?, people: [Person])] = [:]
        var order: [String] = []
        for session in leads {
            let children = (folded[session.key] ?? []).sorted { $0.description < $1.description }
            var tone = Self.tone(of: session, attention: attention[session.key], watched: watched)
            for child in children {
                guard let snapshot = byKey[child] else { continue }
                tone = min(tone, Self.tone(of: snapshot, attention: attention[child], watched: watched))
            }
            let projectKey = board.projectKey(for: session)
            let id = projectKey.map { "stage.p.\($0)" } ?? "stage.unplaced"
            if grouped[id] == nil {
                grouped[id] = (projectKey, [])
                order.append(id)
            }
            grouped[id]?.people.append(Person(key: session.key, tone: tone, folded: children))
        }

        let rooms: [Room] = order.compactMap { id in
            guard let entry = grouped[id] else { return nil }
            let people = entry.people.sorted { lhs, rhs in
                if lhs.tone != rhs.tone { return lhs.tone < rhs.tone }
                return lhs.key.description < rhs.key.description
            }
            return Room(
                id: id,
                projectKey: entry.projectKey,
                title: SceneLayout.floorTitle(projectKey: entry.projectKey),
                people: people
            )
        }
        return rooms.sorted { lhs, rhs in
            if lhs.tone != rhs.tone { return lhs.tone < rhs.tone }
            let left = lhs.title.lowercased()
            let right = rhs.title.lowercased()
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Packing

    struct Packing {
        let frame: SceneFrame
        let zoom: CGFloat
        /// Rooms that did not fit at all.
        let hidden: Int
        /// People left out of a room that was cut short.
        let truncated: Int
        let tile: CGRect?
    }

    /// Lays `rooms` out for a strip `viewSize` points across at `zoom`.
    ///
    /// Shelves, from the top left: a room goes to the right of the last one
    /// until the shelf is full, then starts the next shelf under the tallest
    /// room on this one. A room never splits across two shelves; a room too
    /// tall for what is left of the strip keeps the rows that fit, its most
    /// urgent people first, when it is the first thing on its shelf, and is
    /// folded away otherwise.
    static func pack(
        _ rooms: [Room],
        zoom: CGFloat,
        viewSize: CGSize,
        insets: Insets,
        metrics: SceneMetrics,
        reservingTile: Bool = false
    ) -> Packing {
        let world = CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom)
        let area = CGRect(
            x: insets.left / zoom,
            y: insets.top / zoom,
            width: max(0, world.width - (insets.left + insets.right) / zoom),
            height: max(0, world.height - (insets.top + insets.bottom) / zoom)
        )
        let cell = metrics.cellWidth
        let gap = metrics.floorGap
        let maxColumns = max(1, Int((area.width / cell).rounded(.down)))
        let tile: CGRect? = reservingTile
            ? CGRect(
                x: area.maxX - overflowTileSize.width / zoom,
                y: area.maxY - overflowTileSize.height / zoom,
                width: overflowTileSize.width / zoom,
                height: overflowTileSize.height / zoom
            )
            : nil

        var floors: [SceneFloor] = []
        var slots: [SceneSlot] = []
        var hidden = 0
        var truncated = 0
        var x = area.minX
        var y = area.minY
        var shelfHeight: CGFloat = 0

        for room in rooms {
            let columns = min(room.people.count, maxColumns)
            let named = (nameplateWidth(room.title, zoom: zoom) / cell * 2).rounded(.up) / 2
            let units = max(minimumRoomUnits, CGFloat(columns), named)
            let width = min(units * cell, area.width)
            var rows = Int(ceil(Double(room.people.count) / Double(columns)))

            if x > area.minX, x + width > area.maxX + 0.5 {
                x = area.minX
                y += shelfHeight + gap
                shelfHeight = 0
            }
            let available = area.maxY - y - metrics.floorHeaderHeight
            let fitting = Int((available / metrics.rowHeight).rounded(.down))
            if fitting < rows {
                // Only the first room on a shelf may be cut short: anywhere
                // else, cutting it would hide its people to keep a gap.
                guard x == area.minX, fitting >= 1 else {
                    hidden += 1
                    continue
                }
                rows = fitting
            }
            var height = metrics.floorHeaderHeight + CGFloat(rows) * metrics.rowHeight
            var rect = CGRect(x: x, y: y, width: width, height: height)
            if let tile, rect.intersects(tile) {
                // The tile's corner is the one place a room may not reach. The
                // first room on a shelf gives up the rows that would; any
                // other is counted on the tile instead.
                let above = Int(((tile.minY - y - metrics.floorHeaderHeight) / metrics.rowHeight)
                    .rounded(.down))
                guard x == area.minX, above >= 1 else {
                    hidden += 1
                    continue
                }
                rows = min(rows, above)
                height = metrics.floorHeaderHeight + CGFloat(rows) * metrics.rowHeight
                rect.size.height = height
            }

            let index = floors.count
            // A room wider than its desks — for its name, or its one person —
            // keeps them in the middle rather than against its left wall.
            let inset = max(0, (width - CGFloat(columns) * cell) / 2)
            let people = room.people.prefix(rows * columns)
            truncated += room.people.count - people.count
            var occupancy = 0
            for (offset, person) in people.enumerated() {
                let row = offset / columns
                let column = offset % columns
                occupancy += 1
                slots.append(
                    SceneSlot(
                        id: "stage.\(person.key.description)",
                        session: person.key,
                        parent: nil,
                        depth: 0,
                        anchor: CGPoint(
                            x: x + inset + (CGFloat(column) + 0.5) * cell,
                            y: y + metrics.floorHeaderHeight + CGFloat(row + 1) * metrics.rowHeight
                        ),
                        scale: 1,
                        floorIndex: index,
                        row: row,
                        childCount: person.folded.count
                    )
                )
            }
            floors.append(
                SceneFloor(
                    id: room.id,
                    index: index,
                    projectKey: room.projectKey,
                    title: room.title,
                    frame: rect,
                    rowCount: rows,
                    occupancy: occupancy
                )
            )
            x += width + gap
            shelfHeight = max(shelfHeight, height)
        }

        let frame = SceneFrame(
            floors: floors,
            slots: slots,
            tethers: [],
            // The strip itself, not the rooms' bounding box: at ``zoom`` the
            // camera frames exactly this, with the rooms anchored top left
            // rather than floated into the middle of it.
            contentRect: floors.isEmpty ? .zero : CGRect(origin: .zero, size: world),
            metrics: metrics
        )
        return Packing(
            frame: frame,
            zoom: zoom,
            hidden: hidden,
            truncated: truncated,
            tile: hidden > 0 ? tile : nil
        )
    }
}
