import AgentSessionLive
import CoreGraphics
import Foundation

/// The three parts of one project's premises.
///
/// Not three themes and not three views: a project is a small company, and the
/// three parts are the rooms it works in. Desks are where the work happens, the
/// meeting rooms are where a session sits with what it delegated, and the break
/// area is where everything that has stopped goes. A session is in exactly one
/// of them at a time, and which one is a function of what it is doing — which
/// is the whole point, because the thing a glance is supposed to answer is
/// *who is working and who is not*, and a room where the answer is a colour on
/// a monitor is a room you have to read desk by desk.
///
/// All three belong to the *project*. There is no campus-wide meeting room and
/// no campus-wide garden, because "whose meeting is this" is the first thing a
/// reader asks of a table and the old map made them work it out from a
/// nameplate.
public enum SceneZone: String, Sendable, Hashable, CaseIterable, Codable {
    /// Desks and monitors. Everything that is actually working.
    case office
    /// Long tables. A session that is delegating, sitting with the children it
    /// delegated to.
    case meeting
    /// The room at the end of the suite: benches, a door, and whatever kind of
    /// break room this company happens to have.
    case breakArea
}

/// What kind of break room a company has.
///
/// Three, and which one a project gets is decided by the project rather than by
/// the reader, because the point is that a suite is *recognisable*: the room
/// with the sofas is always the same repository. It is scenery with a job.
public enum SceneBreakKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// Grass, trees, benches. The one the map shipped with.
    case garden
    /// A counter, a kettle, and somewhere to stand.
    case teaRoom
    /// Sofas, a coffee table, a bookshelf.
    case lounge

    /// What the room's nameplate says.
    public var title: String {
        switch self {
        case .garden: "Garden"
        case .teaRoom: "Tea room"
        case .lounge: "Lounge"
        }
    }
}

/// How the break room's kind is chosen.
///
/// `perProject` is the default and the interesting one: every company gets one
/// of the three, decided from its own path, so a machine with eight
/// repositories open looks like eight different companies rather than eight
/// copies of one. The other three are for somebody who would rather every
/// suite matched.
public enum SceneBreakStyle: String, Sendable, Hashable, CaseIterable, Codable {
    case perProject
    case garden
    case teaRoom
    case lounge

    /// The kind this style pins every project to, or `nil` when it does not.
    public var kind: SceneBreakKind? {
        switch self {
        case .perProject: nil
        case .garden: .garden
        case .teaRoom: .teaRoom
        case .lounge: .lounge
        }
    }
}

/// Which of a suite's rooms are switched on.
///
/// Both default to on. Off is not "hide those sessions" — it is "those
/// sessions stay at their desks", which is exactly the office that shipped
/// before the other rooms existed, and is why the setting is safe to leave to
/// taste rather than being a mode with its own behaviour to learn.
public struct SceneZoneOptions: Sendable, Equatable, Hashable, Codable {
    /// Whether a delegating family walks to a table.
    public var meetingRooms: Bool
    /// Whether the resting, the finished and the forgotten walk to the break
    /// room.
    public var breakAreas: Bool
    /// How a project's break room is chosen.
    public var breakStyle: SceneBreakStyle
    /// One project pinned to one kind, whatever the style says.
    ///
    /// The hook for "no, *this* one is a tea room": a per-project override
    /// outranks the style, the style outranks the seed. Nothing writes to it
    /// yet — the settings pane offers the style — and it is here rather than
    /// bolted on later because it is the shape the setting has to have and a
    /// stored value that has to grow a field is a stored value that has to
    /// migrate.
    public var breakOverrides: [String: SceneBreakKind]

    public init(
        meetingRooms: Bool = true,
        breakAreas: Bool = true,
        breakStyle: SceneBreakStyle = .perProject,
        breakOverrides: [String: SceneBreakKind] = [:]
    ) {
        self.meetingRooms = meetingRooms
        self.breakAreas = breakAreas
        self.breakStyle = breakStyle
        self.breakOverrides = breakOverrides
    }

    /// Every room, which is what a fresh install gets.
    public static let all = SceneZoneOptions()

    /// Desks only: the office exactly as it was before the other rooms existed.
    public static let officeOnly = SceneZoneOptions(meetingRooms: false, breakAreas: false)

    /// Whether `zone` is drawn at all. The desks cannot be switched off.
    public func includes(_ zone: SceneZone) -> Bool {
        switch zone {
        case .office: true
        case .meeting: meetingRooms
        case .breakArea: breakAreas
        }
    }

    /// The kind of break room `project` has.
    ///
    /// Override first, then the style, then the project's own name. The last
    /// of those is a hash of the path rather than `hashValue`, which is seeded
    /// per process — a company whose break room changed every time the app
    /// restarted would be a company nobody could learn the shape of.
    public func breakKind(forProject project: String?) -> SceneBreakKind {
        if let project, let pinned = breakOverrides[project] { return pinned }
        if let fixed = breakStyle.kind { return fixed }
        return Self.seededKind(forProject: project)
    }

