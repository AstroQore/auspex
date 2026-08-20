import Foundation
import Observation
import SwiftUI

/// The one clock on the board.
///
/// ## Why a clock at all
///
/// The stopwatch beside every running card has to count. It used to do that
/// with one self-updating `Text` per card, which is fine for ten cards and is a
/// room heater for five hundred: every one of them is an independent timer the
/// render loop has to service, and none of them is doing anything the others
/// are not.
///
/// So there is one ticker, at 1 Hz, and every stopwatch is a pure function of
/// it. They all show the same instant as a result, rather than each sampling
/// `Date()` at whatever moment its own body happened to run.
///
/// ## Why it is only the stopwatches
///
/// It used to carry a second, faster property — a 4 Hz `phase` — because the
/// activity strip under every card was a function of it. That strip is now a
/// `CAGradientLayer` with animations that repeat forever on the render server
/// (see ``ActivityStrip``), so nothing on the board needs a phase, and the
/// clock ticks once a second instead of four times.
///
/// The remaining reader is ``ElapsedLabel``, in a leaf. Reading `now` in a
/// card's body, or in the board's, would re-evaluate every card once a second
/// and undo the arrangement.
@MainActor
@Observable
final class BoardClock {
    /// The wall clock, republished once a second.
    private(set) var now = Date()

    /// Runs until the surrounding task is cancelled.
    ///
    /// Deadlines are computed from a fixed start instant rather than by
    /// sleeping for a fixed gap each time, so a scheduler hiccup costs one
    /// late tick instead of shifting every tick after it.
    func run() async {
        let start = ContinuousClock.now
        var next = 0
        while !Task.isCancelled {
            next += 1
            let deadline = start.advanced(by: .seconds(next))
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            now = Date()
        }
    }
}
