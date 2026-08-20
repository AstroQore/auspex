import AgentSessionKit
import AgentSessionLive
import Darwin
import Foundation
import Testing

@testable import AuspexCore

/// The guard in front of `kill(2)`.
///
/// Every case here is a way the pid on a card can stop meaning what it meant
/// when it was written down. None of them signals anything: the table is a
/// fixed array, so the suite can drive "the pid was recycled" and "the process
/// belongs to somebody else" without needing either to be true on the machine
/// running the tests.
@Suite("SessionControl · guards")
struct SessionControlGuardTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func identity(
        _ harness: Harness = .claudeCode,
        pid: pid_t? = 4_711,
        procStart: Date? = start
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: harness, sessionID: "11111111-2222-3333-4444-555555555555"),
            sourcePath: "/Users/example/store/session.jsonl",
            cwd: "/Users/example/Code/widget",
            pid: pid,
            procStart: procStart
        )
    }

    private func table(
        pid: pid_t = 4_711,
        ppid: pid_t = 1,
        uid: uid_t = getuid(),
        startTime: Date = start,
        executablePath: String = "/opt/homebrew/bin/claude",
        name: String? = nil
    ) -> StubProcessTable {
        StubProcessTable(records: [
            ProcessRecord(
                pid: pid,
                ppid: ppid,
                uid: uid,
                startTime: startTime,
                executablePath: executablePath,
                name: name,
                argv: []
            )
        ])
    }

    @Test("a session whose process the table still holds is signallable")
    func matched() {
        let availability = SessionControl.availability(
            for: identity(),
            table: table(),
            ownUID: getuid(),
            ownPID: 999_001
        )
        #expect(availability.target?.pid == 4_711)
        #expect(availability.target?.startTime == Self.start)
        #expect(availability.target?.processName == "claude")
        #expect(availability.reason == nil)
    }

    @Test("a session with no pid says so rather than offering a dead menu item")
    func noPID() {
        let availability = SessionControl.availability(
            for: identity(pid: nil),
            table: table(),
            ownPID: 999_001
        )
        #expect(availability.isAvailable == false)
        #expect((availability.reason ?? "").contains("never saw a process"))
    }

    /// `0` means "my whole process group" to `kill(2)`, `-1` means "everything
    /// I own", and `1` is `launchd`. A pid read off another tool's disk must
    /// never be able to mean any of the three.
    @Test("broadcast pids and launchd are refused", arguments: [pid_t(0), -1, 1])
    func broadcastPIDs(_ pid: pid_t) {
        let availability = SessionControl.availability(
            for: identity(pid: pid),
            table: table(pid: pid),
            ownPID: 999_001
        )
        #expect(availability.isAvailable == false)
        #expect((availability.reason ?? "").contains("will signal"))
    }

    @Test("Auspex refuses to signal itself")
    func ownProcess() {
        let availability = SessionControl.availability(
            for: identity(pid: 4_711),
            table: table(),
            ownPID: 4_711
        )
        #expect(availability.reason == "That is Auspex's own process.")
    }

    @Test("Auspex refuses to signal something it is running inside")
    func ownAncestor() {
        // 4711 is our parent: signalling it would take Auspex down with it.
        let processes = StubProcessTable(records: [
            ProcessRecord(pid: 4_711, ppid: 1, startTime: Self.start, executablePath: "/bin/zsh", argv: []),
            ProcessRecord(pid: 999_001, ppid: 4_711, startTime: Self.start, executablePath: "/bin/auspex", argv: [])
        ])
        let availability = SessionControl.availability(
            for: identity(),
            table: processes,
            ownPID: 999_001
        )
        #expect(availability.reason == "Auspex is running inside pid 4711.")
    }

    @Test("a pid that is not in the table is not signalled")
    func gone() {
        let availability = SessionControl.availability(
            for: identity(),
            table: StubProcessTable(records: []),
            ownPID: 999_001
        )
        #expect((availability.reason ?? "").contains("not running any more"))
    }

    @Test("another user's process is left alone")
    func otherUser() {
        let availability = SessionControl.availability(
            for: identity(),
            table: table(uid: getuid() &+ 1),
            ownPID: 999_001
        )
        #expect((availability.reason ?? "").contains("another user"))
    }

    /// The case the whole check exists for: the recorded process exited, its
    /// pid was handed to something else, and the card still shows the number.
    @Test("a recycled pid is refused, and the reason says so")
    func recycled() {
        let availability = SessionControl.availability(
            for: identity(),
            table: table(startTime: Self.start.addingTimeInterval(600)),
            ownPID: 999_001
        )
        #expect(availability.isAvailable == false)
        #expect((availability.reason ?? "").contains("recycled"))
    }

    @Test("a start time inside the tolerance is the same process")
    func withinTolerance() {
        let availability = SessionControl.availability(
            for: identity(),
            table: table(startTime: Self.start.addingTimeInterval(1.5)),
            ownPID: 999_001
        )
        #expect(availability.isAvailable)
    }

    @Test("without a recorded start time, the executable has to still be the harness's")
    func noStartTimeButRightLauncher() {
        let availability = SessionControl.availability(
            for: identity(procStart: nil),
            table: table(executablePath: "/Users/example/.local/bin/claude"),
            ownPID: 999_001
        )
        #expect(availability.isAvailable)
    }

    @Test("without a recorded start time, a pid that is now something else is refused")
    func noStartTimeWrongProcess() {
        let availability = SessionControl.availability(
            for: identity(procStart: nil),
            table: table(executablePath: "/usr/bin/rsync"),
            ownPID: 999_001
        )
        #expect(availability.isAvailable == false)
        #expect((availability.reason ?? "").contains("rsync"))
    }

    /// The kernel truncates its short name at sixteen characters and will not
    /// report a path for every process, so the name alone has to be enough.
    @Test("the kernel's short name is accepted when there is no executable path")
    func shortNameOnly() {
        let availability = SessionControl.availability(
            for: identity(.codex, procStart: nil),
            table: table(executablePath: "", name: "codex"),
            ownPID: 999_001
        )
        #expect(availability.isAvailable)
    }

    @Test("a harness with no command-line launcher is refused when there is no start time", arguments: [
        Harness.claudeCowork, .grokBot
    ])
    func noLauncher(_ harness: Harness) {
        let availability = SessionControl.availability(
            for: identity(harness, procStart: nil),
            table: table(executablePath: "/Applications/Whatever.app/Contents/MacOS/Whatever"),
            ownPID: 999_001
        )
        #expect(availability.isAvailable == false)
    }

    @Test("the last-moment re-check catches a pid that changed hands after the menu opened")
    func stillMatches() {
        let target = SessionControl.Target(pid: 4_711, startTime: Self.start, processName: "claude")
        #expect(SessionControl.stillMatches(target, table: table()))
        #expect(SessionControl.stillMatches(target, table: StubProcessTable(records: [])) == false)
        #expect(
            SessionControl.stillMatches(
                target,
                table: table(startTime: Self.start.addingTimeInterval(600))
            ) == false
        )
        #expect(SessionControl.stillMatches(target, table: table(uid: getuid() &+ 1)) == false)
    }

    @Test("a send whose re-check fails never reaches the syscall")
    func refusedSend() {
        // pid 1 would be `launchd` if this ever got as far as `kill(2)`, which
        // is exactly why the assertion is worth making with that number.
        let target = SessionControl.Target(pid: 1, startTime: Self.start, processName: "launchd")
        let outcome = SessionControl.send(.terminate, to: target, table: table(pid: 1))
        #expect(outcome.isSent == false)
        guard case let .refused(reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("no longer the process"))
    }
}

