import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// One piece of work, as a tile on the wall.
///
/// ## What changed, and why it is the whole board
///
/// The card used to be a session. Half the sessions on a busy machine are
/// subagents — a step inside somebody else's job — so a delegation of four
/// drew as four peers and the reader had to reassemble the family every time
/// they looked. This card is the *task*: its title, where it stands, who is
/// holding it, and a strip of dots for the sessions folded inside it. A
/// delegation of four is one card with a `↳ 3`.
///
/// ## Reading order
///
/// The same three distances ``SessionCard`` was built for, asked of a task:
///
/// - **Across the room** — the status ring's colour, the harness rail, and a
///   red outline that breathes when somebody is stuck. No reading.
/// - **At a glance** — the title, the state pill, the member strip. Four words
///   and two glyphs.
/// - **On purpose** — the handle, the chips, the claim and its freshness, the
///   ledger lines, the counters.
///
/// ## Why it holds a unit and not a frame
///
/// The same bargain every other view on this wall makes: ``TaskUnit`` is a
/// flat `Equatable` value the model derived once, so `.equatable()` decides in
/// a handful of instructions whether this card moved. Nothing time-varying is
/// stored — the strip and the stopwatch are leaves that read ``BoardClock``
/// themselves, so they keep moving while nothing above them re-evaluates.
struct TaskCard: View, Equatable {
    let unit: TaskUnit
    let isSelected: Bool
    /// Whether the member list is open. Not derived here: it is a question
    /// about the *wall* — one global switch, one axis, one chevron per card —
    /// and the model owns all three.
    let isExpanded: Bool
    var onToggleExpanded: (() -> Void)?
    var onOpenDetail: (() -> Void)?
    var onSelectMember: ((SessionKey) -> Void)?
    /// Clears the agent's call. `nil` on the surfaces where a card is a
    /// picture rather than a control, which is also what keeps the banner from
    /// growing a dead button in an offscreen render.
    var onDismissNotice: (() -> Void)?

    /// Equality is over what is drawn. The closures are the same actions on
    /// every card and comparing functions is not a thing Swift will do.
    nonisolated static func == (lhs: TaskCard, rhs: TaskCard) -> Bool {
        lhs.unit == rhs.unit && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
    }

    private var attentionColour: Color? { AttentionStyle.colour(unit.attention) }

