import AgentSessionLive
import CoreGraphics
import Foundation

/// The three parts of one continuous map.
///
/// Not three themes and not three views: the office is always there, and the
/// other two are annexes drawn beside it that a person can switch off. A
/// session is in exactly one of them at a time, and which one is a function of
/// what it is doing — which is the whole point, because the thing a glance is
/// supposed to answer is *who is working and who is not*, and a room where the
/// answer is a colour on a monitor is a room you have to read desk by desk.
public enum SceneZone: String, Sendable, Hashable, CaseIterable, Codable {
    /// Desks and monitors. Everything that is actually working.
    case office
    /// Long tables. A session that is delegating, sitting with the children it
    /// delegated to.
    case meeting
    /// Benches, a pond and a gate. Everything that has stopped.
    case garden
}

/// Which annexes are switched on.
///
/// Both default to on. Off is not "hide those sessions" — it is "those
/// sessions stay at their desks", which is exactly the office that shipped
/// before the annexes existed, and is why the setting is safe to leave to
/// taste rather than being a mode with its own behaviour to learn.
public struct SceneZoneOptions: Sendable, Equatable, Hashable, Codable {
    /// Whether a delegating family walks to a table.
    public var meetingRoom: Bool
    /// Whether the resting, the finished and the forgotten walk outside.
    public var garden: Bool

    public init(meetingRoom: Bool = true, garden: Bool = true) {
        self.meetingRoom = meetingRoom
        self.garden = garden
    }

    /// Both annexes, which is what a fresh install gets.
    public static let all = SceneZoneOptions()

    /// Neither: the office exactly as it was before the annexes existed.
    public static let officeOnly = SceneZoneOptions(meetingRoom: false, garden: false)

    /// Whether `zone` is drawn at all. The office cannot be switched off.
    public func includes(_ zone: SceneZone) -> Bool {
        switch zone {
        case .office: true
        case .meeting: meetingRoom
        case .garden: garden
        }
    }

    private enum CodingKeys: String, CodingKey {
        case meetingRoom, garden
    }

    /// Absent keys mean on, so a settings file written before the annexes
    /// existed opens with them rather than with a scene that quietly lost two
    /// thirds of its map.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingRoom = try container.decodeIfPresent(Bool.self, forKey: .meetingRoom) ?? true
        garden = try container.decodeIfPresent(Bool.self, forKey: .garden) ?? true
    }
}

/// What a session is sitting on, which is also what it is *doing there*.
///
/// The kind and the zone are separate because the zone decides the geometry —
/// which strip of the map, which allocation table — and the kind decides the
/// furniture and the pose. A renderer that only knew the zone would have to
/// re-derive "is this one asleep" from the session, and two places deriving
/// one fact is how a picture starts disagreeing with itself.
public enum SceneSeatKind: String, Sendable, Hashable, CaseIterable {
    /// A workstation in the office.
    case desk
    /// The head of a long table: the session that delegated.
    case tableHead
    /// A child on the far side of the table.
    case tableNorth
    /// A child on the near side.
    case tableSouth
    /// On the waiting bench by the path, wanting a person. The loudest place
    /// on the map.
    case call
    /// On the waiting bench holding the note that says it finished.
    case note
    /// Resting on the back lawn. Nothing outstanding.
    case bench
    /// Asleep on the back lawn. Claims to be working and has not said anything
    /// for a long time.
    case doze
    /// On the way out through the gate.
    case gate

    /// Which zone this kind belongs to.
    public var zone: SceneZone {
        switch self {
        case .desk: .office
        case .tableHead, .tableNorth, .tableSouth: .meeting
        case .call, .note, .bench, .doze, .gate: .garden
        }
    }

    /// Whether somebody in this seat is on their way off the map.
    public var isLeaving: Bool { self == .gate }

    /// Whether this is the front row of the garden — the bench by the path,
    /// facing the way somebody would walk in.
    ///
    /// The two kinds here are the two attention buckets, and they are in the
    /// same row on purpose: what they have in common is that *you* are the
    /// next thing that has to happen. Everything else in the garden is resting.
    public var isWaitingBench: Bool {
        switch self {
        case .call, .note: true
        case .desk, .tableHead, .tableNorth, .tableSouth, .bench, .doze, .gate: false
        }
    }

    /// Whether this is one of the back lawn's held places — a bench or a patch
    /// of shade. The gate is not one: nobody keeps a place in a queue they are
    /// about to walk out of, and neither is the waiting bench, which has a
    /// table of its own.
    public var isGardenRest: Bool {
        switch self {
        case .bench, .doze: true
        case .desk, .tableHead, .tableNorth, .tableSouth, .call, .note, .gate: false
        }
    }
}

/// Where every session on one board belongs.
///
/// ## Why this is a free function over a board rather than a method on a state
///
/// Two of the three answers are not properties of a session at all. A subagent
/// goes to the meeting room because *its parent* is delegating, and a session
/// sits on the waiting bench because something explicit said it wants a person
/// or has finished — which is a fact Auspex holds and nothing else on the
/// machine does. So the placement takes the board, the delegation edges the
/// board admits to, and what each session is signalling, and answers for all
/// of them at once.
///
/// It is pure: same inputs, same answer, no clock and no I/O. That is what
/// makes "a blocked session never leaves its desk" a test rather than a hope.
public enum SceneZoning {
    /// One session's place on the map.
    public struct Placement: Sendable, Equatable, Hashable {
        public let kind: SceneSeatKind
        /// The delegating session whose table this is, for a meeting seat.
        /// `nil` everywhere else.
        public let table: SessionKey?

