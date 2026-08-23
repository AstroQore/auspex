import AgentSessionLive

/// The sessions whose process state can still change the board.
///
/// A retained store may contain thousands of ended sessions. Re-probing all
/// of them every three seconds cannot change their state and turns a small
/// live-process check into a full-history filesystem sweep. A later transcript
/// event reactivates its session before the next snapshot, so excluding ended
/// rows here loses no resurrection signal.
public enum LivenessCandidates {
    public static func identities(in board: BoardSnapshot) -> [SessionIdentity] {
        board.sessions.compactMap { session in
            session.state.isEnded ? nil : session.identity
        }
    }
}
