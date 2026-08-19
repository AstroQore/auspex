import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// One session, as a tile on the wall.
///
/// ## Reading order
///
/// The card is built so that the three questions a person actually asks get
/// answered at three different distances:
///
/// - **Across the room** — the accent rail says which harness, the pulse line
///   says what it is doing, and a red border says it is blocked. No reading
///   required.
/// - **At a glance** — the state pill, the activity line, and the elapsed
///   stopwatch. Four words and a number.
/// - **On purpose** — the counters and the footer: turns, tool calls, tokens,
///   project, pid, model.
///
/// Everything whose characters matter — paths, ids, numbers — is monospaced,
/// and everything that names rather than says is condensed uppercase. A card
/// is mostly labels, and that pairing is what keeps it dense without becoming
/// a wall of text.
///
/// ## Equatable on purpose
///
/// The board replaces its whole frame up to twenty times a second, so every
/// card's body would otherwise be re-evaluated twenty times a second whether
/// or not that card changed. Conforming to `Equatable` and rendering through
/// `.equatable()` lets SwiftUI skip the ones whose session is byte-identical
/// to the last frame's — which, on a wall where one session is busy and thirty
/// are idle, is nearly all of them. That is why `reduceMotion` is a stored
/// property rather than an `@Environment` read: a value the equality check
/// cannot see is a value that would stop taking effect.
struct SessionCard: View, Equatable {
    let session: SessionSnapshot
    let isSelected: Bool
    let reduceMotion: Bool
    /// How many sessions are below this one in the delegation forest.
    ///
    /// Not the same number as `state.childCount`, which counts only the
    /// children *still running* and only the ones this session's own log
    /// recorded. This is what the board can see: every descendant, including a
    /// `codex exec` the process table linked up and a child that has finished.
    var descendantCount: Int = 0
    /// The session that spawned this one, when the board still holds it.
    var parentTitle: (key: SessionKey, title: String)?
    var onSelectParent: (SessionKey) -> Void = { _ in }

    /// Equality is over the values that are drawn. The closure is not one of
    /// them — it is the same action on every card — and comparing functions is
    /// not a thing Swift will do anyway.
    ///
    /// `nonisolated` because a synthesised `==` on a `@MainActor` view is
    /// itself main-actor isolated, and `.equatable()` calls it from wherever
    /// SwiftUI's diff runs. Nothing it touches is mutable state.
    nonisolated static func == (lhs: SessionCard, rhs: SessionCard) -> Bool {
        lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.descendantCount == rhs.descendantCount
            && lhs.parentTitle?.key == rhs.parentTitle?.key
            && lhs.parentTitle?.title == rhs.parentTitle?.title
    }

