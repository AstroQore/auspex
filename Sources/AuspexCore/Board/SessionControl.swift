import AgentSessionKit
import AgentSessionLive
import Darwin
import Foundation

/// Whether Auspex may signal a session's process, and what to call the thing
/// it would do.
///
/// The board is an observer. Signalling is the one place it stops being one,
/// and the whole of this type is the argument for why that is safe: a signal
/// is irreversible, `kill(2)` takes a bare integer, and the integer Auspex
/// holds was read out of another tool's store minutes or hours ago. Between
/// that read and the click, the process it named can have exited and its pid
/// been handed to something else — a build, a backup, a browser tab's helper.
///
/// So nothing here signals anything. It answers *may I*, against a process
/// table read now, and hands back the pid it verified. The app layer's job is
/// to ask this question immediately before it acts and to act only on the
/// answer — see `SessionControlModel` in `AuspexApp`.
///
/// ## What is checked, and why each one is load-bearing
///
/// - **A pid was recorded.** Most harnesses never write one down. No pid is
///   the common case, not an error.
/// - **The pid is above 1.** `0` means "every process in my group" to
///   `kill(2)` and `-1` means "everything I own"; `1` is `launchd`. A pid that
///   came off disk must never be allowed to mean any of those, and a bounds
///   check is cheaper than trusting that a parser never returns zero.
/// - **It is not Auspex, or anything Auspex is running inside.** A crash is
///   the least bad outcome of getting that wrong.
/// - **The process exists and is ours.** Another user's process is not ours to
///   stop, and the kernel would refuse anyway — better a sentence than an
///   `EPERM` nobody sees.
/// - **It is still the same process.** `(pid, startTime)` is the identity, and
///   a recorded start time more than ``startTimeTolerance`` away from the
///   running one means the pid was recycled. When a harness recorded no start
///   time, the executable has to at least still be that harness's launcher —
///   which will not save you from a recycled pid that landed on another
///   `claude`, but does rule out the case that actually happens, where the pid
///   is now something else entirely.
public enum SessionControl {
    // MARK: - Signals

    /// The three things Auspex will send, in increasing order of how much they
    /// take away from the person on the other end.
    ///
    /// Three and not one because they answer three different questions — *stop
    /// what you are doing*, *shut down*, and *you are not shutting down and I
    /// have run out of patience* — and because a UI that offers only the last
    /// one teaches people to reach for it first.
    public enum Signal: String, Sendable, Hashable, CaseIterable, Codable {
        /// `SIGINT`. What a terminal sends on ⌃C — with the caveat that a
        /// full-screen harness reading its keyboard in raw mode never sees a
        /// terminal ⌃C as a signal at all, so the two are not the same thing.
        /// See `docs/research/claude-messaging-socket.md` for what Claude Code
        /// actually does with one.
        case interrupt
        /// `SIGTERM`. The ordinary "please exit" that a process may catch and
        /// clean up after.
        case terminate
        /// `SIGKILL`. Uncatchable. Offered only after a `terminate` failed to
        /// take, never as the first thing a click can do.
        case forceKill

        /// The number `kill(2)` takes.
        public var number: Int32 {
            switch self {
            case .interrupt: SIGINT
            case .terminate: SIGTERM
            case .forceKill: SIGKILL
            }
        }

        /// The C name, for the trace note and for anything a person has to
        /// match up against `ps` or a shell.
        public var name: String {
            switch self {
            case .interrupt: "SIGINT"
            case .terminate: "SIGTERM"
            case .forceKill: "SIGKILL"
            }
        }

        /// What the menu item says.
        ///
        /// *Interrupt (SIGINT)* and not *Interrupt (⌃C)*, which is what it
        /// looked like it should say. A full-screen harness reads its keyboard
        /// in raw mode, where ⌃C arrives as a byte and never becomes a signal
        /// — so "the thing that happens when I press ⌃C in the terminal" and
        /// "what this menu item sends" are genuinely different events, and
        /// naming the second after the first would be a promise the item
        /// cannot keep. See ``interruptHelp(for:pid:)``.
        public var menuTitle: String {
            switch self {
            case .interrupt: "Interrupt (SIGINT)"
            case .terminate: "Kill…"
            case .forceKill: "Force kill"
            }
        }
    }

