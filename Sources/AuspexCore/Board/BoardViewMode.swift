import Foundation

/// How the live sessions are drawn.
///
/// The same board, several ways of looking at it: a grid of cards for reading,
/// a rendered scene and a crew view for watching, and a trajectory for taking
/// one session apart. The choice is a mode rather than a separate destination
/// because it does not change *what* is on screen, only how it is drawn: the
/// selection, the grouping, the filters, and the trace beside it all survive a
/// switch.
///
/// It lives in Core, and it is an enum rather than a boolean, so that adding
/// the next way of looking at the board is a case here and a branch in the
/// container — not a new flag threaded through the model, the picker, and the
/// window's state restoration.
public enum BoardViewMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// The grid of session cards. The default, and the only one that can show
    /// every session at once.
    case board
    /// The rendered office. Fewer facts per session, but the shape of the
    /// whole machine at a glance.
    case scene
    /// One geometric avatar per session, animated by what it is doing.
    case crew
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
        case .board: "Board"
        case .scene: "Scene"
        case .crew: "Crew"
        case .trajectory: "Trajectory"
        }
    }

    /// An SF Symbol, for the places a label will not fit.
    public var systemImage: String {
        switch self {
        case .board: "square.grid.2x2"
        case .scene: "building.2"
        case .crew: "person.3"
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
        case .board, .scene, .crew: false
        case .trajectory: true
        }
    }

    /// The modes the picker offers, in display order.
    ///
    /// Named rather than using ``allCases`` directly so a view reads as what it
    /// means, and so the order is stated in one place if it ever stops being
    /// declaration order.
    public static var pickerOrder: [BoardViewMode] { allCases }
}
