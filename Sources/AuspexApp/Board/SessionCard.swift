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
/// ## Why it holds a row and not a snapshot
///
/// SwiftUI compares view values to decide what to re-render, so everything a
/// card stores is compared — several hundred times per graph update on a busy
/// machine. A `SessionSnapshot` carries a dictionary of open tool calls, a set
/// of open children, and fifteen optionals of identity, and comparing those was
/// the single most expensive thing the board did: a profile of it was
/// `SessionSnapshot.__derived_struct_equals` most of the way down.
///
/// A ``BoardRow`` is flat — scalars, small enums, and strings the model copied
/// out of the snapshot once per frame — so `.equatable()` decides in a handful
/// of instructions whether this card changed. On a wall where three sessions
/// are busy and forty are not, that skips nearly all of them.
///
/// The two things on the card that move — the strip and the stopwatch — are
/// leaves that read ``BoardClock`` themselves, precisely so they can keep
/// moving without anything above them being re-evaluated. Nothing time-varying
/// is stored here, and nothing here reads the clock.
struct SessionCard: View, Equatable {
    let row: BoardRow
    let isSelected: Bool
    var onSelectParent: (SessionKey) -> Void = { _ in }

    /// Equality is over the values that are drawn. The closure is not one of
    /// them — it is the same action on every card — and comparing functions is
    /// not a thing Swift will do anyway.
    ///
    /// `nonisolated` because a synthesised `==` on a `@MainActor` view is
    /// itself main-actor isolated, and `.equatable()` calls it from wherever
    /// SwiftUI's diff runs. Nothing it touches is mutable state.
    nonisolated static func == (lhs: SessionCard, rhs: SessionCard) -> Bool {
        lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let style = row.state.style
        let accent = row.harness.style.accent
        let isOver = row.isEnded

        VStack(alignment: .leading, spacing: 10) {
            header(style: style, isOver: isOver)
            identityLine
            activityLine(style: style)
            chips
            ActivityStrip(motion: style.motion, color: style.color, isStale: row.isStale)
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
            .fill(isOver ? AuspexPalette.stateEnded : accent)
            .frame(width: 2)
            .padding(1)
        }
        // Composited offscreen, so it is applied only when it is doing
        // something: `.opacity(1)` is an identity to look at and not to the
        // renderer.
        .opacity(isOver ? 0.62 : 1)
        .modifier(Desaturate(isOn: row.isStale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.harness.displayName), \(row.title), \(row.state.label)")
    }

    // MARK: Rows

    /// The mark, the headline, and the state — the only line that has to be
    /// readable from across the room.
    private func header(style: StateStyle, isOver: Bool) -> some View {
        HStack(spacing: 10) {
            HarnessBadge(harness: row.harness, size: 22, isMuted: isOver)
            Text(row.title)
                .font(AuspexType.cardTitle)
                .foregroundStyle(isOver ? AuspexPalette.text3 : AuspexPalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.isStale, !isOver { StaleTag() }
            StatePill(state: row.state, isStale: row.isStale)
                .fixedSize()
        }
    }

    /// Who this session is: the harness's own short id, the process, and the
    /// model. Three facts nobody reads until they need one, at which point
    /// they need it exactly.
    private var identityLine: some View {
        HStack(spacing: 6) {
            Text(row.shortID)
            if let pid = row.pid {
                separator
                // `verbatim` because a pid is an identifier, not a quantity:
                // an interpolated `Int` would go through the locale's number
                // formatter and get a thousands separator in the middle of it.
                Text(verbatim: "pid \(pid)").fixedSize()
            }
            if let model = row.modelName {
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
        let text = PathDisplay.condense(row.activity, limit: 64)
        return HStack(spacing: 8) {
            Text(style.glyph)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(style.color)
                .frame(width: 16)
            Text(text)
                .font(AuspexType.mono)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(PathDisplay.truncation(for: text))
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
            if let project = row.project {
                FactChip(placeLabel(project: project))
            }
            if let directory = row.directory {
                FactChip(PathDisplay.abbreviate(directory), isMono: true)
                    .layoutPriority(-1)
            }
            if let parent = row.parent {
                Button { onSelectParent(parent.key) } label: {
                    FactChip(tint: AuspexPalette.stateDelegating) {
                        Text("↑ \(parent.title)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Open the session that spawned this one")
            } else if row.descendantCount > 0 {
                FactChip(
                    row.descendantCount == 1 ? "↳ 1 child" : "↳ \(row.descendantCount) children",
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
                    since: row.elapsedSince,
                    until: row.endedAt,
                    tint: row.state.style.isAlarming
                        ? row.state.style.color
                        : AuspexPalette.text
                )
            }
            MetaField(key: "turns", value: "\(row.turnCount)")
            MetaField(key: "tools", value: "\(row.toolCallCount)")
            Spacer(minLength: 4)
            Text("\(TokenFormat.compact(row.tokensIn))/\(TokenFormat.compact(row.tokensOut))")
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

    /// The project chip's text: the project, and the branch when one is known.
    private func placeLabel(project: String) -> String {
        guard let branch = row.branch, !branch.isEmpty else { return project }
        return "\(project) · \(branch)"
    }

    private var elapsedLabel: String {
        switch row.state {
        case .ended: "ran for"
        case .waitingPermission: "waiting"
        case .idle: "quiet"
        default: "elapsed"
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