    var body: some View {
        let style = session.state.style
        let harnessStyle = session.key.harness.style
        let isOver = session.state.isEnded

        HStack(spacing: 0) {
            // The rail: harness identity, full height, hard edges. It is the
            // only place the accent is a solid fill, which is what makes it
            // readable at the edge of vision.
            Rectangle()
                .fill(isOver ? AuspexPalette.textTertiary.opacity(0.5) : harnessStyle.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 0) {
                header(style: style, isOver: isOver)
                Divider().overlay(AuspexPalette.hairline)
                activity(style: style)
                Spacer(minLength: 6)
                lineage
                footer
                PulseLine(
                    motion: style.motion,
                    color: style.color,
                    isStale: session.isStale
                )
            }
        }
        .frame(minHeight: 158, alignment: .top)
        .panelChrome(
            isSelected: isSelected,
            isHighlighted: style.isAlarming && !reduceMotion,
            highlightColor: style.color
        )
        // Both of these composite the card offscreen, so neither is applied
        // unless it is doing something: `.saturation(1)` and `.opacity(1)` are
        // identities to look at and not to the renderer.
        .opacity(isOver ? 0.62 : 1)
        .modifier(Desaturate(isOn: session.isStale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(harnessStyle.displayName), \(title), \(session.state.label)")
    }

    // MARK: Sections

    /// Title on its own line, pill on the line below it.
    ///
    /// The obvious layout puts the pill beside the title, and it costs a
    /// hundred points of the one line a person actually reads — enough to turn
    /// "Backfill the events table" into "Backfill the events…". The title gets
    /// the full width; the pill sits at the end of the path line, which had
    /// slack to give.
    private func header(style: StateStyle, isOver: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HarnessBadge(harness: session.key.harness, size: 22, isMuted: isOver)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(PathDisplay.abbreviate(session.identity.cwd ?? session.identity.sourcePath))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if session.isStale, !isOver { StaleTag() }
                    StatePill(state: session.state, isStale: session.isStale)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func activity(style: StateStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: style.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.color)
                Text(activityText)
                    .font(AuspexType.mono)
                    .foregroundStyle(
                        session.state.activityDescription == nil
                            ? AuspexPalette.textTertiary
                            : AuspexPalette.textPrimary.opacity(0.85)
                    )
                    .lineLimit(1)
                    .truncationMode(PathDisplay.truncation(for: activityText))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                elapsedClock
                Spacer(minLength: 4)
                counters
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// The elapsed readout.
    ///
    /// `Text(timerInterval:)` updates itself — AppKit drives it — so a wall of
    /// forty stopwatches costs no timers of our own. It is paused at the end
    /// time for a session that is over, which is what makes an ended card show
    /// how long it ran rather than how long ago it stopped.
    private var elapsedClock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(elapsedLabel)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Group {
                if let since = elapsedSince {
                    Text(
                        timerInterval: since...since.addingTimeInterval(60 * 60 * 24),
                        pauseTime: session.endedAt,
                        countsDown: false
                    )
                } else {
                    Text("--:--")
                }
            }
            .font(AuspexType.monoClock)
            .auspexTabularDigits()
            .foregroundStyle(
                session.state.style.isAlarming
                    ? session.state.style.color
                    : AuspexPalette.textPrimary
            )
        }
    }

    private var counters: some View {
        HStack(spacing: 12) {
            counter(value: "\(session.turnCount)", label: "turns")
            counter(value: "\(session.toolCallCount)", label: "tools")
            counter(
                value: "\(TokenFormat.compact(session.tokensIn))/\(TokenFormat.compact(session.tokensOut))",
                label: "tok in/out"
            )
        }
    }

    private func counter(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.textSecondary)
            Text(label)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
        }
    }

    /// Where this card sits in the delegation forest — up, down, or neither.
    ///
    /// Only drawn when there is something to say, which on most walls is a
    /// minority of cards. Up is a *link*: a chip naming the parent, and
    /// clicking it moves the inspector there, because "what asked for this" is
    /// a question whose answer is another card. Down is a *count*: the children
    /// are already on the board, and thirteen chips would be a card nobody can
    /// read.
    @ViewBuilder
    private var lineage: some View {
        if parentTitle != nil || descendantCount > 0 {
            HStack(spacing: 5) {
                if let parent = parentTitle {
                    Button {
                        onSelectParent(parent.key)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.turn.left.up")
                                .font(.system(size: 7, weight: .bold))
                            Text(parent.title)
                                .font(AuspexType.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(AuspexPalette.stateDelegating)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(
                            Capsule().strokeBorder(
                                AuspexPalette.stateDelegating.opacity(0.4), lineWidth: 1
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open the session that spawned this one")
                }
                if descendantCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 7, weight: .bold))
                        Text(descendantCount == 1 ? "1 child" : "\(descendantCount) children")
                            .auspexLabel(AuspexType.labelSmall)
                    }
                    .foregroundStyle(AuspexPalette.stateDelegating.opacity(0.85))
                    .accessibilityLabel("\(descendantCount) sessions below this one")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
        }
    }

    /// Project, pid, model — and nothing else.
    ///
    /// Three fields, because a card is about 280 points wide and a fourth turns
    /// every one of them into `fe…–ui`. A truncated field is worse than an
    /// absent one: it looks like data and cannot be read. The branch and the
    /// child list live in the detail pane, where there is room for them.
    private var footer: some View {
        HStack(spacing: 5) {
            if let project = BoardGrouping.projectName(for: session) {
                Text(project)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let pid = session.identity.pid {
                separator
                // `verbatim` because a pid is an identifier, not a quantity:
                // `Text("pid \(pid)")` would run it through the locale's number
                // formatter and put a thousands separator in the middle of it.
                Text(verbatim: "pid \(pid)").fixedSize()
            }
            if let model = session.identity.model {
                separator
                Text(model)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        .font(AuspexType.monoSmall)
        .foregroundStyle(AuspexPalette.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(AuspexPalette.textTertiary.opacity(0.55))
            .fixedSize()
    }

    // MARK: Content

    /// The card's headline: what the harness called this session, or failing
    /// that the project it is in, or failing that the session id.
    ///
    /// Never invented. A session whose adapter recorded none of the three
    /// shows its own id, which at least identifies it.
    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        if let project = BoardGrouping.projectName(for: session) { return project }
        return String(session.key.sessionID.prefix(12))
    }

    private var activityText: String {
        if let description = session.state.activityDescription {
            if case .writingFile(let path) = session.state, let path {
                return PathDisplay.abbreviate(path)
            }
            if case .toolCalling = session.state,
               let target = session.pending.mostRecentOpenToolCall?.target {
                return "\(description) · \(PathDisplay.condense(target))"
            }
            return description
        }
        switch session.state {
        case .ended(let reason): return "ended · \(reason.rawValue)"
        case .idle: return "nothing outstanding"
        case .thinking: return "reasoning"
        default: return "—"
        }
    }

    private var elapsedLabel: String {
        switch session.state {
        case .ended: "ran for"
        case .waitingPermission: "blocked"
        case .idle: "quiet"
        default: "elapsed"
        }
    }

    /// When the current state began, as precisely as the snapshot allows.
    ///
    /// An open tool call records its own start, which is exact. Everything
    /// else uses the last event, which is exact too — a state change is always
    /// caused by an event — except while a session keeps emitting events that
    /// do not change its state, where it reads as "time since anything
    /// happened". That is the more useful number of the two anyway.
    private var elapsedSince: Date? {
        switch session.state {
        case .toolCalling, .writingFile:
            session.pending.mostRecentOpenToolCall?.startedAt ?? session.lastEventAt
        case .ended:
            session.startedAt ?? session.lastEventAt
        default:
            session.lastEventAt ?? session.startedAt
        }
    }

}

/// Desaturation that exists only while a session is stale.
private struct Desaturate: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.saturation(0.45)
        } else {
            content
        }
    }
}

/// Path shortening, in one place so a path never appears two ways in one
/// window.
enum PathDisplay {
    /// Replaces the user's own home directory with `~`.
    ///
    /// Privacy as much as width: Auspex's whole job is to display paths from
    /// other tools' stores, and a screenshot of the board should not carry the
    /// account name. Resolution goes through `AuspexPaths` for the reason the
    /// house rules give — a stray `HOME` in some agent's environment must not
    /// decide what this shows.
    static func abbreviate(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        let home = AuspexPaths.realHomeDirectory().path
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        let suffix = path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    /// Where to put the ellipsis.
    ///
    /// A path is identified by its tail — `…/Sources/AuspexApp` says more than
    /// `/Users/example/Code/…` — so paths truncate in the middle and keep both
    /// ends. Prose and shell commands read left to right and truncate at the
    /// end, because a sentence with its middle removed is a sentence nobody can
    /// read.
    static func truncation(for text: String) -> Text.TruncationMode {
        looksLikePath(text) ? .middle : .tail
    }

    /// Whether `text` is a filesystem path rather than a command or a sentence.
    static func looksLikePath(_ text: String) -> Bool {
        guard text.contains("/") else { return false }
        return !text.contains(" ")
    }

    /// A tool target cut down to something that fits one line of a card: a
    /// shell command keeps its first clause, a path keeps its last two
    /// components.
    static func condense(_ target: String, limit: Int = 44) -> String {
        let abbreviated = abbreviate(target)
        guard abbreviated.count > limit else { return abbreviated }
        if abbreviated.contains("/"), !abbreviated.contains(" ") {
            let parts = abbreviated.split(separator: "/")
            if parts.count > 2 {
                return "…/" + parts.suffix(2).joined(separator: "/")
            }
        }
        return String(abbreviated.prefix(limit - 1)) + "…"
    }
}
