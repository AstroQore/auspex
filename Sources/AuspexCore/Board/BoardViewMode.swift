import Foundation

/// How the live work is drawn.
///
/// The same board, five ways of looking at it: a wall of cards for reading,
/// a room and a wall of faces for watching, a user-owned Perch, and one
/// session opened out for taking apart. The choice is a mode rather than a separate destination
/// because it does not change *what* is on screen, only how it is drawn: the
/// selection, the grouping, the filters, and the trace beside it all survive a
/// switch.
///
/// ## The names
///
/// An auspex read birds. The modes are named for what they show rather than
/// for the widget that shows it: the **Ledger** is what has been written down,
/// the **Aviary** is the room they are in, the **Flock** is the birds
/// themselves, the **Perch** is where a person placed them, and a **Flight** is
/// the path one of them took. Established raw values keep their old spellings
/// — `board`, `scene`, `crew`, `trajectory` — because
/// they are what `--view` accepts and what a settings file already holds, and
/// renaming a stored value to improve a label is how a preference silently
/// resets.
///
/// It lives in Core, and it is an enum rather than a boolean, so that adding
/// the next way of looking at the board is a case here and a branch in the
/// container — not a new flag threaded through the model, the picker, and the
/// window's state restoration.
public enum BoardViewMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// The grid of session cards. The default, and the only one that can show
    /// every session at once.
    case board
    /// The rendered office. Fewer facts per task, but the shape of the whole
    /// machine at a glance.
    case scene
    /// One avatar per piece of work, animated by what it is doing, with the
    /// sessions inside it as a brood of smaller ones.
    case crew
    /// A user-owned spatial memory. Unlike the Aviary, existing positions are
    /// never recomputed: a card stays where the person put it.
    case perch
    /// One session, opened out: a waterfall of its turns, every step it took,
    /// and an inspector on whichever one is selected.
    ///
    /// The odd one out, and deliberately so. The other three draw *the board*;
    /// this draws the selected session and nothing else, which is why it is
    /// the only mode that ``requiresSelection``.
    case trajectory

    public var id: String { rawValue }

    /// The segment's label in the header's picker.
    public var title: String {
        switch self {
        case .board: "Ledger"
        case .scene: "Aviary"
        case .crew: "Flock"
        case .perch: "Perch"
        case .trajectory: "Flight"
        }
    }

    /// An SF Symbol, for the places a label will not fit.
    public var systemImage: String {
        switch self {
        case .board: "square.grid.2x2"
        case .scene: "building.2"
        case .crew: "person.3"
        case .perch: "mappin.and.ellipse"
        case .trajectory: "chart.bar.doc.horizontal"
        }
    }

    /// Whether the mode is about one session rather than about all of them.
    ///
    /// The picker reads this to decide what to disable, and the container
    /// reads it to decide what to fall back to — a mode that needs a selection
    /// and has none must show something rather than an empty column.
    public var requiresSelection: Bool {
        switch self {
        case .board, .scene, .crew, .perch: false
        case .trajectory: true
        }
    }

    /// A mode named on the command line or in the environment.
    ///
    /// Both spellings, and the raw value first. `--view crew` is what somebody
    /// has in a shell history and in a script; `--view flock` is what they
    /// will type after reading the window. A flag that stopped working because
    /// a label changed would be the rename charging rent.
    public init?(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mode = BoardViewMode(rawValue: name) {
            self = mode
            return
        }
        switch name {
        case "ledger": self = .board
        case "aviary": self = .scene
        case "flock": self = .crew
        case "map", "perch": self = .perch
        case "flight": self = .trajectory
        default: return nil
        }
    }

    /// The modes the picker offers, in display order.
    ///
    /// Named rather than using ``allCases`` directly so a view reads as what it
    /// means, and so the order is stated in one place if it ever stops being
    /// declaration order.
    public static var pickerOrder: [BoardViewMode] { allCases }
}
