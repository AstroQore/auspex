import AgentSessionLive
import AuspexCore
import SwiftUI

/// The bar across the top of the board.
///
/// It answers, left to right, the three questions in the order a person asks
/// them: *what am I looking at* (the heading and its count), *does anything
/// need me* (the four summary chips), and *how do I want to look at it* (the
/// mode picker, the grouping menu, the search field).
///
/// It is a view of the app's own making rather than a window toolbar. A
/// toolbar would put the state chips in AppKit's chrome, where they cannot
/// carry the board's colours, cannot be laid out to a 52 pt rhythm, and would
/// be the one row in the window drawn by somebody else.
struct BoardHeader: View {
    @Bindable var model: LiveBoardModel
    let section: BoardSection

    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(AppEnvironment.self) private var environment

    /// How tall the bar is, published so that anything hung over the board's
    /// column can start below it rather than guessing. The search panel used to
    /// guess, and landed on the heading.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            if section == .live, model.viewMode == .now {
                nowBar
            } else {
                boardBar
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .background(AuspexPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
        // One measurement, read by one rule — see ``fit``. A `GeometryReader`
        // in the background proposes nothing to the bar and lays nothing out;
        // it reports the width the bar was given.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
        )
    }

    /// Now's bar: the heading and its live line, the three counts that are
    /// about the person, the stage switch, the mode menu, and search.
    @ViewBuilder
    private var nowBar: some View {
        let fit = nowFit
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(NowCopy.title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.22)
                .foregroundStyle(AuspexPalette.text)
            if fit.showsStatus {
                NowStatusLine(live: model.nowCounts.live, working: model.nowCounts.working)
            }
        }
        .fixedSize()
        Spacer(minLength: 8)
        if fit.pills > 0 {
            NowCountPills(counts: model.nowCounts, limit: fit.pills).fixedSize()
        }
        NowStageSwitch(showsStage: $model.showsStage).fixedSize()
        ViewModeMenu(model: model, section: section).fixedSize()
        searchField
    }

    /// What of Now's bar fits, most important last to go: the search field,
    /// the switch and the mode menu never give way; the live line goes first,
    /// then the pills from the quietest end.
    ///
    /// Arithmetic over resting widths rather than `ViewThatFits`, for the
    /// reason ``fit`` gives.
    private var nowFit: (showsStatus: Bool, pills: Int) {
        guard width > 0 else { return (true, 3) }
        var reserved: CGFloat = 40  // the bar's own padding
        reserved += 60  // the heading
        reserved += 12 * 4  // the gaps between the controls
        reserved += 172  // the stage switch
        reserved += 84  // the mode menu
        reserved += 120  // the search field at its narrowest
        var free = width - reserved
        // Resting widths of the three pills, most urgent first, and the gap
        // before each.
        let pills: [CGFloat] = [72, 96, 84]
        let status: CGFloat = 200
        var shown = 0
        for pill in pills where free >= pill + 6 {
            free -= pill + 6
            shown += 1
        }
        return (shown == pills.count && free >= status, shown)
    }

    /// Every other mode's bar, as it was before Now: the counts, catch-up and
    /// review, then the controls that cut the wall.
    @ViewBuilder
    private var boardBar: some View {
            heading
            if section == .live || section == .allSessions {
                // The chips are the first thing to give way. Every control to
                // their right is a thing a person operates, and a picker
                // squeezed to forty points is a picker nobody can hit; a chip
                // that is not on screen is a number they can still read off
                // the sidebar and the cards.
                counts(limit: fit.chips, showsMarkAll: fit.showsMarkAll)
                if showsCatchUpInHeader {
                    catchUpButton.fixedSize()
                }
                if showsReviewInHeader { reviewNext.fixedSize() }
                Spacer(minLength: 8)
                if model.ignoredCount > 0 {
                    ignoredToggle.fixedSize()
                }
                ViewModeMenu(model: model, section: section).fixedSize()
                TaskFilterMenu(model: model).fixedSize()
                groupMenu.fixedSize()
                windowMenu.fixedSize()
                searchField
            } else {
                if let subtitle {
                    Text(subtitle)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
            }
    }

    /// The bar's own width, measured once and re-measured when it changes.
    @State private var width: CGFloat = 0

    /// How many chips fit, and whether the clear-everything button fits beside
    /// them.
    ///
    /// ## Why this is arithmetic and not `ViewThatFits`
    ///
    /// `ViewThatFits` picks between its children by *laying each of them out*
    /// until one fits. Six candidates over five chips meant the header
    /// measured up to thirty chips on every pass, and a `sample` of the window
    /// at `--demo-scale 12` had `TextChildQuery → ResolvedTextFilter` under it
    /// as one of the two largest things on the main thread — for a bar whose
    /// contents change when a number does.
    ///
    /// The widths below are the resting widths of controls this file draws, so
    /// they are as true as a measurement and cost nothing. Being a few points
    /// out costs one chip at one window width, which is the same thing the
    /// ladder did.
    private var fit: (chips: Int?, showsMarkAll: Bool) {
        guard width > 0 else { return (nil, true) }
        // Everything to the right of the chips, none of which may be squeezed.
        var reserved: CGFloat = 40  // the bar's own padding
        reserved += 150  // the heading and its count
        reserved += 12 * 5  // the gaps between the controls
        reserved += 92  // the mode menu
        reserved += 46  // the filter menu
        reserved += 108  // the grouping menu
        reserved += 92  // the window menu
        reserved += 150  // the search field
        if model.ignoredCount > 0 { reserved += 96 }
        if showsCatchUpInHeader { reserved += 82 }
        if showsReviewInHeader { reserved += 78 }
        let free = width - reserved
        guard free > 0 else { return (0, false) }
        // A chip is a mark, two or three digits, and a word: 86 points covers
        // "in review", which is the widest of the four.
        let fits = Int(free / 86)
        let wanted = model.summary.chips.count
        if fits >= wanted, free - CGFloat(wanted) * 86 >= 60 { return (nil, true) }
        return (min(fits, wanted), false)
    }

    private var catchUpCount: Int {
        model.catchUp.items.count + model.watchSignals.count
    }

    /// Catch-up is the primary entry back into a busy board and stays visible
    /// at the default window width. Review Next is its focused shortcut and
    /// joins it only when the centre column is wide enough for both.
    private var showsCatchUpInHeader: Bool {
        catchUpCount > 0
    }

    private var showsReviewInHeader: Bool {
        model.reviewCount > 0 && (width == 0 || width >= 1_000)
    }

    private var catchUpButton: some View {
        Button { model.isCatchUpOpen = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("Catch up \(catchUpCount)")
                    .font(AuspexType.caption)
                    .auspexTabularDigits()
            }
            .foregroundStyle(AuspexPalette.text2)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AuspexPalette.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AuspexPalette.stateStale.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.auspex(cornerRadius: 8))
        .help("Review material changes, human work, and amber watch signals")
    }

    // MARK: Pieces

    /// The chips, and the clear-everything button beside them.
    ///
    /// One group rather than two, so the width can be spent on a chip before
    /// the button. A number a person came to read outranks a control they can
    /// also reach from the View menu (⇧⌘K).
    private func counts(limit: Int?, showsMarkAll: Bool) -> some View {
        HStack(spacing: 8) {
            SummaryChips(
                summary: model.summary,
                limit: limit,
                selected: model.bucketFilter,
                onSelect: { model.toggleBucketFilter($0) }
            )
            if showsMarkAll, model.hasAttention {
                markAllSeen.fixedSize()
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // On the live section the heading names the way it is being
            // looked at: the sidebar's row is called Now, and a wall of cards
            // under the word "Now" would be the header contradicting the
            // menu beside it.
            Text(section == .live ? model.viewMode.title : section.title)
                .font(AuspexType.windowTitle)
                .foregroundStyle(AuspexPalette.text)
            if let headingCount {
                Text("\(headingCount)")
                    .font(AuspexType.monoCount)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .fixedSize()
    }

    /// Opens the review queue from whichever whole-board view is on screen.
    /// The count is already one of the summary facts; this is the action beside
    /// it, and it changes no task until the person chooses Close or Reopen.
    private var reviewNext: some View {
        Button { model.openNextReview() } label: {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                Text("Review \(model.reviewCount)")
                    .font(AuspexType.caption)
                    .auspexTabularDigits()
            }
            .foregroundStyle(AuspexPalette.stateWriting)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AuspexPalette.stateWriting.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AuspexPalette.stateWriting.opacity(0.24), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 8))
        .help("Review next — open the first task waiting for your judgement")
    }

    /// The number beside the heading, when the heading is about a number of
    /// sessions. A status page is not, and a count there would be counting
    /// something the page below it does not show.
    private var headingCount: Int? {
        switch section {
        case .live: model.summary.live
        case .allSessions: model.sessionCount
        default: nil
        }
    }

    /// The line beside a status page's heading.
    ///
    /// Settings has none. It has six panes, each about a different thing, and
    /// one line up here can only ever describe one of them — which is exactly
    /// what happened: every pane was introduced as "characters, and where
    /// packages come from" for as long as there were six of them. The line each
    /// pane deserves is now that pane's own, in its title row. See
    /// ``SettingsPane/subtitle``.
    private var subtitle: String? {
        switch section {
        case .harnesses:
            "\(AuspexAdapters.featured.count) harnesses · what Auspex can see on this Mac, and how"
        default:
            nil
        }
    }

    /// Clears every signal on the board at once.
    ///
    /// On screen only while something is actually signalling, which is the
    /// same rule the chips follow and for the same reason: a control that is
    /// always there and usually does nothing is a control people stop seeing.
    ///
    /// It is the escape hatch the whole attention model needs to be safe. Every
    /// other clearing rule is automatic — you opened the card, you answered in
    /// the terminal, a day went by — and a person who has just dealt with six
    /// agents somewhere else needs one gesture that says so, or they will learn
    /// to ignore the red instead.
    private var markAllSeen: some View {
        Button { model.markAllSeen() } label: {
            // The mark and the number, and no words. The chips beside it are
            // what a person came to the header to read, and a button spelling
            // itself out in full is 110 points of the width they need — the
            // same bargain the ignored toggle makes one place along.
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.attention.count)")
                    .font(AuspexType.caption)
                    .auspexTabularDigits()
            }
            .foregroundStyle(AuspexPalette.text3)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AuspexPalette.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 8))
        .accessibilityLabel("Mark all as seen")
        .help(
            "Mark all as seen — clear every card that is asking or reporting. "
                + "A session that is still blocked will say so again."
        )
    }

    /// What the rules are hiding, and the switch that reveals it.
    ///
    /// Only on screen when a rule is actually catching something, because a
    /// control that always says "0 ignored" is a control that teaches a person
    /// to stop reading that corner of the header. The count is of *sessions*,
    /// not rules: what a person wants to know before trusting a quiet board is
    /// how much of it is not being shown.
    private var ignoredToggle: some View {
        Button {
            environment.catalog.setShowsIgnored(!model.showsIgnored)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.showsIgnored ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(model.ignoredCount) ignored")
                    .font(AuspexType.caption)
                    .auspexTabularDigits()
            }
            .foregroundStyle(
                model.showsIgnored ? AuspexPalette.text : AuspexPalette.text3
            )
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.showsIgnored ? AuspexPalette.selection : AuspexPalette.bg1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 8))
        .help(
            model.showsIgnored
                ? "Hide the ignored sessions again. " + IgnoreCopy.stillRecorded
                : "Show the \(model.ignoredCount) sessions your rules hide, dimmed. "
                    + IgnoreCopy.stillRecorded
        )
    }

    /// The grouping axis, as a menu rather than a segmented control: there are
    /// four axes and only one is in use at a time, and four segments would take
    /// the width the search field needs.
    private var groupMenu: some View {
        Menu {
            Picker("Group by", selection: $model.groupBy) {
                ForEach(BoardGroupBy.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .auspexSystemControlFocus()
            Divider()
            // The wall's one density switch. A card folds its subagents into a
            // strip of dots, which is what makes twelve pieces of work
            // readable rather than forty processes; this is for the person who
            // wants the old density back on every card at once. A single card
            // still opens on its own chevron either way.
            Button {
                environment.catalog.setShowsSubagents(!model.showsSubagents)
            } label: {
                if model.showsSubagents {
                    Label("Show subagents", systemImage: "checkmark")
                } else {
                    Text("Show subagents")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("By").foregroundStyle(AuspexPalette.text3)
                Text(model.groupBy.title).foregroundStyle(AuspexPalette.text2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            .font(AuspexType.body)
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.auspex(cornerRadius: 8))
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(fieldBackground)
        .help(
            "Divide the board into sections, and choose whether every card "
                + "lists the sessions inside it"
        )
    }

    /// How far back the board reaches, beside the axis it is divided along.
    ///
    /// Next to "By Project" because the two questions are the same shape —
    /// *how is this board cut* — and because the header is where somebody
    /// notices that an afternoon's sessions are missing.
    private var windowMenu: some View {
        SessionWindowMenu(
            window: model.sessionWindow,
            hint: model.olderHiddenHint,
            onSelect: { environment.catalog.setSessionWindow($0) }
        )
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(fieldBackground)
        .help(
            model.olderHiddenHint.map { "\($0). Widen to see them." }
                ?? "How far back the board and the map reach. "
                    + "Older sessions stay in the store."
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AuspexPalette.text3)
            // `ImageRenderer` cannot draw an `NSTextField`, and a screenshot
            // with a system placeholder box where the search field should be
            // says nothing true about the app. The offscreen render gets the
            // field's resting state, which is what it looks like anyway.
            if isSnapshotRender {
                Text(model.searchQuery.isEmpty ? searchPlaceholder : model.searchQuery)
                    .font(AuspexType.body)
                    .foregroundStyle(
                        model.searchQuery.isEmpty ? AuspexPalette.text3 : AuspexPalette.text
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField(searchPlaceholder, text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text)
                    .auspexSystemControlFocus()
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, idealWidth: 150, maxWidth: 150)
        .frame(height: 28)
        .background(fieldBackground)
        .help("Search every transcript")
    }

    private var searchPlaceholder: String {
        section == .live && model.viewMode == .now ? NowCopy.search : "Search sessions"
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AuspexPalette.bg1)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
    }
}

/// The numbers, each with its bucket's mark, and each a filter.
///
/// Zeroes are dropped and `ended` never appears at all, which is
/// ``BoardSummary/chips``' rule and not this view's: a red chip that is always
/// on screen is a red chip nobody looks at.
///
/// Clicking one shows only that bucket, and clicking it again shows everything.
/// A count a person cannot act on sends them hunting through the wall for the
/// three cards it was about; a count that filters answers the question it
/// raised. The selected chip is drawn lit rather than merely outlined, because
/// a filtered board looks like a quiet one and the reason has to be visible
/// from the same glance.
struct SummaryChips: View {
    let summary: BoardSummary
    /// How many chips to draw, most urgent first. `nil` draws every chip that
    /// has something to say.
    var limit: Int?
    /// The bucket the board is filtered to, if any.
    var selected: TaskLedger.Bucket?
    var onSelect: (TaskLedger.Bucket) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(shown, id: \.kind) { chip in
                let isOn = selected == chip.kind
                Button { onSelect(chip.kind) } label: {
                    HStack(spacing: 5) {
                        if let mark = Self.mark(for: chip.kind) {
                            Text(mark)
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Self.color(for: chip.kind))
                                .frame(width: 8)
                        } else {
                            StateDot(color: Self.color(for: chip.kind), glows: isOn)
                        }
                        Text("\(chip.value)")
                            .font(.system(size: 11.5, weight: .bold))
                            .auspexTabularDigits()
                            .foregroundStyle(
                                chip.kind == .idle && !isOn
                                    ? AuspexPalette.text3
                                    : AuspexPalette.text
                            )
                        Text(chip.kind.label)
                            .font(AuspexType.caption)
                            .foregroundStyle(isOn ? AuspexPalette.text2 : AuspexPalette.text3)
                    }
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isOn ? AuspexPalette.selection : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.auspex(cornerRadius: 6))
                .help(
                    isOn
                        ? "Show every session again"
                        : "Show only the \(chip.kind.label) sessions"
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(chip.value) \(chip.kind.label)")
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var shown: [(kind: BoardSummary.Kind, value: Int)] {
        guard let limit else { return summary.chips }
        return Array(summary.chips.prefix(limit))
    }

    /// One colour per kind, from the state palette — so the chip that says
    /// "needs you" is the same red as the ring on the card it is counting.
    static func color(for kind: BoardSummary.Kind) -> Color {
        switch kind {
        case .needsYou: AuspexPalette.statePermission
        case .doneReported: AuspexPalette.stateWriting
        case .working: AuspexPalette.stateTool
        case .idle: AuspexPalette.stateIdle
        case .ended: AuspexPalette.stateEnded
        }
    }

    /// The mark in front of the number, for the two chips that are about
    /// something explicit.
    ///
    /// `! 2 needs you` and `✓ 1 done` read as claims; `3 working` and `9 idle`
    /// read as tallies, which is what they are. The mark is the same character
    /// the scene puts over an agent's head and the crew wall puts in a corner,
    /// so it is learned once.
    static func mark(for kind: BoardSummary.Kind) -> String? {
        switch kind {
        case .needsYou: "!"
        case .doneReported: "✓"
        case .working: "▶"
        case .idle, .ended: nil
        }
    }
}

// MARK: - Now's pieces

/// `17:31 · 14 live · 7 working`. A leaf, so the clock's tick re-evaluates
/// this line and nothing else in the bar.
private struct NowStatusLine: View {
    let live: Int
    let working: Int

    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        Text(NowCopy.status(
            time: (clock?.now ?? Date()).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)),
            live: live,
            working: working
        ))
        .font(.system(size: 12, design: .monospaced))
        .auspexTabularDigits()
        .foregroundStyle(AuspexPalette.text3)
        .lineLimit(1)
    }
}

/// The three counts that are about the person, each on a wash of its own
/// colour. Most urgent first, so a narrow bar drops the receipts before the
/// questions.
private struct NowCountPills: View {
    let counts: NowFrame.Counts
    var limit = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(pills.prefix(limit)), id: \.label) { pill in
                Text("\(pill.label) \(pill.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .auspexTabularDigits()
                    .foregroundStyle(NowTone.ink(pill.tone))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(NowTone.wash(pill.tone)))
                    .opacity(pill.count == 0 ? 0.55 : 1)
                    .accessibilityLabel("\(pill.count) \(pill.label)")
            }
        }
    }

    private var pills: [(tone: NowFrame.Tone, label: String, count: Int)] {
        [
            (.needsYou, NowCopy.needsYou, counts.needsYou),
            (.mayNeedYou, NowCopy.mayNeedYou, counts.mayNeedYou),
            (.done, NowCopy.doneUnseen, counts.done)
        ]
    }
}

