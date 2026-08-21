import AgentSessionLive
import SwiftUI

/// How a ``SessionState`` looks and how it moves.
///
/// ## Colour is one half of the answer, motion is the other
///
/// Eight states in eight colours is a legend a person has to learn. Eight
/// states in eight colours *that move differently* is something they can read
/// without learning: a slow breath means thinking, a travelling segment means
/// a tool is running, a hard blink means someone is waiting on you. Peripheral
/// vision is far better at motion than at hue, which is exactly what a board
/// on a second display needs.
///
/// So every state carries a ``Motion``, and it is the same mechanism in every
/// case — one strip along the bottom of the card. One device, six behaviours.
/// A second animated element would make the wall busy without making it more
/// informative.
///
/// Sessions that are not doing anything animate nothing at all: `.idle` and
/// `.ended` resolve to ``Motion/steady(_:)``, whose `isAnimated` is `false`,
/// so ``ActivityStrip`` draws them as one rectangle in SwiftUI and gives them
/// no layer and no animation. A wall of four hundred finished sessions costs
/// the render loop nothing.
struct StateStyle: Sendable, Equatable {
    /// The state's colour: the pill, the dot, the strip, and — for
    /// `waitingPermission` only — the card's outline and glow.
    let color: Color
    /// The pill's text, in sentence case. "Needs you" rather than "Waiting for
    /// permission": it is the phrasing the summary chips and the menu bar
    /// already use, and it is what a person would say out loud.
    let label: String
    /// The one-character mark on the card's activity line and in the trace
    /// gutter. Drawn in ``color`` and set in SF Mono, so a column of them
    /// lines up down the trace.
    let glyph: String
    /// An SF Symbol, for the places AppKit will only take one — the menu bar
    /// label, and VoiceOver.
    let symbolName: String
    /// How the activity strip behaves.
    let motion: Motion
    /// Whether this state should pull the eye. Exactly one state does.
    let isAlarming: Bool

    /// What the activity strip does.
    ///
    /// A description of a rhythm, not of a frame: ``ActivityStrip`` turns each
    /// case into a `CAAnimation` that repeats forever on the render server, so
    /// nothing here is sampled against a clock and no case costs the main
    /// thread anything per frame.
    enum Motion: Sendable, Equatable, Hashable {
        /// A fixed bar at this opacity. Never redrawn.
        case steady(Double)
        /// The whole strip fades between two opacities and back. Thinking.
        case breathe
        /// A bright head travels left to right and wraps. A tool is open;
        /// `width` is how wide the head is, in twenty-fourths of the strip, so
        /// a file write reads as a tighter, busier pass than a shell command.
        case sweep(width: Int)
        /// Someone is waiting. Drawn as a still bar at full colour rather than
        /// as a flash: the card this sits on already carries a red outline and
        /// a glow, and a strobing strip under it sounded the same alarm twice.
        case strobe
        /// One tick per child, lighting in sequence.
        case ticks(count: Int)

