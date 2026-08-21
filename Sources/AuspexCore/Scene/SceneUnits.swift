import AgentSessionKit
import AgentSessionLive
import Foundation

/// The board the aviary is drawn from: one desk per piece of work.
///
/// ## Why the office needed a second frame rather than a second layout
///
/// The scene's whole argument is spatial — a desk is held for as long as its
/// occupant is on the board, so a person learns *where* something is and finds
/// it again by looking rather than by reading nameplates. That argument is
/// worth more per desk when a desk is a task: a delegation of four used to
/// take four desks in a row, three of which appeared for one turn and vacated,
/// which is exactly the churn the seating rules exist to prevent.
///
/// Everything the layout does — floors, bays, meeting rooms, the vacancy hold
/// — is written against a ``BoardSnapshot``, and it is right about all of it.
/// So this hands it one: the leads, wearing their task's title, with the
/// members folded away. The scene needs no new concept and the seating
/// stability it already has now applies to the unit a person actually thinks
/// in.
///
/// ## What is lost, and where it goes
///
/// A member has no desk of its own here. Its state still reaches the room
/// through the lead — a session delegating to three children draws as
/// `delegating`, which is what the state already meant — and the count is on
/// the nameplate. Seating the members *around* their lead at the project's
/// meeting table is the right final answer and belongs with the suite layout's
/// meeting-room API, which is on another branch; when that lands, this is the
/// function that grows a second return value rather than the layout growing a
/// second notion of who is in the room.
public enum SceneUnits {
    /// One frame, reduced to its leads.
    ///
    /// - Parameters:
    ///   - board: the frame the wall is drawing.
    ///   - units: the units derived from it.
    /// - Returns: a frame with one session per unit, titled by the task.
    public static func board(from board: BoardSnapshot, units: [TaskUnit]) -> BoardSnapshot {
        guard !units.isEmpty else { return board }
        var leads: [SessionSnapshot] = []
        leads.reserveCapacity(units.count)
        for unit in units {
            guard var session = board.session(for: unit.lead.key) else { continue }
            // The nameplate. A desk in a room of forty is read at a glance and
            // a session id is not a name; the task's title is the one string
            // that says what the desk is for.
            session.identity.title = Self.nameplate(unit.title)
            leads.append(session)
        }
        guard !leads.isEmpty else { return board }
        return BoardSnapshot(
            generatedAt: board.generatedAt,
            sessions: leads,
            claims: board.claims,
            sandboxThreads: board.sandboxThreads
        )
    }

    /// How much of a title fits on a nameplate.
    ///
    /// Forty-eight characters. The scene draws it at nine points on a plate a
    /// desk wide, and a string longer than this is drawn as an ellipsis with
    /// nothing before it — which is worse than a sentence cut off mid-clause.
    public static let nameplateLimit = 48

    static func nameplate(_ title: String) -> String {
        guard title.count > nameplateLimit else { return title }
        return String(title.prefix(nameplateLimit - 1)) + "…"
    }
}
