import Foundation
import Observation
import SwiftUI

/// The one clock on the board.
///
/// ## Why a clock at all
///
/// Two things on the wall move on their own: the activity strip under each
/// card, and the elapsed stopwatch beside it. Both used to drive themselves —
/// a `repeatForever` animation per card, and one self-updating `Text` per
/// stopwatch — which is fine for ten cards and is a room heater for five
/// hundred. Every one of them is an independent timer the render loop has to
/// service, and none of them is doing anything the others are not.
///
/// So there is one ticker, at 4 Hz, and everything that moves is a pure
/// function of its phase.
///
/// ## Why two properties instead of one
///
/// ``phase`` advances four times a second; ``second`` advances once. They are
/// stored separately rather than derived at the call site because Observation
/// tracks reads *per property*: a stopwatch that reads only `second` is
/// invalidated once a second, not four times, and a card that reads neither is
/// never invalidated at all.
///
/// That is the whole performance story of the board, and it only works if the
/// reads stay where they are. The clock is read by two leaf views —
/// ``ActivityStrip`` and ``ElapsedLabel`` — and by nothing else. Reading it in
/// a card's body, or in the board's, would re-evaluate every card four times a
/// second and undo the arrangement.
@MainActor
@Observable
final class BoardClock {
    /// Ticks per second. Fast enough that a sweeping strip reads as travel,
    /// slow enough that a board of forty animating cards is a rounding error.
    static let rate = 4

    /// The 4 Hz counter. Everything animated is a function of this.
    private(set) var phase = 0

    /// The wall clock, republished once a second. Drives the stopwatches, and
    /// keeps them all reading the same instant rather than each sampling
    /// `Date()` at whatever moment its own body happened to run.
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
            let deadline = start.advanced(by: .milliseconds(1_000 / Self.rate * next))
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            phase = next
            // Republished only on a whole second: an `@Observable` property
            // invalidates everything that read it on every write, including a
            // write of the value it already held.
            if next.isMultiple(of: Self.rate) { now = Date() }
        }
    }
}