        /// Whether this state is one where something is still happening.
        ///
        /// Read by the surfaces that have no strip — the state pill's dot, and
        /// the sidebar's — to decide whether to glow. It is about the session,
        /// not about the strip: `.strobe` says yes here and still does not move.
        var isAnimated: Bool {
            switch self {
            case .steady: false
            case .breathe, .sweep, .strobe, .ticks: true
            }
        }
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
                glyph: "·",
                symbolName: "pause",
                motion: .steady(0.35),
                isAlarming: false
            )
        case .thinking:
            StateStyle(
                color: AuspexPalette.stateThinking,
                label: "Thinking",
                glyph: "◌",
                symbolName: "brain",
                motion: .breathe,
                isAlarming: false
            )
        case .toolCalling:
            StateStyle(
                color: AuspexPalette.stateTool,
                label: "Tool",
                glyph: "›_",
                symbolName: "wrench.adjustable",
                motion: .sweep(width: 7),
                isAlarming: false
            )
        case .writingFile:
            StateStyle(
                color: AuspexPalette.stateWriting,
                label: "Writing",
                glyph: "✎",
                symbolName: "square.and.pencil",
                motion: .sweep(width: 5),
                isAlarming: false
            )
        case .delegating(let children):
            StateStyle(
                color: AuspexPalette.stateDelegating,
                // The state, not its count. "Children 2" reads as a quantity of
                // things rather than as something the session is doing, and the
                // pill's job is the second one; the number rides in the badge
                // beside the word.
                label: "Delegating",
                glyph: "↳",
                symbolName: "arrow.triangle.branch",
                motion: .ticks(count: max(1, min(children, 8))),
                isAlarming: false
            )
        case .waitingPermission:
            StateStyle(
                color: AuspexPalette.statePermission,
                label: "Needs you",
                glyph: "!",
                symbolName: "exclamationmark.triangle.fill",
                motion: .strobe,
                isAlarming: true
            )
        case .ended:
            StateStyle(
                color: AuspexPalette.stateEnded,
                label: "Ended",
                glyph: "■",
                symbolName: "stop.fill",
                motion: .steady(0.35),
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

/// What each state actually means for the person reading it.
///
/// Two of the seven are easy to confuse and expensive to get wrong, and this
/// is the sentence that separates them wherever there is room for one — a
/// tooltip on a pill, an entry in the scene's legend, a row in the README's
/// table.
///
/// *Idle* is a live process with nothing outstanding: the terminal is still
/// there and typing into it works. *Ended* is a process that is gone: nothing
/// will happen in that window again, and only Resume — a new session seeded
/// with the old one's transcript — brings the work back. A person who reads
/// the first as the second abandons work they could have carried on; one who
/// reads the second as the first types into a dead terminal.
enum StateCopy {
    /// The sentence, or `nil` for a state whose own word already says it.
    static func explanation(for state: SessionState) -> String? {
        switch state {
        case .idle:
            "Idle — nothing outstanding, and the process is still there. "
                + "You can keep talking in that terminal."
        case .ended:
            "Ended — the process is gone. Nothing more will happen in that "
                + "terminal; only Resume brings the work back."
        case .waitingPermission:
            "Needs you — it will make no further progress until somebody "
                + "answers."
        case .thinking, .toolCalling, .writingFile, .delegating:
            nil
        }
    }

    /// The tag beside a working session that has gone quiet.
    static let stale =
        "Stale — it says it is working and has said nothing for a while. "
            + "A long build looks exactly like this, and so does a wedged one."
}

/// The state pill: a lit dot and one word.
///
/// Tinted rather than filled — 10 % of the state colour behind it, a 25 %
/// border around it, the word itself at full strength. A filled pill at this
/// size becomes the loudest thing on the card, and the loudest thing on a card
/// should be its title. The dot carries a small glow while the session is
/// actually doing something, which is what lets `Needs you` and `Idle` be
/// told apart across a room even though both are one short word in a box.
///
/// 6 pt corners rather than a capsule: the board is built out of cut edges,
/// and a fully rounded pill next to a 10 pt card reads as a control that could
/// be pressed.
struct StatePill: View {
    let state: SessionState
    var isStale = false
    /// Whether the delegating pill carries its child count.
    ///
    /// On the board it does, because nothing else on the card says how many.
    /// A surface that already draws the count somewhere of its own turns it
    /// off rather than showing the same number twice.
    var showsChildCount = true

    var body: some View {
        let style = state.style
        let isQuiet = !style.motion.isAnimated
        HStack(spacing: 6) {
            StateDot(color: style.color, glows: !isQuiet)
            Text(style.label)
                .font(AuspexType.pill)
                .fixedSize()
            if showsChildCount, let children = state.childCount, children > 1 {
                Text("\(children)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(style.color)
        .opacity(isStale ? 0.7 : 1)
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(style.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(style.color.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .help(StateCopy.explanation(for: state) ?? state.label)
    }
}

/// The 6 pt dot that stands in for a state wherever a pill will not fit: the
/// summary chips, the sidebar's session rows, the trace's Following toggle.
///
/// The glow is not decoration — it is the difference between "this is a colour
/// on a legend" and "this is happening now", and it is the only thing on the
/// board drawn with a shadow.
struct StateDot: View {
    let color: Color
    var glows = false
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glows ? color.opacity(0.65) : .clear, radius: glows ? 4 : 0)
            .accessibilityHidden(true)
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
            .font(AuspexType.pill)
            .foregroundStyle(AuspexPalette.stateStale)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                    AuspexPalette.stateStale.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])
                )
            )
            .accessibilityLabel("Stale: no events recently")
            .help(StateCopy.stale)
    }
}
