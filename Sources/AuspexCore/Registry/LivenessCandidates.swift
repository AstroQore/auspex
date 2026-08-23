import AgentSessionLive
import Foundation

/// The sessions whose process state can still change the board.
///
/// A retained store may contain thousands of ended sessions. Re-probing all
/// of them every three seconds cannot change their state and turns a small
/// live-process check into a full-history filesystem sweep. A later transcript
/// event reactivates its session before the next snapshot, so excluding ended
/// rows here loses no resurrection signal.
public enum LivenessCandidates {
    /// Long enough for many three-second ticks to repair a transient probe,
    /// bounded so old process-gone history does not become permanent work.
    public static let recoveryGrace: TimeInterval = 60

    public static func identities(
        in board: BoardSnapshot,
        recoveryGrace: TimeInterval = Self.recoveryGrace
    ) -> [SessionIdentity] {
        identities(
            in: board.sessions,
            now: board.generatedAt,
            recoveryGrace: recoveryGrace
        )
    }

    public static func identities<S: Sequence>(
        in sessions: S,
        now: Date,
        recoveryGrace: TimeInterval = Self.recoveryGrace
    ) -> [SessionIdentity] where S.Element == SessionSnapshot {
        sessions.compactMap { session in
            if !session.state.isEnded { return session.identity }
            guard case .ended(let reason) = session.state,
                  reason == .processGone,
                  let endedAt = session.endedAt ?? session.lastEventAt,
                  now.timeIntervalSince(endedAt) <= max(0, recoveryGrace)
            else { return nil }
            return session.identity
        }
    }
}