    // MARK: - Targets

    /// A process this module has just verified: the pid, and the start time it
    /// was verified against.
    ///
    /// Carrying the start time is what lets the caller re-check without
    /// re-deriving anything — and what a second, harder signal checks against,
    /// so that a "Force" step seconds after a "Kill" cannot land on a pid the
    /// kernel handed to somebody else in between.
    public struct Target: Hashable, Sendable {
        /// The verified process id.
        public let pid: pid_t
        /// The running process's start time, as the table reported it.
        public let startTime: Date
        /// The kernel's short name for it, for the confirmation dialog.
        public let processName: String

        public init(pid: pid_t, startTime: Date, processName: String) {
            self.pid = pid
            self.startTime = startTime
            self.processName = processName
        }
    }

    /// Whether a session can be signalled, or the sentence explaining why not.
    ///
    /// Modelled the way ``SessionResumeAvailability`` is, and for the same
    /// reason: "no" is a thing a menu has to render. An item that quietly
    /// disappears from one card and not the next is a thing a person notices
    /// and cannot explain.
    public enum Availability: Hashable, Sendable {
        /// The process was found, is ours, and is still the one recorded.
        case available(Target)
        /// It cannot be signalled, and why — a sentence, not an error code.
        case unavailable(reason: String)

        /// The verified target, or `nil`.
        public var target: Target? {
            guard case let .available(target) = self else { return nil }
            return target
        }

        /// Why not, or `nil` when it can be signalled.
        public var reason: String? {
            guard case let .unavailable(reason) = self else { return nil }
            return reason
        }

        /// `true` when there is a process to signal.
        public var isAvailable: Bool { target != nil }
    }

    /// How far a running process's start time may differ from the recorded one
    /// before the pid counts as recycled.
    ///
    /// The same two seconds `LivenessResolver` uses, deliberately: a session
    /// that the board calls alive and one that this module will signal should
    /// not be able to disagree about whether a pid is the process it was.
    public static let startTimeTolerance: TimeInterval = 2

    /// The lowest pid Auspex will ever pass to `kill(2)`.
    ///
    /// `2`, not `1`. Zero and negative pids are broadcasts, and `1` is
    /// `launchd`.
    public static let lowestSignallablePID: pid_t = 2

    // MARK: - The question

    /// May this session's process be signalled, and which process is it?
    ///
    /// - Parameters:
    ///   - identity: the session, as the board holds it.
    ///   - table: the process table, read now. A caller about to signal should
    ///     hand this a table it has just refreshed; three seconds of cache is
    ///     fine for deciding whether a menu item is enabled and is not fine
    ///     for deciding where a signal goes.
    ///   - ownUID: the running user. Injected for the suite.
    ///   - ownPID: Auspex's own process.
    ///   - tolerance: start-time slack for the recycled-pid check.
    public static func availability(
        for identity: SessionIdentity,
        table: any ProcessTableReading,
        ownUID: uid_t = getuid(),
        ownPID: pid_t = getpid(),
        tolerance: TimeInterval = startTimeTolerance
    ) -> Availability {
        guard let pid = identity.pid else {
            return .unavailable(
                reason: "Auspex never saw a process for this session, so there is nothing to signal."
            )
        }
        guard pid >= lowestSignallablePID else {
            return .unavailable(reason: "pid \(pid) is not a process Auspex will signal.")
        }
        guard pid != ownPID else {
            return .unavailable(reason: "That is Auspex's own process.")
        }
        guard !table.ancestors(of: ownPID).contains(where: { $0.pid == pid }) else {
            return .unavailable(reason: "Auspex is running inside pid \(pid).")
        }
        guard let record = table.record(pid: pid) else {
            return .unavailable(reason: "pid \(pid) is not running any more.")
        }
        guard record.uid == ownUID else {
            return .unavailable(reason: "pid \(pid) belongs to another user.")
        }

        if let recorded = identity.procStart {
            let drift = abs(record.startTime.timeIntervalSince(recorded))
            guard drift <= tolerance else {
                return .unavailable(
                    reason: "pid \(pid) was recycled — the process running under it now started "
                        + "\(Int(drift.rounded()))s away from the one this session recorded."
                )
            }
        } else {
            guard isPlausibleLauncher(record, for: identity.key.harness) else {
                return .unavailable(
                    reason: "This session recorded no start time, and pid \(pid) is now "
                        + "\(displayName(of: record)) rather than "
                        + "\(identity.key.harness.displayName)."
                )
            }
        }

        return .available(
            Target(pid: pid, startTime: record.startTime, processName: displayName(of: record))
        )
    }