    /// The kind a project's path alone decides.
    static func seededKind(forProject project: String?) -> SceneBreakKind {
        let kinds = SceneBreakKind.allCases
        let index = Int(fnv1a(project ?? "") % UInt64(kinds.count))
        return kinds[index]
    }

    /// FNV-1a, 64 bit. Small, stable across processes and platforms, and
    /// entirely good enough to pick one of three.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    private enum CodingKeys: String, CodingKey {
        case meetingRooms, breakAreas, breakStyle, breakOverrides
        /// What the two switches were called before a project's rooms belonged
        /// to the project.
        case meetingRoom, garden
    }

    /// Absent keys mean on, so a settings file written before the suites
    /// existed opens with them rather than with a scene that quietly lost two
    /// thirds of its map. The two old names are read as well as the new ones,
    /// because somebody who switched the garden off meant it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingRooms = try container.decodeIfPresent(Bool.self, forKey: .meetingRooms)
            ?? container.decodeIfPresent(Bool.self, forKey: .meetingRoom)
            ?? true
        breakAreas = try container.decodeIfPresent(Bool.self, forKey: .breakAreas)
            ?? container.decodeIfPresent(Bool.self, forKey: .garden)
            ?? true
        breakStyle = try container.decodeIfPresent(SceneBreakStyle.self, forKey: .breakStyle)
            ?? .perProject
        breakOverrides = try container.decodeIfPresent(
            [String: SceneBreakKind].self, forKey: .breakOverrides
        ) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingRooms, forKey: .meetingRooms)
        try container.encode(breakAreas, forKey: .breakAreas)
        try container.encode(breakStyle, forKey: .breakStyle)
        if !breakOverrides.isEmpty {
            try container.encode(breakOverrides, forKey: .breakOverrides)
        }
    }
}

/// What a session is sitting on, which is also what it is *doing there*.
///
/// The kind and the zone are separate because the zone decides the geometry —
/// which room of the suite, which allocation table — and the kind decides the
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
    /// On the waiting bench by the door, wanting a person. The loudest place
    /// in the suite.
    case call
    /// On the waiting bench holding the note that says it finished.
    case note
    /// Resting in the break room. Nothing outstanding.
    case bench
    /// Asleep in the break room. Claims to be working and has not said
    /// anything for a long time.
    case doze
    /// On the way out through the suite's door.
    case gate

    /// Which room of the suite this kind belongs to.
    public var zone: SceneZone {
        switch self {
        case .desk: .office
        case .tableHead, .tableNorth, .tableSouth: .meeting
        case .call, .note, .bench, .doze, .gate: .breakArea
        }
    }

    /// Whether somebody in this seat is on their way off the map.
    public var isLeaving: Bool { self == .gate }

    /// Whether this is the front row of the break room — the bench by the
    /// corridor, facing the way somebody would walk in.
    ///
    /// The two kinds here are the two attention buckets, and they are in the
    /// same row on purpose: what they have in common is that *you* are the
    /// next thing that has to happen. Everything else in the room is resting.
    public var isWaitingBench: Bool {
        switch self {
        case .call, .note: true
        case .desk, .tableHead, .tableNorth, .tableSouth, .bench, .doze, .gate: false
        }
    }

    /// Whether this is one of the break room's held places — a bench or a
    /// corner to doze in. The door is not one: nobody keeps a place in a queue
    /// they are about to walk out of, and neither is the waiting bench, which
    /// has a table of its own.
    public var isBreakRest: Bool {
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
    /// One session's place in its project's suite.
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
        /// everything goes back to when the other rooms are switched off.
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
    ///   - options: which of the suite's rooms are switched on.
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
        // Attention first, and it beats everything else in the suite — the
        // meeting it was in, the fact that its process has exited, the desk it
        // was at. Somebody who is waiting on *you* is not doing any of those
        // things any more, whatever their transcript still says.
        //
        // This is a change of mind and worth saying so: a blocked session used
        // to keep its desk, on the theory that a shout from the break room is
        // a shout you have to go looking for. It reads the other way round in
        // practice. A desk in a room of forty desks is where you hide; the
        // bench by the door is where a person's eye lands first, and it is the
        // same row for both buckets so there is one place to look per company
        // rather than a hunt through the building.
        if options.breakAreas {
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
            // With the break room switched off there is nowhere to walk to,
            // and the desk is where the strobing monitor already is.
            return .desk
        } else if attention.wantsPerson {
            return .desk
        }

        if options.meetingRooms, !session.state.isEnded,
           let table = table(for: session, sessions: sessions, parent: parent) {
            let kind: SceneSeatKind = table == session.key ? .tableHead : .tableNorth
            // The side a child sits on is a seating decision, not a placement
            // one — the layout alternates the two sides as it fills a table —
            // so `tableNorth` here means "a child at this table" and the
            // layout says which side that turned out to be.
            return Placement(kind: kind, table: table)
        }

        guard options.breakAreas else { return .desk }

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