/// Signalling, against a process the suite started itself.
///
/// `/bin/sleep` and nothing else. It is ours, it does nothing, and it is the
/// only honest way to check that the guard and the syscall are wired to each
/// other — a mocked `kill` would prove that the mock was called.
@Suite("SessionControl · a real process", .serialized)
struct SessionControlLiveTests {
    /// Starts a `/bin/sleep` and returns it with a target built the way the
    /// board would build one: from the pid and the start time the process
    /// table reports.
    private func sleeper() throws -> (Process, SessionControl.Target, ProcessTable) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let table = ProcessTable(maxAge: 0, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        guard let record = table.record(pid: process.processIdentifier) else {
            throw ControlTestError.notInTable
        }
        return (
            process,
            SessionControl.Target(
                pid: record.pid,
                startTime: record.startTime,
                processName: record.name
            ),
            table
        )
    }

    private func identity(pid: pid_t, procStart: Date) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: .claudeCode, sessionID: "sleeper"),
            sourcePath: "/Users/example/store/session.jsonl",
            pid: pid,
            procStart: procStart
        )
    }

    @Test("a live child is signallable, and stops being so once it is gone")
    func interruptThenKill() throws {
        let (process, target, table) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        // The board's question, against the real table.
        table.refresh()
        let availability = SessionControl.availability(
            for: identity(pid: target.pid, procStart: target.startTime),
            table: table
        )
        #expect(availability.target == target)

        // Interrupt: `/bin/sleep` has no handler, so SIGINT ends it.
        table.refresh()
        #expect(SessionControl.send(.interrupt, to: target, table: table).isSent)
        process.waitUntilExit()
        #expect(process.isRunning == false)

        // And the same target is refused afterwards, which is the property
        // that matters: a stale target cannot be re-sent into a recycled pid.
        table.refresh()
        #expect(SessionControl.stillMatches(target, table: table) == false)
        let after = SessionControl.availability(
            for: identity(pid: target.pid, procStart: target.startTime),
            table: table
        )
        #expect(after.isAvailable == false)
    }

    @Test("kill escalates from SIGTERM to SIGKILL against a process that ignores the first")
    func terminateThenForce() throws {
        let (process, target, table) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        table.refresh()
        #expect(SessionControl.send(.terminate, to: target, table: table).isSent)
        process.waitUntilExit()
        #expect(process.isRunning == false)

        // The second step, once the first has already taken: refused, rather
        // than sent to whatever now holds the number.
        table.refresh()
        let outcome = SessionControl.send(.forceKill, to: target, table: table)
        #expect(outcome.isSent == false)
    }
}

