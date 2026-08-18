import AgentSessionLive
import SwiftUI

/// How a ``SessionState`` looks and how it moves.
///
/// ## Colour is one half of the answer, motion is the other
///
/// Six states in six colours is a legend a person has to learn. Six states in
/// six colours *that move differently* is something they can read without
/// learning: a slow breath means thinking, a travelling segment means a tool
/// is running, a hard blink means someone is waiting on you. Peripheral vision
/// is far better at motion than at hue, which is exactly what a board on a
/// second display needs.
///
/// So every state carries a ``Motion``, and it is the same mechanism in every
/// case — one 2 pt line along the bottom edge of the card. One device,
/// six behaviours. Adding a second animated element would make the wall busy
/// without making it more informative.
///
/// Sessions that are not doing anything animate nothing at all: `.idle` and
/// `.ended` resolve to ``Motion/steady(_:)``, which renders a plain rectangle
/// with no animation attached. A board of forty finished sessions costs the
/// render loop nothing.
struct StateStyle: Sendable, Equatable {
    /// The state's colour, used by the pill, the pulse line, and — for
    /// `waitingPermission` only — the card's border.
    let color: Color
    /// The pill's text. Uppercase at the call site; kept in title case here so
    /// it can also be read aloud by VoiceOver.
    let label: String
    /// An SF Symbol for the pill and the menu bar list.
    let symbolName: String
    /// How the pulse line behaves.
    let motion: Motion
    /// Whether this state should pull the eye. Exactly one state does.
    let isAlarming: Bool

    /// What the pulse line does. See the type's discussion for why this is
    /// part of the style rather than a view detail.
    enum Motion: Sendable, Equatable, Hashable {
        /// A fixed bar at this opacity. No animation is attached at all.
        case steady(Double)
        /// The whole line fades between two opacities and back. Thinking.
        case breathe
        /// A bright segment travels left to right and wraps. A tool is open;
        /// `period` is shorter for a file write, which is the faster activity.
        case sweep(period: Double)
        /// The line snaps to full and falls away. Someone is waiting.
        case strobe
        /// One tick per child, lighting in sequence.
        case ticks(count: Int)
    }
}

extension SessionState {
    /// This state's visual identity.
    var style: StateStyle {
        switch self {
        case .idle:
            StateStyle(
                color: AuspexPalette.stateIdle,
                label: "Idle",
                symbolName: "pause",
                motion: .steady(0.16),
                isAlarming: false
            )
        case .thinking:
            StateStyle(
                color: AuspexPalette.stateThinking,
                label: "Thinking",
                symbolName: "brain",
                motion: .breathe,
                isAlarming: false
            )
        case .toolCalling:
            StateStyle(
                color: AuspexPalette.stateTool,
                label: "Tool",
                symbolName: "wrench.adjustable",
                motion: .sweep(period: 1.7),
                isAlarming: false
            )
        case .writingFile:
            StateStyle(
                color: AuspexPalette.stateWriting,
                label: "Writing",
                symbolName: "square.and.pencil",
                motion: .sweep(period: 1.05),
                isAlarming: false
            )
        case .delegating(let children):
            StateStyle(
                color: AuspexPalette.stateDelegating,
                // The child count rides in the pill's badge, so the word does
                // not have to carry it.
                label: "Children",
                symbolName: "arrow.triangle.branch",
                motion: .ticks(count: max(1, min(children, 8))),
                isAlarming: false
            )
        case .waitingPermission:
            StateStyle(
                color: AuspexPalette.statePermission,
                // "Blocked", not "Waiting for permission": it is the word the
                // section headers and the menu bar already use for this state,
                // and a pill wide enough for the long form eats the card title
                // it sits next to.
                label: "Blocked",
                symbolName: "exclamationmark.triangle.fill",
                motion: .strobe,
                isAlarming: true
            )
        case .ended:
            StateStyle(
                color: AuspexPalette.stateEnded,
                label: "Ended",
                symbolName: "stop.fill",
                motion: .steady(0),
                isAlarming: false
            )
        }
    }

    /// The line under a card's title: what is actually happening, in the
    /// harness's own words.
    ///
    /// `nil` when the state has nothing to add beyond its pill — an idle
    /// session's activity line would say "Idle" twice.
    var activityDescription: String? {
        switch self {
        case .idle, .thinking, .ended:
            nil
        case .toolCalling(let name):
            name
        case .writingFile(let path):
            path.map { ($0 as NSString).lastPathComponent } ?? "file"
        case .delegating(let children):
            children == 1 ? "1 child session" : "\(children) child sessions"
        case .waitingPermission(let tool):
            tool ?? "a tool"
        }
    }

    /// The child count, for the badge on a delegating card. `nil` otherwise.
    var childCount: Int? {
        if case .delegating(let children) = self { return children }
        return nil
    }
}

/// The state pill: a symbol, a condensed uppercase word, and — when the
/// session is delegating — the number of children.
///
/// Tinted rather than filled. A filled pill at this size becomes the loudest
/// thing on the card, and the loudest thing on a card should be its title.
/// The exception is `waitingPermission`, which is filled on purpose: it is the
/// one state that is allowed to shout.
struct StatePill: View {
    let state: SessionState
    var isStale = false

    var body: some View {
        let style = state.style
        let filled = style.isAlarming
        HStack(spacing: 3) {
            Image(systemName: style.symbolName)
                .font(.system(size: 8, weight: .bold))
            Text(style.label)
                .auspexLabel(AuspexType.labelSmall)
            if let children = state.childCount {
                Text("\(children)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 3)
                    .background(
                        Capsule().fill(style.color.opacity(filled ? 0.35 : 0.20))
                    )
            }
        }
        .foregroundStyle(filled ? Color.white : style.color)
        .opacity(isStale ? 0.65 : 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(filled ? style.color.opacity(0.92) : style.color.opacity(0.13))
        )
        .overlay(
            Capsule()
                .strokeBorder(style.color.opacity(filled ? 0 : 0.30), lineWidth: 1)
        )
        .accessibilityLabel(state.label)
    }
}

/// The "stale" tag: shown beside the pill when a session claims to be working
/// but has said nothing for longer than the reducer's patience.
///
/// A tag rather than a state, because that is what staleness is — a long
/// `swift build` is silent and perfectly healthy, and turning it into a state
/// would mean throwing away what the session was actually doing.
struct StaleTag: View {
    var body: some View {
        Text("Stale")
            .auspexLabel(AuspexType.labelSmall)
            .foregroundStyle(AuspexPalette.stateStale)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                Capsule().strokeBorder(
                    AuspexPalette.stateStale.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])
                )
            )
            .accessibilityLabel("Stale: no events recently")
    }
}
