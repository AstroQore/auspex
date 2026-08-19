import AuspexCore
import SwiftUI

/// The strip along the bottom of every session card, and the only animated
/// element on the whole board.
///
/// ## What it is for
///
/// A wall of forty cards cannot be read by reading forty cards. It is read the
/// way an instrument panel is read: peripherally, for the thing that is
/// behaving differently. Colour alone does not survive peripheral vision
/// well — motion does. So each state gets a distinct rhythm on one shared
/// strip, and a person learns the wall in about a minute: slow breath is
/// thinking, a travelling cell is a tool, a hard blink is someone waiting on
/// you.
///
/// ## Why it is cheap
///
/// Every rhythm is a pure function of ``BoardClock``'s 4 Hz phase, and the
/// phase is read *here*, in a leaf, and nowhere above it. That is what keeps a
/// board of five hundred sessions from re-evaluating five hundred card bodies
/// four times a second: only the strips of the cards that are actually moving
/// are invalidated, and a card whose session is idle or finished draws
/// ``StaticStrip``, which reads no clock and is therefore never invalidated at
/// all.
///
/// The steps are interpolated with a short `easeInOut` keyed on the phase, so
/// a 4 Hz ticker still produces a smooth breath rather than a stutter.
///
/// ## Reduced motion
///
/// Every case collapses to a plain bar at the state's colour. The information
/// is still there — the colour, the dot, and the pill all carry it — and
/// nothing on the screen moves.
struct ActivityStrip: View {
    let motion: StateStyle.Motion
    let color: Color
    /// Desaturates the strip for a session that has gone quiet.
    var isStale = false
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many cells the strip is divided into. Enough to read as a bar
    /// chart of the last minute rather than as a progress bar.
    static let cellCount = 24

    var body: some View {
        Group {
            if reduceMotion || !motion.isAnimated {
                StaticStrip(color: tint, opacity: staticOpacity, height: height)
            } else {
                AnimatedStrip(motion: motion, color: tint, height: height)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        isStale ? color.opacity(0.5) : color
    }

    /// What the strip shows when it is not allowed to move: enough presence to
    /// carry the colour, not so much that a wall of them becomes stripes.
    private var staticOpacity: Double {
        switch motion {
        case .steady(let opacity): opacity
        case .breathe, .sweep, .ticks: 0.6
        case .strobe: 0.9
        }
    }
}

/// A strip that does not move, and — importantly — does not read the clock.
private struct StaticStrip: View {
    let color: Color
    let opacity: Double
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(opacity))
    }
}

/// A strip driven by the board's clock.
///
/// The clock is optional so a card rendered outside the board — a preview, a
/// screenshot renderer — degrades to a still strip instead of trapping.
private struct AnimatedStrip: View {
    let motion: StateStyle.Motion
    let color: Color
    let height: CGFloat

    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        let phase = clock?.phase ?? 0
        Group {
            switch motion {
            case .breathe:
                bar(opacity: phase.isMultiple(of: 2) ? 0.25 : 0.8)
            case .strobe:
                bar(opacity: phase.isMultiple(of: 2) ? 0.30 : 1)
            case .sweep(let cells):
                cellRow(lit: sweepIndices(phase: phase, span: cells))
            case .ticks(let count):
                tickRow(count: count, phase: phase)
            case .steady(let opacity):
                bar(opacity: opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: phase)
    }

    private func bar(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(opacity))
    }

    /// The travelling head, as a set of lit cell indices.
    ///
    /// The head is `span` cells wide and wraps, which is what makes it read as
    /// progress rather than as scrubbing — a segment that slid back would say
    /// something the session is not doing.
    private func sweepIndices(phase: Int, span: Int) -> ClosedRange<Int> {
        let total = ActivityStrip.cellCount
        let head = phase % total
        return head...(head + span - 1)
    }

    private func cellRow(lit: ClosedRange<Int>) -> some View {
        let total = ActivityStrip.cellCount
        return HStack(spacing: 2) {
            ForEach(0..<total, id: \.self) { index in
                let isLit = lit.contains(index) || lit.contains(index + total)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(isLit ? 0.95 : 0.16))
            }
        }
    }

    /// One tick per running child, lighting in sequence. The count *is* the
    /// information — three ticks means three children — and the sequence is
    /// what distinguishes it from a static segmented bar.
    private func tickRow(count: Int, phase: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color.opacity(phase % count == index ? 0.95 : 0.22))
            }
        }
    }
}

/// A stopwatch that is driven by the board's clock rather than by one of its
/// own.
///
/// It reads ``BoardClock/second`` and nothing else, so it is invalidated once
/// a second — and a session that has ended reads nothing at all, because its
/// duration is fixed and a frozen number does not need a clock to tell it so.
struct ElapsedLabel: View {
    /// When the interval being measured began.
    let since: Date?
    /// When it stopped, for a session that is over. `nil` while it is running.
    var until: Date?
    var font: Font = AuspexType.monoClock
    var tint: Color = AuspexPalette.text

    var body: some View {
        Group {
            if let since {
                if let until {
                    Text(DurationFormat.clock(until.timeIntervalSince(since)))
                } else {
                    RunningElapsed(since: since)
                }
            } else {
                Text(verbatim: "--:--")
            }
        }
        .font(font)
        .auspexTabularDigits()
        .foregroundStyle(tint)
    }
}

/// The half of ``ElapsedLabel`` that is actually live.
///
/// The clock's ``BoardClock/now`` is what the duration is measured against,
/// which is both what subscribes this view to the 1 Hz tick and what keeps
/// every stopwatch on the wall showing the same instant.
private struct RunningElapsed: View {
    let since: Date

    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        let now = clock?.now ?? Date()
        return Text(DurationFormat.clock(now.timeIntervalSince(since)))
    }
}