    /// Whether the process still under `pid` is the one a target was made
    /// from — the check to run in the instant before `kill(2)`.
    ///
    /// Separate from ``availability(for:table:ownUID:ownPID:tolerance:)``
    /// because the two happen at different moments: the first decides whether
    /// a menu item is live, and this one decides whether the click that
    /// followed it may still land. A confirmation dialog can sit open for a
    /// minute, and a pid is not a stable name for anything over a minute.
    public static func stillMatches(
        _ target: Target,
        table: any ProcessTableReading,
        ownUID: uid_t = getuid(),
        tolerance: TimeInterval = startTimeTolerance
    ) -> Bool {
        guard target.pid >= lowestSignallablePID,
              let record = table.record(pid: target.pid),
              record.uid == ownUID
        else { return false }
        return abs(record.startTime.timeIntervalSince(target.startTime)) <= tolerance
    }

    // MARK: - Sending

    /// What came of a send.
    public enum Outcome: Hashable, Sendable {
        /// The signal was delivered.
        case sent(Signal)
        /// The last-moment re-check failed, so nothing was sent.
        case refused(reason: String)
        /// `kill(2)` itself failed.
        case failed(reason: String)

        /// The sentence for the session's trace, or `nil` when a refusal is
        /// not worth recording.
        public var isSent: Bool {
            if case .sent = self { return true }
            return false
        }
    }

    /// Re-verifies `target` and, only if it is still the same process, signals
    /// it.
    ///
    /// The one place in Auspex that calls `kill(2)`. It lives in Core rather
    /// than beside the menu item because the check and the syscall must not be
    /// separable: a caller that could reach the syscall without the check is a
    /// caller that will eventually be written.
    ///
    /// `table` must be freshly refreshed. Handing this a cached snapshot would
    /// defeat the whole point of the re-check.
    @discardableResult
    public static func send(
        _ signal: Signal,
        to target: Target,
        table: any ProcessTableReading,
        ownUID: uid_t = getuid(),
        tolerance: TimeInterval = startTimeTolerance
    ) -> Outcome {
        guard stillMatches(target, table: table, ownUID: ownUID, tolerance: tolerance) else {
            return .refused(
                reason: "pid \(target.pid) is no longer the process this session recorded."
            )
        }
        guard kill(target.pid, signal.number) == 0 else {
            return .failed(reason: describe(errno: errno))
        }
        return .sent(signal)
    }

    // MARK: - What the person reads

    /// The confirmation dialog's title.
    public static func killPrompt(title: String, target: Target) -> String {
        "Kill \(displayTitle(title))?"
    }

    /// The confirmation dialog's body: which process, and what it costs.
    ///
    /// Names the pid because that is the fact a person can check in another
    /// window before agreeing, and says what survives, because the thing most
    /// people actually want to know before killing an agent is whether they
    /// lose the conversation.
    public static func killMessage(target: Target, isResumable: Bool) -> String {
        let process = "\(target.processName) (pid \(target.pid))"
        return isResumable
            ? "Auspex will send SIGTERM to \(process). The transcript is already on disk, "
                + "so the session can be resumed afterwards; anything the agent was part-way "
                + "through will not be finished."
            : "Auspex will send SIGTERM to \(process). Anything the agent was part-way through "
                + "will not be finished."
    }

