import AppKit
import Foundation

/// How long the main thread is busy, per turn of its run loop.
///
/// ## Why a meter rather than `sample`
///
/// `AGENTS.md` § 4.1 asks for process CPU, and process CPU is the right budget
/// — but it is a terrible instrument for *this* bug. The failure a person
/// reports is "the window stopped responding", which is a statement about one
/// thread, and the machine this is developed on is running a dozen agents whose
/// own CPU moves the process number by tens of per cent between two identical
/// runs. A `sample` call graph answers "what is the main thread doing" and says
/// nothing about how long it did it for.
///
/// What a frozen window actually is: the main thread never gets back to
/// `mach_msg_trap`. So that is what this measures. AppKit's run loop wakes,
/// does everything it has to do — events, the SwiftUI transaction, Core
/// Animation's flush — and goes back to sleep; the interval between waking and
/// sleeping is one turn, and a turn longer than a frame is a dropped frame
/// whatever else the machine is doing.
///
/// Two `CFRunLoopObserver`s, one at `.afterWaiting` and one at
/// `.beforeWaiting`, and a subtraction. It costs two `mach_absolute_time`
/// reads per turn, and it is off unless `AUSPEX_STALL_LOG=1` is in the
/// environment — it prints to stdout, which is a place a shipping app has no
/// business writing to.
///
/// ## Reading the line
///
/// ```text
/// auspex-meter: 5.0s · 312 turns · busy 71.4% · median 9.1ms · p95 84.2ms · max 190.3ms
/// ```
///
/// `busy` is the share of the wall clock the main thread spent awake, which is
/// the number the budget is about. `max` is the one that says whether the
/// window froze: anything over about 100 ms is a visible stall, and a window
/// whose p95 is over 16 ms cannot hold 60 fps no matter what the average says.
@MainActor
final class MainThreadMeter {
    /// The one meter, or `nil` when nobody asked for one.
    static let shared: MainThreadMeter? = {
        guard ProcessInfo.processInfo.environment["AUSPEX_STALL_LOG"] == "1" else { return nil }
        return MainThreadMeter()
    }()

    /// How often a summary is printed.
    private static let reportInterval: TimeInterval = 5

    /// Every turn's busy time in the current window, in seconds.
    private var turns: [TimeInterval] = []
    private var wokeAt: TimeInterval?
    private var windowStart = ProcessInfo.processInfo.systemUptime
    private var observers: [CFRunLoopObserver] = []

    private init() {}

    /// Starts measuring. Idempotent; the window's `task` calls it.
    func start() {
        guard observers.isEmpty else { return }
        // Last of everything on the way in and first on the way out, so a turn
        // brackets every other observer — AppKit's display cycle and SwiftUI's
        // transaction flush both run inside these two marks.
        add(activity: .afterWaiting, order: CFIndex.min) { [weak self] in
            self?.wokeAt = ProcessInfo.processInfo.systemUptime
        }
        add(activity: .beforeWaiting, order: CFIndex.max) { [weak self] in
            self?.finishTurn()
        }
        FileHandle.standardOutput.write(Data("auspex-meter: measuring the main thread\n".utf8))
    }

    /// Stops measuring and prints whatever is left.
    func stop() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers.removeAll()
        report()
    }

    private func add(
        activity: CFRunLoopActivity,
        order: CFIndex,
        _ body: @escaping @MainActor () -> Void
    ) {
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activity.rawValue,
            true,
            order,
            { _, _ in MainActor.assumeIsolated { body() } }
        ) else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        observers.append(observer)
    }

    private func finishTurn() {
        guard let wokeAt else { return }
        self.wokeAt = nil
        let now = ProcessInfo.processInfo.systemUptime
        turns.append(max(0, now - wokeAt))
        guard now - windowStart >= Self.reportInterval else { return }
        report(now: now)
    }

    private func report(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer {
            turns.removeAll(keepingCapacity: true)
            windowStart = now
        }
        guard !turns.isEmpty else { return }
        FileHandle.standardOutput.write(Data((Self.line(
            turns: turns,
            elapsed: max(0.001, now - windowStart)
        ) + "\n").utf8))
    }

    /// One summary line, as a value, so the format can be asserted on without
    /// a run loop.
    ///
    /// The percentiles are taken by rank on the sorted turns rather than
    /// interpolated: a hundred turns is a small sample, and inventing a number
    /// between two measurements would be pretending to a precision the
    /// instrument does not have.
    static func line(turns: [TimeInterval], elapsed: TimeInterval) -> String {
        let sorted = turns.sorted()
        let busy = turns.reduce(0, +)
        func ms(_ seconds: TimeInterval) -> String {
            String(format: "%.1fms", seconds * 1000)
        }
        func rank(_ fraction: Double) -> TimeInterval {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
            return sorted[index]
        }
        return "auspex-meter: "
            + String(format: "%.1fs", elapsed)
            + " · \(turns.count) turns"
            + String(format: " · busy %.1f%%", busy / elapsed * 100)
            + " · median \(ms(rank(0.5)))"
            + " · p95 \(ms(rank(0.95)))"
            + " · max \(ms(sorted.last ?? 0))"
    }
}
