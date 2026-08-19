import Foundation

/// How the live sessions are drawn.
///
/// The same board, three ways of looking at it: a grid of cards for reading,
/// and — as they land — a rendered scene and a crew view for watching. The
/// choice is a mode rather than a separate destination because it does not
/// change *what* is on screen, only how it is drawn: the selection, the
/// grouping, the filters, and the trace beside it all survive a switch.
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

    public var id: String { rawValue }

    /// The segment's label in the header's picker.
    public var title: String {
        switch self {
        case .board: "Board"
        case .scene: "Scene"
        }
    }

    /// An SF Symbol, for the places a label will not fit.
    public var systemImage: String {
        switch self {
        case .board: "square.grid.2x2"
        case .scene: "building.2"
        }
    }

    /// The modes the picker offers, in display order.
    ///
    /// Named rather than using ``allCases`` directly so a view reads as what it
    /// means, and so the order is stated in one place if it ever stops being
    /// declaration order.
    public static var pickerOrder: [BoardViewMode] { allCases }
}
