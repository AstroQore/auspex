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
/// - **Across the room** — the accent rail says which harness, the strip says
///   what it is doing, and a red outline with a glow says it is blocked. No
///   reading required.
/// - **At a glance** — the title, the state pill, and the activity line. Four
///   words and a mark.
/// - **On purpose** — the identity line, the chips, and the footer: id, pid,
///   model, where it is working, elapsed, turns, tools, tokens.
///
/// Everything whose characters matter — ids, paths, numbers — is monospaced.
/// A card is mostly data, and that is what keeps it dense without becoming a
/// wall of text.
///
/// ## Equatable on purpose
///
/// The board replaces its whole frame several times a second, so every card's
/// body would otherwise be re-evaluated several times a second whether or not
/// that card changed. Conforming to `Equatable` and rendering through
/// `.equatable()` lets SwiftUI skip the ones whose session is byte-identical
/// to the last frame's — which, on a wall where three sessions are busy and
/// forty are not, is nearly all of them.
///
/// The two things on the card that move — the strip and the stopwatch — are
/// leaves that read ``BoardClock`` themselves, precisely so that they can keep
/// moving without anything above them being re-evaluated. Nothing time-varying
/// is a stored property here, and nothing here reads the clock.
struct SessionCard: View, Equatable {
    let session: SessionSnapshot
    let isSelected: Bool
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
            && lhs.descendantCount == rhs.descendantCount
            && lhs.parentTitle?.key == rhs.parentTitle?.key
            && lhs.parentTitle?.title == rhs.parentTitle?.title
    }

    var body: some View {
        let style = session.state.style
        let harnessStyle = session.key.harness.style
        let isOver = session.state.isEnded

        VStack(alignment: .leading, spacing: 10) {
            header(style: style, isOver: isOver)
            identityLine
            activityLine(style: style)
            chips
            ActivityStrip(motion: style.motion, color: style.color, isStale: session.isStale)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome(
            isSelected: isSelected,
            isHighlighted: style.isAlarming,
            highlightColor: style.color
        )
        .overlay(alignment: .leading) {
            // The rail: harness identity, full height, and the only place the
            // accent is a solid fill — which is what makes it readable at the
            // edge of vision. Inset by the border's own pixel so it reads as
            // part of the card rather than as something stuck to it.
            UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(isOver ? AuspexPalette.stateEnded : harnessStyle.accent)
            .frame(width: 2)
            .padding(1)
        }
        // Composited offscreen, so it is applied only when it is doing
        // something: `.opacity(1)` is an identity to look at and not to the
        // renderer.
        .opacity(isOver ? 0.62 : 1)
        .modifier(Desaturate(isOn: session.isStale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(harnessStyle.displayName), \(title), \(session.state.label)")
    }

    // MARK: Rows

    /// The mark, the headline, and the state — the only line that has to be
    /// readable from across the room.
    private func header(style: StateStyle, isOver: Bool) -> some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: session.key.harness, size: 22, isMuted: isOver)
            Text(title)
                .font(AuspexType.cardTitle)
                .foregroundStyle(isOver ? AuspexPalette.text3 : AuspexPalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.isStale, !isOver { StaleTag() }
            StatePill(state: session.state, isStale: session.isStale)
                .fixedSize()
        }
    }

    /// Who this session is: the harness's own short id, the process, and the
    /// model. Three facts nobody reads until they need one, at which point
    /// they need it exactly.
    private var identityLine: some View {
        HStack(spacing: 6) {
            Text(shortID)
            if let pid = session.identity.pid {
                separator
                // `verbatim` because a pid is an identifier, not a quantity:
                // an interpolated `Int` would go through the locale's number
                // formatter and get a thousands separator in the middle of it.
                Text(verbatim: "pid \(pid)").fixedSize()
            }
            if let model = session.identity.model {
                separator
                Text(model).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        .font(AuspexType.monoSmall)
        .foregroundStyle(AuspexPalette.text3)
    }

    /// What is happening, in the harness's own words, behind the state's mark.
    private func activityLine(style: StateStyle) -> some View {
        HStack(spacing: 8) {
            Text(style.glyph)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(style.color)
                .frame(width: 16)
            Text(activityText)
                .font(AuspexType.mono)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(PathDisplay.truncation(for: activityText))
            Spacer(minLength: 0)
        }
    }

    /// Where the work is happening, and what it is connected to.
    ///
    /// Up is a *link*: a chip naming the parent, and clicking it moves the
    /// inspector there, because "what asked for this" is a question whose
    /// answer is another card. Down is a *count*: the children are already on
    /// the board, and thirteen chips would be a card nobody can read.
    private var chips: some View {
        HStack(spacing: 6) {
            if let project = BoardGrouping.projectName(for: session) {
                FactChip(placeLabel(project: project))
            }
            if let cwd = session.identity.cwd ?? session.identity.gitRoot {
                FactChip(PathDisplay.abbreviate(cwd), isMono: true)
                    .layoutPriority(-1)
            }
            if let parent = parentTitle {
                Button { onSelectParent(parent.key) } label: {
                    FactChip(tint: AuspexPalette.stateDelegating) {
                        Text("↑ \(parent.title)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the session that spawned this one")
                .layoutPriority(-2)
            } else if descendantCount > 0 {
                FactChip(
                    descendantCount == 1 ? "↳ 1 child" : "↳ \(descendantCount) children",
                    tint: AuspexPalette.stateDelegating
                )
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// The counters, in the order they are asked for.
    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Text(elapsedLabel)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                ElapsedLabel(
                    since: elapsedSince,
                    until: session.endedAt,
                    tint: session.state.style.isAlarming
                        ? session.state.style.color
                        : AuspexPalette.text
                )
            }
            MetaField(key: "turns", value: "\(session.turnCount)")
            MetaField(key: "tools", value: "\(session.toolCallCount)")
            Spacer(minLength: 4)
            Text(
                "\(TokenFormat.compact(session.tokensIn))/\(TokenFormat.compact(session.tokensOut))"
            )
            .font(AuspexType.monoSmall)
            .auspexTabularDigits()
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize()
            .help("Tokens in / out")
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(AuspexPalette.text3.opacity(0.6))
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
        return shortID
    }

    /// The first eight characters of the session id — enough to recognise one
    /// in a terminal, short enough to sit beside a pid.
    private var shortID: String {
        String(session.key.sessionID.prefix(8))
    }

    /// The project chip's text: the project, and the branch when one is known.
    private func placeLabel(project: String) -> String {
        guard let branch = session.identity.gitBranch, !branch.isEmpty else { return project }
        return "\(project) · \(branch)"
    }

    private var activityText: String {
        if let description = session.state.activityDescription {
            if case .writingFile(let path) = session.state, let path {
                return PathDisplay.abbreviate(path)
            }
            if case .toolCalling = session.state,
               let target = session.pending.mostRecentOpenToolCall?.target {
                return "\(description)  \(PathDisplay.condense(target))"
            }
            return description
        }
        switch session.state {
        case .ended(let reason): return "exited · \(reason.rawValue)"
        case .idle: return "quiet"
        case .thinking: return "reasoning"
        default: return "—"
        }
    }

    private var elapsedLabel: String {
        switch session.state {
        case .ended: "ran for"
        case .waitingPermission: "waiting"
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