/// Office and lists, or the lists alone.
private struct NowStageSwitch: View {
    @Binding var showsStage: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment(NowCopy.stageAndLists, isOn: showsStage) { showsStage = true }
            segment(NowCopy.listsOnly, isOn: !showsStage) { showsStage = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AuspexPalette.line, lineWidth: 1)
        )
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? AuspexPalette.bg0 : AuspexPalette.text)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(isOn ? AuspexPalette.text : AuspexPalette.panel)
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 0))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Every way of looking at the board, as one menu.
///
/// A menu rather than six segments: Now is where a person lives, and the
/// other five are places they go on purpose. Six segments would also take the
/// width the counts need. On the Sessions page Now is not offered — that page
/// is the whole history as a wall, and the Now lists are about the present.
struct ViewModeMenu: View {
    @Bindable var model: LiveBoardModel
    let section: BoardSection

    var body: some View {
        let current = section.effectiveMode(model.viewMode)
        Menu {
            ForEach(BoardViewMode.pickerOrder) { mode in
                if section != .allSessions || mode != .now {
                    Button {
                        model.viewMode = mode
                    } label: {
                        if mode == current {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.systemImage)
                        }
                    }
                    // Flight draws one session, so it needs one selected.
                    .disabled(mode.requiresSelection && !model.canOpenTrajectory)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text3)
                Text(current.title).foregroundStyle(AuspexPalette.text2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            .font(AuspexType.body)
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.auspex(cornerRadius: 8))
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AuspexPalette.bg1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
        )
        .help(
            "\(NowCopy.viewMode): Now, the Ledger of cards, the Aviary, the Flock, "
                + "your Perch, or one session's Flight"
        )
        .accessibilityLabel("\(NowCopy.viewMode): \(current.title)")
    }
}

extension BoardSection {
    /// The mode this section actually draws when the board is set to `mode`.
    ///
    /// The Sessions page is the whole history as a wall; Now's lists are
    /// about the present and have no history to show, so on that page Now
    /// draws as the Ledger.
    func effectiveMode(_ mode: BoardViewMode) -> BoardViewMode {
        self == .allSessions && mode == .now ? .board : mode
    }
}
