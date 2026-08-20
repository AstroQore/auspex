import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Testing

@testable import AuspexApp

/// The whole path a click takes: the menu's question, the dialog, the signal,
/// and the line that ends up in the session's trace.
///
/// Driven against a `/bin/sleep` the suite starts itself, which is the only
/// process it is ever allowed to signal. Everything else is real — the process
/// table is the kernel's, the guard is the one the app ships, and the syscall
/// is `kill(2)`.
@MainActor
@Suite("Session control · the click path", .serialized)
struct SessionControlModelTests {
    /// A model wired the way `AppEnvironment` wires it, plus a box to catch
    /// the events and notices it would otherwise send into the pipeline.
    @MainActor
    private final class Harnessed {
        let model = SessionControlModel()
        var events: [AgentEvent] = []
        var notices: [String] = []
        let table = ProcessTable(
            maxAge: 0.2,
            includesArguments: false,
            includesWorkingDirectory: false
        )

        init() {
            model.start(table: table)
            model.onEvent = { [weak self] in self?.events.append($0) }
            model.onNotice = { [weak self] in self?.notices.append($0) }
        }

        /// The notes the model wrote, as sentences.
        var notes: [String] {
            events.compactMap { event in
                guard case let .note(text) = event.kind else { return nil }
                return text
            }
        }
    }