    /// What the Interrupt item's tooltip says, per harness.
    ///
    /// Worth saying out loud for Claude Code because the obvious assumption is
    /// wrong. A full-screen harness reads its keyboard in raw mode, where ⌃C
    /// arrives as a byte and never becomes a signal at all — so the TUI's
    /// "press again to exit" has nothing to do with `SIGINT`, and a real
    /// `SIGINT` goes to the handler that shuts the session down. Observed
    /// against a disposable session; see
    /// `docs/research/claude-messaging-socket.md`.
    public static func interruptHelp(for harness: Harness, pid: pid_t) -> String {
        switch harness {
        case .claudeCode:
            "Sends SIGINT to pid \(pid). Claude Code takes that as a graceful quit — it saves "
                + "the session and exits, rather than stopping only the current turn."
        default:
            "Sends SIGINT to pid \(pid) — the signal a terminal sends on ⌃C. What the harness "
                + "does with it is the harness's decision."
        }
    }

    /// The sentence written into the session's trace after a signal is sent.
    ///
    /// A note rather than a synthesised lifecycle event: this is Auspex saying
    /// what *Auspex* did, and it must never be mistaken for something the
    /// harness reported about itself. Nothing but a signal name and a pid goes
    /// in — no path, no argv, no prompt text.
    public static func note(_ signal: Signal, target: Target) -> String {
        "Auspex sent \(signal.name) to pid \(target.pid) at your request."
    }

    /// The note for a signal that could not be sent, and why.
    public static func failureNote(_ signal: Signal, pid: pid_t, reason: String) -> String {
        "Auspex could not send \(signal.name) to pid \(pid): \(reason)"
    }

    /// `errno`, as something a person can read.
    public static func describe(errno code: Int32) -> String {
        switch code {
        case ESRCH: "the process had already exited"
        case EPERM: "the system refused permission"
        case EINVAL: "the signal is not valid"
        default: String(cString: strerror(code))
        }
    }

    // MARK: - Identifying a harness's process

    /// Executable names that launch each harness, as basenames.
    ///
    /// Basenames only, because a Homebrew `codex` and one under
    /// `~/.local/bin` are the same harness. The three harnesses with no entry
    /// have no command-line launcher at all — they are applications, and a
    /// session of theirs that somehow carried a pid with no start time is
    /// exactly the case this check exists to refuse.
    public static let launcherNames: [Harness: Set<String>] = [
        .claudeCode: ["claude"],
        .codex: ["codex"],
        .chatgptWork: ["codex"],
        .geminiCLI: ["gemini"],
        .antigravity: ["agy"],
        .grokBuild: ["grok"],
        .cursor: ["cursor-agent"]
    ]

    /// Whether a running process still looks like the harness that recorded
    /// it, by executable name.
    ///
    /// Weak evidence, and used only where there is nothing stronger. The
    /// kernel truncates its short name to sixteen characters, so both the
    /// short name and the executable's basename are tried — a process whose
    /// path the kernel will not report still has the name.
    public static func isPlausibleLauncher(_ record: ProcessRecord, for harness: Harness) -> Bool {
        guard let names = launcherNames[harness] else { return false }
        if names.contains(record.name) { return true }
        let basename = (record.executablePath as NSString).lastPathComponent
        return !basename.isEmpty && names.contains(basename)
    }

    /// What to call a process in a sentence.
    private static func displayName(of record: ProcessRecord) -> String {
        if !record.name.isEmpty { return record.name }
        let basename = (record.executablePath as NSString).lastPathComponent
        return basename.isEmpty ? "an unnamed process" : basename
    }

    /// A session title cut to something a dialog can hold on one line.
    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this session" }
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}
