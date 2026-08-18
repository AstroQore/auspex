import SwiftUI

/// The line along the bottom of every session card, and the one animated
/// element in the whole board.
///
/// ## What it is for
///
/// A wall of forty cards cannot be read by reading forty cards. It is read the
/// way an instrument panel is read: peripherally, for the thing that is
/// behaving differently. Colour alone does not survive peripheral vision
/// well — motion does. So each state gets a distinct rhythm on one shared
/// 2 pt line, and a person learns the wall in about a minute: slow breath is
/// thinking, a travelling segment is a tool, a hard blink is someone waiting
/// on you.
///
/// ## Why it is cheap
///
/// One `repeatForever` animation per animating card, started once in
/// `onAppear` and never touched again — no timer, no `TimelineView`, nothing
/// that re-evaluates a card's body on every frame. `.steady` states attach no
/// animation at all, so a board full of finished sessions is completely
/// static. The `.id(motion)` on the container is what restarts the animation
/// cleanly when a session changes state: SwiftUI tears the old view down, and
/// the new one's `onAppear` starts the new rhythm from its beginning rather
/// than from wherever the last one happened to be.
///
/// ## Reduced motion
///
/// Every case collapses to a steady bar at the state's colour. The
/// information is still there — the colour and the pill both carry it — and
/// nothing on the screen moves.
struct PulseLine: View {
    let motion: StateStyle.Motion
    let color: Color
    /// Desaturates the line for a session that has gone quiet.
    var isStale = false
    var height: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                steady(opacity: staticOpacity)
            } else {
                switch motion {
                case .steady(let opacity):
                    steady(opacity: opacity)
                case .breathe:
                    BreathingBar(color: tinted)
                case .sweep(let period):
                    SweepingBar(color: tinted, period: period)
                case .strobe:
                    StrobingBar(color: tinted)
                case .ticks(let count):
                    TickingBar(color: tinted, count: count)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // A state change should restart the rhythm, not cross-fade into it.
        .id(motion)
        .accessibilityHidden(true)
    }

    private var tinted: Color {
        isStale ? color.opacity(0.45) : color
    }

    /// What the line shows when it is not allowed to move: enough presence to
    /// carry the colour, not so much that a wall of them becomes stripes.
    private var staticOpacity: Double {
        switch motion {
        case .steady(let opacity): opacity
        case .breathe, .sweep, .ticks: 0.55
        case .strobe: 0.9
        }
    }

    private func steady(opacity: Double) -> some View {
        Rectangle().fill(tinted.opacity(opacity))
    }
}

// MARK: - Rhythms

/// Thinking: the whole line fades up and down. Slow, so a room full of them
/// reads as calm.
private struct BreathingBar: View {
    let color: Color
    @State private var isLit = false

    var body: some View {
        Rectangle()
            .fill(color.opacity(isLit ? 0.70 : 0.20))
            .animation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true), value: isLit)
            .onAppear { isLit = true }
    }
}

/// A tool is open: a bright segment travels the width and wraps.
///
/// The dim base stays lit underneath so the card still has an edge between
/// passes. `autoreverses: false` matters — a segment that slid back would read
/// as scrubbing, not as progress.
private struct SweepingBar: View {
    let color: Color
    let period: Double
    @State private var isTravelling = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let segment = max(36, width * 0.26)
            Rectangle()
                .fill(color.opacity(0.16))
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [color.opacity(0), color, color.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: segment)
                    .offset(x: isTravelling ? width : -segment)
                    .animation(
                        .linear(duration: period).repeatForever(autoreverses: false),
                        value: isTravelling
                    )
                }
                .onAppear { isTravelling = true }
        }
        // Only the travelling segment leaves its bounds, so only it pays
        // for a clip.
        .clipped()
    }
}

/// Waiting for permission: a hard on, a quick fall. The only rhythm on the
/// board with a sharp edge, because it is the only state that will not
/// resolve itself.
private struct StrobingBar: View {
    let color: Color
    @State private var isLit = false

    var body: some View {
        Rectangle()
            .fill(color.opacity(isLit ? 1 : 0.30))
            .animation(.easeOut(duration: 0.45).repeatForever(autoreverses: true), value: isLit)
            .onAppear { isLit = true }
    }
}

/// Delegating: one tick per running child, lighting in sequence.
///
/// The count is the information — three ticks means three children — and the
/// sequence is what distinguishes it from a static segmented bar. Each tick
/// carries the same animation offset by its index, which needs no coordinator
/// and stays in step no matter when the card was created.
private struct TickingBar: View {
    let color: Color
    let count: Int
    @State private var isRunning = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Rectangle()
                    .fill(color.opacity(isRunning ? 0.85 : 0.18))
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: isRunning
                    )
            }
        }
        .onAppear { isRunning = true }
    }
}