    private func sleeper() throws -> (Process, SessionIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let table = ProcessTable(maxAge: 0, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        let record = try #require(table.record(pid: process.processIdentifier))
        let identity = SessionIdentity(
            key: SessionKey(harness: .claudeCode, sessionID: "11111111-2222-3333-4444-555555555555"),
            sourcePath: "/Users/example/store/session.jsonl",
            cwd: "/Users/example/Code/widget",
            pid: record.pid,
            procStart: record.startTime,
            title: "rebuild the index"
        )
        return (process, identity)
    }

    @Test("interrupt asks nothing, signals, and says so in the trace")
    func interrupt() throws {
        let harnessed = Harnessed()
        let (process, identity) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        #expect(harnessed.model.availability(for: identity).isAvailable)
        harnessed.model.interrupt(identity)
        process.waitUntilExit()

        #expect(process.isRunning == false)
        // No dialog: an interrupt is the recoverable one.
        #expect(harnessed.model.prompt == nil)
        #expect(harnessed.notes == ["Auspex sent SIGINT to pid \(identity.pid!) at your request."])
        #expect(harnessed.events.allSatisfy { $0.session == identity.key })
        #expect(harnessed.notices.isEmpty)
    }

    @Test("kill opens a dialog naming the session and the process, and sends nothing yet")
    func killAsksFirst() throws {
        let harnessed = Harnessed()
        let (process, identity) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        harnessed.model.requestKill(identity)
        let prompt = try #require(harnessed.model.prompt)
        #expect(prompt.step == .terminate)
        #expect(prompt.headline == "Kill rebuild the index?")
        #expect(prompt.message.contains("pid \(identity.pid!)"))
        #expect(prompt.confirmTitle == "Kill")
        // Claude Code has a CLI resume, so the dialog says the conversation
        // survives — the thing people actually want to know before agreeing.
        #expect(prompt.message.contains("resumed"))

        // Nothing has been signalled: the ask is the whole of what happened.
        #expect(process.isRunning)
        #expect(harnessed.notes.isEmpty)

        harnessed.model.dismiss()
        #expect(harnessed.model.prompt == nil)
        #expect(process.isRunning)
    }

    @Test("confirming sends SIGTERM and records it")
    func killConfirms() throws {
        let harnessed = Harnessed()
        let (process, identity) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        harnessed.model.requestKill(identity)
        harnessed.model.confirm(try #require(harnessed.model.prompt))
        process.waitUntilExit()

        #expect(process.isRunning == false)
        #expect(harnessed.notes == ["Auspex sent SIGTERM to pid \(identity.pid!) at your request."])
    }

    /// The case the guard exists for, reproduced end to end: the dialog is
    /// open, the process exits underneath it, and the click that follows must
    /// not land on whatever now holds the number.
    @Test("a process that exits while the dialog is open is not signalled afterwards")
    func exitsUnderTheDialog() throws {
        let harnessed = Harnessed()
        let (process, identity) = try sleeper()

        harnessed.model.requestKill(identity)
        let prompt = try #require(harnessed.model.prompt)

        process.terminate()
        process.waitUntilExit()

        harnessed.model.confirm(prompt)
        #expect(harnessed.notes.count == 1)
        #expect(harnessed.notes[0].contains("could not send SIGTERM"))
        #expect(harnessed.notices.count == 1)
    }

    @Test("a session with no process offers nothing, and explains why")
    func noProcess() {
        let harnessed = Harnessed()
        let identity = SessionIdentity(
            key: SessionKey(harness: .cursor, sessionID: "no-process"),
            sourcePath: "/Users/example/store/store.db"
        )
        let availability = harnessed.model.availability(for: identity)
        #expect(availability.isAvailable == false)
        #expect((availability.reason ?? "").isEmpty == false)

        // And clicking anyway does nothing but say so.
        harnessed.model.interrupt(identity)
        harnessed.model.requestKill(identity)
        #expect(harnessed.model.prompt == nil)
        #expect(harnessed.notes.isEmpty)
    }

    /// Before the pipeline is up there is no process table, so every session
    /// is unsignallable rather than signalled against a table that is not
    /// there.
    @Test("an unstarted model signals nothing")
    func beforeStart() throws {
        let model = SessionControlModel()
        let (process, identity) = try sleeper()
        defer { if process.isRunning { process.terminate() } }

        #expect(model.availability(for: identity).isAvailable == false)
        model.interrupt(identity)
        #expect(process.isRunning)
    }
}

/// The demo's stand-in process.
///
/// Worth a test of its own because it is the only part of the control feature
/// a person can try by hand, and because it starts a real process: something
/// has to assert that it is started once, attached to a session, and stopped.
@Suite("Session control · the demo's stand-in", .serialized)
struct DemoSignalTargetTests {
    @Test("one demo session is lent a live pid, and the process goes when the source does")
    func lendsAndCleansUp() async throws {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(of: AgentEvent.self)
        let source = DemoEventSource(continuation: continuation)
        let run = Task { await source.run() }

        // The earliest session in the script opens at t+0.2s; the patch is
        // emitted straight after its `sessionStarted`.
        var lent: (key: SessionKey, pid: pid_t)?
        for await event in events {
            if case let .identityUpdated(patch) = event.kind, let pid = patch.pid {
                lent = (event.session, pid)
                break
            }
        }
        run.cancel()

        let borrowed = try #require(lent)
        let table = ProcessTable(maxAge: 0, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        // A real, running process — which is the whole point — and ours.
        let record = try #require(table.record(pid: borrowed.pid))
        #expect(record.name == "sleep")
        #expect(record.uid == getuid())

        await source.stop()
        // `terminate()` is asynchronous; the process is reaped shortly after.
        var attempts = 0
        while attempts < 50 {
            table.refresh()
            if table.record(pid: borrowed.pid) == nil { break }
            try await Task.sleep(for: .milliseconds(40))
            attempts += 1
        }
        table.refresh()
        #expect(table.record(pid: borrowed.pid) == nil)
    }

    @Test("a renderer's demo starts no process at all")
    func rendererLendsNothing() async throws {
        let before = sleepers()
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(of: AgentEvent.self)
        let source = DemoEventSource(continuation: continuation, lendsProcess: false)
        let run = Task { await source.run() }

        var seen = 0
        for await event in events {
            if case .identityUpdated(let patch) = event.kind {
                #expect(patch.pid == nil)
            }
            seen += 1
            if seen > 30 { break }
        }
        run.cancel()
        await source.stop()
        #expect(sleepers() == before)
    }

    /// How many `/bin/sleep` processes this user has, so the assertion is
    /// about what the test started rather than about the machine.
    private func sleepers() -> Int {
        let table = ProcessTable(maxAge: 0, includesArguments: false, includesWorkingDirectory: false)
        table.refresh()
        return table.find { $0.uid == getuid() && $0.name == "sleep" }.count
    }
}