private enum ControlTestError: Error {
    case notInTable
}

/// The strings a person reads before agreeing to any of this.
@Suite("SessionControl · what it says")
struct SessionControlWordingTests {
    private let target = SessionControl.Target(
        pid: 4_711,
        startTime: Date(timeIntervalSince1970: 1_700_000_000),
        processName: "claude"
    )

    @Test("the confirmation names the session and the process")
    func confirmation() {
        #expect(SessionControl.killPrompt(title: "rebuild the index", target: target)
            == "Kill rebuild the index?")
        let message = SessionControl.killMessage(target: target, isResumable: true)
        #expect(message.contains("claude (pid 4711)"))
        #expect(message.contains("resumed"))
        #expect(SessionControl.killMessage(target: target, isResumable: false).contains("resumed") == false)
    }

    @Test("an untitled session still gets a sentence a person can read")
    func untitled() {
        #expect(SessionControl.killPrompt(title: "   ", target: target) == "Kill this session?")
    }

    /// A trace note is stored and displayed, so it carries a signal name and a
    /// pid and nothing else — no path, no argv, no prompt text.
    @Test("the trace note says what Auspex did, and only that")
    func note() {
        let note = SessionControl.note(.interrupt, target: target)
        #expect(note == "Auspex sent SIGINT to pid 4711 at your request.")
        #expect(SessionControl.note(.forceKill, target: target).contains("SIGKILL"))
        #expect(SessionControl.failureNote(.terminate, pid: 4_711, reason: "the process had already exited")
            == "Auspex could not send SIGTERM to pid 4711: the process had already exited")
    }

    @Test("errno becomes a sentence rather than a number")
    func errnoText() {
        #expect(SessionControl.describe(errno: ESRCH) == "the process had already exited")
        #expect(SessionControl.describe(errno: EPERM) == "the system refused permission")
    }

    @Test("the signals carry the numbers they claim to")
    func numbers() {
        #expect(SessionControl.Signal.interrupt.number == SIGINT)
        #expect(SessionControl.Signal.terminate.number == SIGTERM)
        #expect(SessionControl.Signal.forceKill.number == SIGKILL)
    }
}
