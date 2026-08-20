import AgentSessionLive
import Foundation

/// A real process for the demo's sessions to point at, so that Interrupt and
/// Kill can be tried without a harness anywhere near it.
///
/// The demo board is fabricated: its sessions carry pids that belong to
/// nothing, and ``SessionControl`` correctly refuses to signal any of them.
/// That is the right behaviour and it makes the two controls untestable by
/// hand — the one part of the app whose failure mode is "it signalled the
/// wrong process" would ship having only ever been exercised by a unit test.
///
/// So the demo starts a `/bin/sleep` and lends one session its pid. Everything
/// downstream is then real: the process table sees it, the guard verifies
/// `(pid, startTime)` against it, `kill(2)` goes to it, and the trace records
/// what was sent. The only fiction is which session the number is written on.
///
/// `/bin/sleep` specifically, with a bounded argument. It holds no files open,
/// it has no children, and if Auspex is force-quit before ``stop()`` runs, the
/// worst that is left behind is a process that exits by itself within the
/// quarter hour.
actor DemoSignalTarget {
    private var process: Process?

    /// How long the stand-in lives if nothing kills it. Long enough to outlast
    /// a demo, short enough that a leaked one is not a leak anybody notices.
    private static let lifetime = "900"

    /// The pid and start time of a live stand-in, starting one if the last was
    /// killed.
    ///
    /// Respawning is the point: the demo exists to be tried, and a Kill that
    /// works once and then leaves every session permanently unsignallable
    /// would demonstrate half of the feature.
    func current() -> (pid: pid_t, procStart: Date)? {
        if let process, process.isRunning {
            if let started = startTime(of: process.processIdentifier) {
                return (process.processIdentifier, started)
            }
        }
        // Whatever is there has to go before anything replaces it. Dropping
        // the reference without terminating would leak one stand-in per
        // replacement, which is exactly the shape of leak a demo produces
        // hundreds of times before anybody notices.
        stop()
        let next = Process()
        next.executableURL = URL(fileURLWithPath: "/bin/sleep")
        next.arguments = [Self.lifetime]
        // No inherited pipes: nothing reads this process's output, and leaving
        // it attached to the app's own stdout would put its exit status in the
        // console.
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        guard (try? next.run()) != nil else { return nil }
        process = next
        guard let started = startTime(of: next.processIdentifier) else { return nil }
        return (next.processIdentifier, started)
    }

    /// Ends the stand-in. Called from the app's own shutdown.
    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// The kernel's start time for a pid — the same field the guard compares
    /// against, read the same way, so the demo cannot accidentally pass a
    /// check the real board would fail.
    private func startTime(of pid: pid_t) -> Date? {
        let table = ProcessTable(
            maxAge: 0,
            includesArguments: false,
            includesWorkingDirectory: false
        )
        table.refresh()
        return table.record(pid: pid)?.startTime
    }
}