        public init(kind: SceneSeatKind, table: SessionKey? = nil) {
            self.kind = kind
            self.table = table
        }

        public var zone: SceneZone { kind.zone }

        /// The office desk, which is where everything starts and where
        /// everything goes back to when the annexes are switched off.
        public static let desk = Placement(kind: .desk)
    }

    /// Places every session on `board`.
    ///
    /// - Parameters:
    ///   - sessions: the board's sessions, in the board's own order. Order
    ///     decides nothing except which of two equally-senior delegating
    ///     ancestors wins a cycle, which cannot happen on a well-formed board.
    ///   - parent: the delegation edges, already filtered to sessions that are
    ///     on this board. ``SceneLayout`` has this map; asking it to hand it
    ///     over is cheaper and less error-prone than deriving it twice.
    ///   - attention: what each session is signalling, if anything. Only the
    ///     sessions that are actually saying something need be in it.
    ///   - options: which annexes are switched on.
    public static func placements(
        sessions: [SessionSnapshot],
        parent: [SessionKey: SessionKey],
        attention: [SessionKey: AttentionState],
        options: SceneZoneOptions
    ) -> [SessionKey: Placement] {
        var byKey: [SessionKey: SessionSnapshot] = [:]
        byKey.reserveCapacity(sessions.count)
        for session in sessions { byKey[session.key] = session }

        var result: [SessionKey: Placement] = [:]
        result.reserveCapacity(sessions.count)

        for session in sessions {
            result[session.key] = placement(
                session,
                sessions: byKey,
                parent: parent,
                attention: attention[session.key] ?? .none,
                options: options
            )
        }
        return result
    }

    /// Where one session goes, given everything around it.
    private static func placement(
        _ session: SessionSnapshot,
        sessions: [SessionKey: SessionSnapshot],
        parent: [SessionKey: SessionKey],
        attention: AttentionState,
        options: SceneZoneOptions
    ) -> Placement {
        // Attention first, and it beats everything else on the map — the
        // meeting it was in, the fact that its process has exited, the desk it
        // was at. Somebody who is waiting on *you* is not doing any of those
        // things any more, whatever their transcript still says.
        //
        // This is a change of mind and worth saying so: a blocked session used
        // to keep its desk, on the theory that a shout from the garden is a
        // shout you have to go looking for. It reads the other way round in
        // practice. A desk in a room of forty desks is where you hide; the
        // front row by the path is where a person's eye lands first, and it is
        // the same row for both buckets so there is one place to look rather
        // than a hunt through the building.
        if options.garden {
            switch attention {
            case .needsYou: return Placement(kind: .call)
            case .doneReported: return Placement(kind: .note)
            case .none:
                // Belt and braces, and the same one ``TaskLedger/bucket``
                // keeps: a harness's permission wait always derives to
                // `needsYou`, and a caller that built the map some other way
                // must not be able to seat a blocked session at a table.
                if case .waitingPermission = session.state {
                    return Placement(kind: .call)
                }
            }
        } else if case .waitingPermission = session.state {
            // With the garden switched off there is nowhere to walk to, and
            // the desk is where the strobing monitor already is.
            return .desk
        } else if attention.wantsPerson {
            return .desk
        }

        if options.meetingRoom, !session.state.isEnded,
           let table = table(for: session, sessions: sessions, parent: parent) {
            let kind: SceneSeatKind = table == session.key ? .tableHead : .tableNorth
            // The side a child sits on is a seating decision, not a placement
            // one — the layout alternates the two sides as it fills a table —
            // so `tableNorth` here means "a child at this table" and the
            // layout says which side that turned out to be.
            return Placement(kind: kind, table: table)
        }

        guard options.garden else { return .desk }

        if session.state.isEnded { return Placement(kind: .gate) }
        if session.isStale, session.state.isActive { return Placement(kind: .doze) }
        if case .idle = session.state { return Placement(kind: .bench) }
        return .desk
    }

    /// The table `session` sits at, or `nil` when it is not in a delegating
    /// family.
    ///
    /// The *topmost* delegating ancestor rather than the nearest, so a chain
    /// that delegates twice is one meeting rather than two: the person asked
    /// for one thing, and the tree under it is how it is being done.
    ///
    /// The walk is bounded by a seen set. The delegation forest refuses to
    /// build a cycle, but a board can hold two identities that disagree about
    /// who spawned whom, and an unbounded walk over that is a hang.
    private static func table(
        for session: SessionSnapshot,
        sessions: [SessionKey: SessionSnapshot],
        parent: [SessionKey: SessionKey]
    ) -> SessionKey? {
        var highest: SessionKey?
        if case .delegating = session.state { highest = session.key }

        var seen: Set<SessionKey> = [session.key]
        var current = session.key
        while let above = parent[current], seen.insert(above).inserted {
            current = above
            guard let ancestor = sessions[above] else { break }
            if case .delegating = ancestor.state { highest = above }
        }
        return highest
    }
}
