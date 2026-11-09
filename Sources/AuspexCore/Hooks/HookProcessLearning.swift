import AgentSessionKit
import AgentSessionLive
import Foundation

/// Learns which process a session runs in from the hooks it fires.
///
/// ## Why this is the place to learn it
///
/// Codex and Cursor never write their pid anywhere Auspex reads, so their rows
/// reach the board with `pid == nil` and stay that way — and the MCP caller
/// resolver, which walks from a bridge up to a pid the board knows, then has
/// nothing to find. Every one of their `tasks.claim` calls was refused for it.
///
/// A hook is the one moment both halves are in hand at once. The harness runs
/// `Auspex --hook` as its own direct child (a shell given one simple command
/// `exec`s it rather than forking), so the hook's parent pid is the harness;
/// and the payload names the session in the harness's own words. Two facts
/// from two different sources about the same instant is evidence, not a guess.
///
/// ## What keeps it from teaching the wrong thing
///
/// - **The payload must name a row the board already has.** A session found by
///   the pid itself would make the lesson circular. See
///   ``HookEventRouter/identifiedSession(for:known:)``.
/// - **Only a session with no pid yet.** A pid a tailer read from the
///   harness's own files is better evidence than this, and is never replaced.
/// - **The parent must be that harness's program** (``HarnessProcess``). A hook
///   run through a wrapper reports the wrapper, and recording a shell's pid
///   would make the session look alive for exactly as long as the shell lived.
/// - **Never a thread server.** A Codex `app-server` runs every thread a
///   desktop app has open; its pid identifies none of them, and recording it
///   would make every one of those threads look alive as long as the app is.
///
/// The start time goes in with the pid, which is what lets the liveness check
/// tell the process from a later one that was handed the same number.
public enum HookProcessLearning {
    /// The identity patch one hook teaches, or `nil` when it teaches nothing.
    ///
    /// - Parameters:
    ///   - hook: what the harness sent, with the pid of the process that ran it.
    ///   - session: the row the payload named, from
    ///     ``HookEventRouter/identifiedSession(for:known:)``.
    ///   - board: the current frame, for the row's recorded identity.
    ///   - table: the process table, for what the hook's parent actually is.
    public static func patch(
        for hook: HookEvent,
        session: SessionKey?,
        board: BoardSnapshot,
        table: any ProcessTableReading
    ) -> SessionIdentityPatch? {
        guard let session, hook.pid > 1,
              let snapshot = board.session(for: session),
              snapshot.identity.pid == nil,
              let record = table.record(pid: hook.pid),
              let process = HarnessProcess.recognize(record, table: table),
              process.harnesses.contains(session.harness),
              !process.isMultiSession
        else { return nil }
        return SessionIdentityPatch(pid: process.pid, procStart: process.startTime)
    }
}