    var body: some View {
        let lead = unit.lead
        let style = lead.state.style
        let isOver = unit.isEnded

        VStack(alignment: .leading, spacing: 9) {
            titleRow(isOver: isOver)
            identityRow(isOver: isOver)
            TaskChips(unit: unit, isCompact: true)
            AttentionBanner(attention: unit.attention, onDismiss: onDismissNotice)
            if unit.isInReview, let result = unit.result { reviewLine(result) }
            if unit.hasSessions {
                ledgerLines
                if unit.attention.source != .harness, !isOver { activityLine(style: style) }
                memberStrip
                if isExpanded { memberList }
                ActivityStrip(motion: style.motion, color: style.color, isStale: lead.isStale)
            } else if let body = unit.body {
                Text(body)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome(
            isSelected: isSelected,
            isHighlighted: attentionColour != nil,
            breathes: AttentionStyle.breathes(unit.attention),
            highlightColor: attentionColour ?? style.color
        )
        .overlay(alignment: .leading) { rail(isOver: isOver) }
        .opacity(isOver ? 0.62 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(unit.title), \(unit.status.label), \(unit.memberCount) sessions"
        )
    }

    // MARK: Rows

    /// The line that has to be readable from across the room: where the task
    /// stands, what it is called, and what its lead is doing.
    private func titleRow(isOver: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TaskStatusIcon(status: unit.status, isMuted: isOver)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(unit.title)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(isOver ? AuspexPalette.text3 : AuspexPalette.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if unit.importance.isMarked {
                TaskImportanceIcon(importance: unit.importance).padding(.top, 3)
            }
            // The agent's claim replaces the observation rather than sitting
            // beside it: two pills, one saying "idle" and one saying "needs
            // input", would be the card arguing with itself.
            if let notice = unit.lead.notice, unit.attention.source == .agent {
                NoticePill(kind: notice.kind)
            } else if unit.hasSessions {
                StatePill(state: unit.lead.state, isStale: unit.lead.isStale, showsChildCount: false)
                    .fixedSize()
            }
        }
    }

    /// Who is holding this, and how long ago they were heard from.
    ///
    /// The handle is first and monospaced: it is the thing a person types into
    /// the palette and an agent puts in a brief, and it has to be copyable by
    /// eye. Then the claim — harness, role, freshness — which is what tells
    /// two live sessions apart on a board of a dozen.
    private func identityRow(isOver: Bool) -> some View {
        HStack(spacing: 6) {
            Text(unit.shortID)
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize()
            if unit.origin.isImplicit { autoTag }
            if unit.hasSessions {
                HarnessBadge(harness: unit.lead.harness, size: 13, isMuted: isOver)
                Text(unit.lead.harness.displayName)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .fixedSize()
                if let role = unit.claim?.role {
                    separator
                    Text(role)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text2)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                separator
                FreshnessLabel(at: unit.claim?.freshAt ?? unit.lastEventAt)
            } else {
                // Nobody has started. The one true thing to say is when it was
                // filed; a harness mark here would be naming an agent that has
                // never touched it.
                Text("unclaimed")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
                separator
                Text("filed")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize()
                FreshnessLabel(at: unit.createdAt)
            }
            Spacer(minLength: 0)
        }
    }

    /// The mark that says this card is a derivation rather than a record.
    ///
    /// Faint, and one word. An implicit unit is the ordinary case on a machine
    /// where nobody has adopted the task protocol, and it must not read as a
    /// warning — but a person about to close it should know that there is no
    /// task behind it to close.
    private var autoTag: some View {
        Text("auto")
            .font(AuspexType.labelSmall)
            .foregroundStyle(AuspexPalette.text3)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
            .fixedSize()
            .help("Auspex worked this out from a delegation. Nobody filed a task for it.")
    }

    /// The line the worker wrote when it finished — what a reviewer reads
    /// instead of opening the transcript.
    private func reviewLine(_ result: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("✓")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AuspexPalette.stateWriting)
            Text(result)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AuspexPalette.stateWriting.opacity(0.07))
        )
    }

    /// What was asked last and what came back — the lead's, because the lead
    /// is the session a person is talking to.
    @ViewBuilder
    private var ledgerLines: some View {
        let lead = unit.lead
        if lead.latestPrompt != nil || lead.latestAssistant != nil || lead.reportedFocus != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let asked = lead.latestPrompt {
                    TaskLedgerLine(key: "asked", text: asked, tint: AuspexPalette.text2)
                }
                if let focus = lead.reportedFocus {
                    TaskLedgerLine(
                        key: "doing",
                        text: "\(NoticeStyle.selfReportedMark) \(focus)",
                        tint: AuspexPalette.text2
                    )
                } else if let said = lead.latestAssistant, !unit.isInReview {
                    TaskLedgerLine(key: "said", text: said, tint: AuspexPalette.text3)
                }
            }
        }
    }

    private func activityLine(style: StateStyle) -> some View {
        let text = PathDisplay.condense(unit.lead.activity, limit: 60)
        return HStack(spacing: 8) {
            Text(style.glyph)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(style.color)
                .frame(width: 14)
            Text(text)
                .font(AuspexType.mono)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .truncationMode(PathDisplay.truncation(for: text))
            Spacer(minLength: 0)
        }
    }

    // MARK: Members

    /// The sessions inside this task, as one dot each.
    ///
    /// This is the fold. A subagent is a step inside somebody else's job, and
    /// what a person scanning a wall needs from it is *how many, and are any of
    /// them stuck* — which is exactly what a row of state-coloured dots says,
    /// in the width of a chip rather than of a card. The chevron opens the
    /// list for the one card somebody is actually reading.
    @ViewBuilder
    private var memberStrip: some View {
        if unit.memberCount > 1 {
            Button { onToggleExpanded?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AuspexPalette.text3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("↳ \(unit.subagents.count)")
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.stateDelegating)
                        .fixedSize()
                    HStack(spacing: 3) {
                        ForEach(Array(unit.members.prefix(Self.stripLimit)), id: \.key) { member in
                            StateDot(
                                color: dotColour(member),
                                glows: member.needsPerson,
                                size: 7
                            )
                        }
                        if unit.memberCount > Self.stripLimit {
                            Text("+\(unit.memberCount - Self.stripLimit)")
                                .font(AuspexType.labelSmall)
                                .foregroundStyle(AuspexPalette.text3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.auspex(cornerRadius: 6))
            .help(
                isExpanded
                    ? "Fold the sessions back into the card"
                    : "\(unit.memberCount) sessions are working on this — open the list"
            )
        }
    }

    /// How many dots fit before the strip stops being scannable. Ten is about
    /// the number a person can count at a glance; past that the `+N` says more
    /// than another dot would.
    private static let stripLimit = 10

    private func dotColour(_ row: BoardRow) -> Color {
        if row.needsPerson { return AuspexPalette.statePermission }
        if row.isDoneReported { return AuspexPalette.stateWriting }
        if row.isEnded { return AuspexPalette.stateEnded }
        return row.state.style.color
    }

    /// The sessions, listed. What the old wall showed all the time and this
    /// one shows when asked.
    private var memberList: some View {
        VStack(spacing: 0) {
            ForEach(unit.members, id: \.key) { member in
                TaskMemberRow(
                    row: member,
                    isLead: member.key == unit.lead.key,
                    onSelect: { onSelectMember?(member.key) }
                )
                .equatable()
            }
        }
        .padding(.leading, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AuspexPalette.stateDelegating.opacity(0.35))
                .frame(width: 1)
        }
    }

    // MARK: Chrome

    private func rail(isOver: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 9,
            bottomLeadingRadius: 9,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(isOver ? AuspexPalette.stateEnded : unit.lead.harness.style.accent)
        .frame(width: 2)
        .padding(1)
    }

    /// The counters, and how full the lead's context window is.
    ///
    /// The counters are summed over the family: the tokens a delegation spent
    /// are the tokens all of it spent, and a card reporting only its
    /// orchestrator's would under-report the thing it exists to make visible.
    ///
    /// The gauge is **not** summed, and could not be. A context window is a
    /// property of one conversation — the lead's, which is the session a person
    /// is talking to and the one that will hit a compaction. Adding four
    /// sessions' fills together would produce a number that is not about
    /// anything; averaging them would hide the one that is nearly full. A
    /// member close to its limit is a fact for that member's own row, which the
    /// expanded card and the trace pane both draw.
    ///
    /// Its own line rather than a sixth thing on the counters row, for
    /// ``SessionCard``'s reason: a card is 300 points wide at its narrowest and
    /// a gauge squeezed in beside four numbers is a bar too short to read a
    /// fill off.
    @ViewBuilder
    private var footer: some View {
        if unit.hasSessions {
            VStack(alignment: .leading, spacing: 7) {
                counters
                if let context = unit.lead.context {
                    ContextGaugeView(gauge: context).equatable()
                }
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text(elapsedLabel)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                ElapsedLabel(
                    since: unit.elapsedSince,
                    until: unit.endedAt,
                    tint: unit.lead.state.style.isAlarming
                        ? unit.lead.state.style.color
                        : AuspexPalette.text
                )
            }
            if unit.counts.total > 1 {
                MetaField(key: "live", value: "\(unit.counts.live)/\(unit.counts.total)")
            }
            Spacer(minLength: 4)
            Text("\(TokenFormat.compact(unit.tokensIn))/\(TokenFormat.compact(unit.tokensOut))")
                .font(AuspexType.monoSmall)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize()
                .help("Tokens in / out, across every session on this task")
        }
    }

    private var elapsedLabel: String {
        switch unit.status {
        case .done: "ran for"
        case .blocked: "waiting"
        case .review: "finished"
        case .todo, .doing: "elapsed"
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .font(AuspexType.caption)
            .foregroundStyle(AuspexPalette.text3.opacity(0.6))
            .fixedSize()
    }
}

/// One session inside an opened task card.
///
/// Slimmer than a ``SessionCard`` on purpose: everything a card says about the
/// *work* is on the card above, and what is left is what tells one member from
/// another — whose harness it is, what it is called, and what it is doing right
/// now.
struct TaskMemberRow: View, Equatable {
    let row: BoardRow
    let isLead: Bool
    var onSelect: () -> Void = {}

    nonisolated static func == (lhs: TaskMemberRow, rhs: TaskMemberRow) -> Bool {
        lhs.row == rhs.row && lhs.isLead == rhs.isLead
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                HarnessBadge(harness: row.harness, size: 14, isMuted: row.isEnded)
                if isLead {
                    Text("lead")
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize()
                }
                Text(row.title)
                    .font(AuspexType.caption)
                    .foregroundStyle(row.isEnded ? AuspexPalette.text3 : AuspexPalette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if row.needsPerson || row.isDoneReported {
                    AttentionBadge(attention: row.attention, size: 12)
                }
                Text(PathDisplay.condense(row.activity, limit: 26))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(row.state.style.color.opacity(row.isEnded ? 0.5 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 5))
        .help("Open this session's transcript")
    }
}

/// *2 m ago*, against the board's shared clock.
///
/// Freshness with no heartbeat behind it: a session Auspex is tailing
/// announces itself by writing its transcript, and asking agents to ping as
/// well would be asking them to repeat what the machine already knows.
struct FreshnessLabel: View {
    let at: Date?
    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        Text(RelativeTimeText.since(at, now: clock?.now ?? Date()))
            .font(AuspexType.caption)
            .auspexTabularDigits()
            .foregroundStyle(AuspexPalette.text3)
            .fixedSize()
    }
}

/// One line of a card's ledger: a short key, then what was said.
struct TaskLedgerLine: View {
    let key: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3.opacity(0.75))
                .frame(width: 30, alignment: .leading)
            Text(text)
                .font(AuspexType.caption)
                .foregroundStyle(tint)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
