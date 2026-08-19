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
/// ## Why the invalidation is cheap
///
/// Every rhythm is a pure function of ``BoardClock``'s 4 Hz phase, and the
/// phase is read *here*, in a leaf, and nowhere above it. That is what keeps a
/// board of five hundred sessions from re-evaluating five hundred card bodies
/// four times a second: only the strips of the cards that are actually moving
/// are invalidated, and a card whose session is idle or finished draws
/// ``StaticStrip``, which reads no clock and is therefore never invalidated at
/// all.
///
/// The steps are interpolated with a short `linear` keyed on the phase, so a
/// 4 Hz ticker still produces a smooth breath rather than a stutter.
///
/// ## What the interpolation costs — measured, and unresolved
///
/// The interpolation is not free, and on the live board it is the largest
/// single cost the main thread carries. A new phase arrives every 250 ms and
/// the animation lasts 250 ms, so an animation is always in flight; SwiftUI
/// rebuilds the strip's display list on every display frame for as long as
/// that is true, and AppKit answers a graph that is dirty on every display
/// cycle by re-asking the window for its minimum size.
///
/// `sample <pid> 3`, release build, live against the real store with ~700
/// sessions, window visible, three runs each at matched ingest load:
///
/// | strips | main thread busy | process CPU |
/// | --- | --- | --- |
/// | drawn still (the reduced-motion path) | 1.2–1.6 % | 7.3–8.2 % |
/// | animated, interpolated (this) | 19.8–20.8 % | 24.5–25.8 % |
/// | animated, stepping at 4 Hz, no interpolation | 5.3 % | 10.0 % |
///
/// Two ways out were tried and measured. Animating a view `.opacity(_:)` and
/// an `.offset(x:)` instead of a fill's alpha and a gradient's unit points —
/// on the theory that layer properties are handed to the render server — made
/// no measurable difference (19.0–17.4 % over three runs), so SwiftUI is
/// re-rendering either way. Dropping the interpolation is four times cheaper
/// and visibly steppy. What is left is a design decision — a self-driving
/// `repeatForever` per animating card, which is what ``BoardClock`` was
/// introduced to replace, or a coarser rhythm — and it wants its own measured
/// pass rather than a quiet change here.
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
///
/// ## Why there is no geometry here
///
/// Every rhythm is expressed in shape parameters that interpolate on their
/// own: an opacity, a gradient's unit points, one rectangle per running child.
/// Nothing measures the strip, nothing rebuilds a row of cells, and the
/// implicit `linear` animation keyed on the phase is what turns four steps a
/// second into continuous movement — the interpolation happens in the render
/// server rather than in the view update the ticker drives.
///
/// The earlier version drew twenty-four cells and lit a range of them. It was
/// twenty-four views rebuilt four times a second per animating card, and on a
/// busy board that was most of what the animation cost.
private struct AnimatedStrip: View {
    let motion: StateStyle.Motion
    let color: Color
    let height: CGFloat

    @Environment(BoardClock.self) private var clock: BoardClock?

    /// How many ticks a sweep takes to cross. Six seconds at 4 Hz: slow
    /// enough to read as one thing travelling rather than as a flicker.
    private static let sweepPeriod = 24

    var body: some View {
        let phase = clock?.phase ?? 0
        Group {
            switch motion {
            case .breathe:
                // Four steps to a cycle, so a room full of them reads as calm
                // rather than as blinking.
                bar(opacity: [0.25, 0.5, 0.8, 0.5][phase % 4])
            case .strobe:
                // The one rhythm on the board with a hard edge, because it is
                // the only state that will not resolve itself.
                bar(opacity: phase.isMultiple(of: 2) ? 0.3 : 1)
            case .sweep(let width):
                sweep(phase: phase, width: width)
            case .ticks(let count):
                tickRow(count: count, phase: phase)
            case .steady(let opacity):
                bar(opacity: opacity)
            }
        }
        .animation(.linear(duration: 1 / Double(BoardClock.rate)), value: phase)
    }

    private func bar(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(opacity))
    }

    /// A bright head travelling left to right over a dim base, wrapping.
    ///
    /// The head is a gradient whose unit points move, which needs no
    /// measurement of the strip and animates as two points rather than as a
    /// layout. `autoreverses` is not an option, for the same reason it never
    /// was: a segment that slid back would read as scrubbing rather than as
    /// progress.
    private func sweep(phase: Int, width: Int) -> some View {
        let half = Double(width) / Double(Self.sweepPeriod)
        let centre = Double(phase % Self.sweepPeriod) / Double(Self.sweepPeriod)
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0), color, color.opacity(0)],
                            startPoint: UnitPoint(x: centre - half, y: 0.5),
                            endPoint: UnitPoint(x: centre + half, y: 0.5)
                        )
                    )
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
