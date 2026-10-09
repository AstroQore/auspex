import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The default screen: the office as a stage, and under it the four lists a
/// person opens the window to read.
///
/// ## Why the stage does not scroll with the lists
///
/// The office is an `SKView` inside its own scroll view, and putting it inside
/// another one would make every wheel event over it a question — pan the room,
/// or scroll the page? — that both answer at once. Pinned above the lists, the
/// stage is either on screen or closed, which is also exactly the two states
/// its clock has: running while it can be seen, stopped when it is closed or
/// the window is not visible (see `OfficeSKView`). A stage scrolled out of a
/// page would have been a third state, animating where nobody could see it.
///
/// ## What the body reads
///
/// One value per list from ``LiveBoardModel/nowFrame``, derived on the
/// assembler's executor with the rest of the frame. Nothing here sorts or
/// filters; the rows are flat `Equatable` values that `.equatable()` compares
/// in a handful of instructions, and the stopwatches are leaves that read the
/// window's one ``BoardClock``.
struct NowView: View {
    @Bindable var model: LiveBoardModel

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let name = model.focusedProjectName {
                    ProjectFilterBar(name: name, path: model.focusedProjectKey ?? "") {
                        model.focusedProjectKey = nil
                    }
                }
                if model.showsStage {
                    NowStage(model: model)
                        .frame(height: Self.stageHeight(for: proxy.size.height))
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                NowLists(model: model, columns: NowColumns(width: proxy.size.width))
            }
        }
        .background(AuspexPalette.canvas)
    }

    /// The design's 380 points, as long as the lists keep at least half of
    /// the column. A short window gets a shorter stage rather than a list with
    /// two rows showing.
    static func stageHeight(for column: CGFloat) -> CGFloat {
        min(380, max(200, (column - 16) * 0.5))
    }
}

// MARK: - Stage

/// The office in a card, with its tag, its hint and its legend over it.
private struct NowStage: View {
    let model: LiveBoardModel

    var body: some View {
        // Six at most, already chosen and ordered by the frame; this only
        // turns each into the words it prints.
        let captions = model.nowFrame.captions
        NowStageScene(
            model: model,
            captions: Self.balloons(captions),
            focus: captions.first?.deskKey
        )
        .equatable()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) { tag.padding(.leading, 18).padding(.top, 14) }
            .overlay(alignment: .topTrailing) { collapse.padding(.trailing, 12).padding(.top, 12) }
            .overlay(alignment: .bottomTrailing) { legend.padding(.trailing, 18).padding(.bottom, 14) }
    }

    static func balloons(_ captions: [NowFrame.Caption]) -> [SessionKey: SceneCaption] {
        var result: [SessionKey: SceneCaption] = [:]
        for caption in captions {
            guard let balloon = NowCopy.balloon(for: caption) else { continue }
            result[caption.deskKey] = balloon
        }
        return result
    }

    private var tag: some View {
        HStack(spacing: 8) {
            Text(NowCopy.stageTag)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.66)
                .foregroundStyle(AuspexPalette.bg0)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(AuspexPalette.text.opacity(0.82)))
            Text(NowCopy.stageHint)
                .font(.system(size: 11))
                .foregroundStyle(AuspexPalette.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(AuspexPalette.panel.opacity(0.85)))
        }
        .allowsHitTesting(false)
    }

    private var collapse: some View {
        Button { model.showsStage = false } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuspexPalette.text2)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AuspexPalette.panel.opacity(0.9))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 6))
        .help(NowCopy.collapseStage)
        .accessibilityLabel(NowCopy.collapseStage)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            entry(AuspexPalette.text, NowCopy.legendWorking)
            entry(AuspexPalette.nowNeeds, NowCopy.legendNeedsYou)
            entry(AuspexPalette.nowMaybe, NowCopy.legendMayNeedYou)
            entry(AuspexPalette.stateIdle, NowCopy.legendIdle)
        }
        .font(.system(size: 11))
        .foregroundStyle(AuspexPalette.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.9))
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func entry(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

/// The office itself, re-evaluated only when its balloons change.
///
/// Now's frame moves whenever any row on it does; the office's own inputs —
/// the reduced board, the selection — are observed inside
/// ``SceneContainerView`` and invalidate it by themselves. This wrapper keeps
/// a frame that changed a list but not a balloon from reaching the scene.
private struct NowStageScene: View, Equatable {
    let model: LiveBoardModel
    let captions: [SessionKey: SceneCaption]
    let focus: SessionKey?

    nonisolated static func == (lhs: NowStageScene, rhs: NowStageScene) -> Bool {
        lhs.model === rhs.model && lhs.captions == rhs.captions && lhs.focus == rhs.focus
    }

    var body: some View {
        SceneContainerView(model: model, chrome: .stage, captions: captions, stageFocus: focus)
    }
}

// MARK: - Lists

/// The four lists and the idle line.
private struct NowLists: View {
    @Bindable var model: LiveBoardModel
    let columns: NowColumns

    /// How many working rows show before the rest fold into "N more".
    private static let workingLimit = 8

    @State private var showsAllWorking = false
    @State private var showsIdle = false

    var body: some View {
        let frame = model.nowFrame
        let selected = model.selectedKey
        BoardScroll {
            LazyVStack(alignment: .leading, spacing: 18) {
                if frame.isEmpty {
                    Text(NowCopy.allClear)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.vertical, 8)
                }
                if !frame.needsYou.isEmpty {
                    section(.needsYou, NowCopy.needsYouHeading, NowCopy.needsYouNote, frame.needsYou, selected)
                }
                if !frame.mayNeedYou.isEmpty {
                    section(.mayNeedYou, NowCopy.mayNeedYouHeading, NowCopy.mayNeedYouNote, frame.mayNeedYou, selected)
                }
                if !frame.working.isEmpty { working(frame.working, selected: selected) }
                if !frame.done.isEmpty {
                    section(.done, NowCopy.doneHeading, NowCopy.doneNote, frame.done, selected)
                }
                if frame.idleCount > 0 { idle(frame.idle, selected: selected) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(
        _ tone: NowFrame.Tone,
        _ heading: String,
        _ note: String,
        _ items: [NowFrame.Item],
        _ selected: SessionKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NowSectionHeading(title: heading, count: items.count, note: note, ink: NowTone.ink(tone))
            ForEach(items) { item in
                NowRow(
                    item: item,
                    isSelected: selected == item.key,
                    columns: columns,
                    onOpen: { open(item) },
                    onMarkSeen: item.tone == .done ? { model.markSeen(item.key) } : nil
                )
                .equatable()
            }
        }
    }

    private func working(_ items: [NowFrame.Item], selected: SessionKey?) -> some View {
        let shown = showsAllWorking ? items[...] : items.prefix(Self.workingLimit)
        return VStack(alignment: .leading, spacing: 8) {
            NowSectionHeading(
                title: NowCopy.workingHeading,
                count: items.count,
                note: NowCopy.workingNote,
                ink: NowTone.ink(.working)
            )
            NowWorkingHeader(columns: columns)
            ForEach(shown) { item in
                NowWorkingRow(item: item, isSelected: selected == item.key, columns: columns) {
                    open(item)
                }
                .equatable()
            }
            if items.count > Self.workingLimit {
                foldToggle(
                    showsAllWorking ? NowCopy.fewer : NowCopy.more(items.count - Self.workingLimit)
                ) { showsAllWorking.toggle() }
            }
        }
    }

    private func idle(_ items: [NowFrame.Item], selected: SessionKey?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            foldToggle(NowCopy.idle(items.count, isOpen: showsIdle)) { showsIdle.toggle() }
            if showsIdle {
                ForEach(items) { item in
                    NowRow(
                        item: item,
                        isSelected: selected == item.key,
                        columns: columns,
                        onOpen: { open(item) }
                    )
                    .equatable()
                }
            }
        }
    }

    private func foldToggle(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(AuspexPalette.text3)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
    }

    /// Selecting the session is what opens it: the trace fills the column
    /// beside the lists, the same as a click on a card or on a person in the
    /// office. A blocked task nobody has picked up has no trace, so it opens
    /// the task's page instead.
    private func open(_ item: NowFrame.Item) {
        if item.hasSession {
            model.selectedKey = item.key
        } else {
            model.openUnitID = item.unitID
        }
    }
}

/// A list's heading: the tone's ink, a count, and the rule the list follows.
private struct NowSectionHeading: View {
    let title: String
    let count: Int
    let note: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.96)
                .foregroundStyle(ink)
            Text("\(count) · \(note)")
                .font(.system(size: 12, design: .monospaced))
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The colours a tone is drawn in.
enum NowTone {
    /// The dot, the left rule, a balloon.
    static func mark(_ tone: NowFrame.Tone) -> Color {
        switch tone {
        case .needsYou: AuspexPalette.nowNeeds
        case .mayNeedYou: AuspexPalette.nowMaybe
        case .done: AuspexPalette.nowDone
        case .working: AuspexPalette.text
        case .idle: AuspexPalette.stateIdle
        }
    }

    /// Words in the tone: a heading, a pill's count.
    static func ink(_ tone: NowFrame.Tone) -> Color {
        switch tone {
        case .needsYou: AuspexPalette.nowNeedsInk
        case .mayNeedYou: AuspexPalette.nowMaybeInk
        case .done: AuspexPalette.nowDoneInk
        case .working: AuspexPalette.text
        case .idle: AuspexPalette.text3
        }
    }

    /// The pill's ground.
    static func wash(_ tone: NowFrame.Tone) -> Color {
        switch tone {
        case .needsYou: AuspexPalette.nowNeedsWash
        case .mayNeedYou: AuspexPalette.nowMaybeWash
        case .done: AuspexPalette.nowDoneWash
        case .working, .idle: AuspexPalette.bg2
        }
    }

    /// Whether the row wears the tone's rule down its left edge.
    static func isRuled(_ tone: NowFrame.Tone) -> Bool {
        switch tone {
        case .needsYou, .mayNeedYou, .done: true
        case .working, .idle: false
        }
    }
}

// MARK: - Rows

/// The column widths every row shares, so the four lists line up.
///
/// Two sets, chosen from the column's width once per layout rather than per
/// row: the design's widths when the column is wide enough to leave the
/// "doing" column room to say something, and narrower ones beside an open
/// trace, where the design's would leave it a hundred points.
struct NowColumns: Equatable {
    let dot: CGFloat = 10
    let project: CGFloat
    let harness: CGFloat
    let metric: CGFloat
    let turn: CGFloat
    let context: CGFloat
    let action: CGFloat
    let spacing: CGFloat

    init(width: CGFloat) {
        if width >= 1_000 {
            project = 120; harness = 110; metric = 90; turn = 120; context = 110
            action = 72; spacing = 14
        } else {
            project = 96; harness = 84; metric = 64; turn = 92; context = 84
            action = 52; spacing = 10
        }
    }
}

/// One line in Needs you, May need you, Done or Idle.
private struct NowRow: View, Equatable {
    let item: NowFrame.Item
    let isSelected: Bool
    let columns: NowColumns
    var onOpen: () -> Void = {}
    var onMarkSeen: (() -> Void)?

    /// The closures are left out: whether there is a "mark seen" is decided by
    /// the item's tone, which is compared.
    nonisolated static func == (lhs: NowRow, rhs: NowRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.columns == rhs.columns
    }

    var body: some View {
        HStack(spacing: columns.spacing) {
            Circle()
                .fill(NowTone.mark(item.tone))
                .frame(width: columns.dot, height: columns.dot)
            NowProjectCell(row: item.row, width: columns.project)
            NowHarnessCell(harness: item.row.harness, width: columns.harness)
            line
                .frame(maxWidth: .infinity, alignment: .leading)
            metric
                .frame(width: columns.metric, alignment: .leading)
            action
                .frame(width: columns.action, alignment: .trailing)
        }
        .nowRowChrome(tone: item.tone, isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(item.row.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var line: some View {
        switch item.reason {
        case .permission(let tool, let target):
            if let tool {
                Text("\(NowCopy.waitingPermission) \(Self.mono(NowCopy.call(tool, target)))")
                    .nowLine()
            } else {
                Text(NowCopy.waitingAnswer).nowLine()
            }
        case .notice(let message):
            Text("notify · \(message)").nowLine()
        case .blockedTask:
            Text("\(NowCopy.blockedTask) · \(item.unitTitle)").nowLine()
        case .watch(let kind, _):
            Text("\(NowCopy.watch(kind, tool: item.activity.tool)) · \(Self.mono(scoreAndKind(kind)))")
                .nowLine()
        case .done(let summary):
            Text("\(item.unitTitle) · 「\(summary)」").nowLine()
        case .working, .idle:
            NowActivityText(activity: item.activity)
        }
    }

    static func mono(_ text: String) -> Text {
        Text(text).font(.system(size: 12.5, design: .monospaced))
    }

    /// The signal's code, and a classifier's confidence ahead of it once one
    /// is wired in — `jev 0.91 stale_session`.
    private func scoreAndKind(_ kind: WatchSignal.Kind) -> String {
        guard let score = item.score else { return kind.rawValue }
        return String(format: "jev %.2f %@", score, kind.rawValue)
    }

    @ViewBuilder
    private var metric: some View {
        if case .watch(.contextPressure, _) = item.reason, let fraction = item.row.context?.fraction {
            Text("\(Int((fraction * 100).rounded()))%").nowMetric()
        } else if item.sessionCount > 1 {
            Text("×\(item.sessionCount)").nowMetric()
        } else if let since = item.since {
            if case .watch(.staleSession, _) = item.reason {
                NowElapsed(since: since, suffix: " idle")
            } else {
                NowElapsed(since: since)
            }
        } else {
            Text(verbatim: "").nowMetric()
        }
    }

    @ViewBuilder
    private var action: some View {
        if let onMarkSeen {
            Button(NowCopy.markSeen, action: onMarkSeen)
                .buttonStyle(.auspex)
                .font(.system(size: 12))
                .foregroundStyle(AuspexPalette.accent)
        } else if item.tone == .idle {
            Text(NowCopy.openQuiet)
                .font(.system(size: 12))
                .foregroundStyle(AuspexPalette.text3)
        } else {
            Button(item.hasSession ? NowCopy.open : NowCopy.openTask, action: onOpen)
                .buttonStyle(.auspex)
                .font(.system(size: 12))
                .foregroundStyle(AuspexPalette.accent)
        }
    }
}

/// One running family: its root, what it is doing, for how long, how many
/// subagents are folded under it, and how full its context is.
private struct NowWorkingRow: View, Equatable {
    let item: NowFrame.Item
    let isSelected: Bool
    let columns: NowColumns
    var onOpen: () -> Void = {}

    nonisolated static func == (lhs: NowWorkingRow, rhs: NowWorkingRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.columns == rhs.columns
    }

    var body: some View {
        HStack(spacing: columns.spacing) {
            Circle()
                .fill(NowTone.mark(.working))
                .frame(width: columns.dot, height: columns.dot)
            NowProjectCell(row: item.row, width: columns.project)
            NowHarnessCell(harness: item.row.harness, width: columns.harness)
            NowActivityText(activity: item.activity)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if let since = item.since {
                    NowElapsed(since: since)
                } else {
                    Text(verbatim: "—").nowMetric()
                }
                Text(" · ↳\(item.subagents)").nowMetric()
            }
            .frame(width: columns.turn, alignment: .leading)
            NowContextBar(gauge: item.row.context)
                .frame(width: columns.context)
            Button(NowCopy.openQuiet, action: onOpen)
                .buttonStyle(.auspex)
                .font(.system(size: 12))
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: columns.action, alignment: .trailing)
        }
        .nowRowChrome(tone: .working, isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(item.row.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The small-caps line over the working rows.
private struct NowWorkingHeader: View {
    let columns: NowColumns

    var body: some View {
        HStack(spacing: columns.spacing) {
            Color.clear.frame(width: columns.dot, height: 1)
            label(NowCopy.columnProject).frame(width: columns.project, alignment: .leading)
            label(NowCopy.columnHarness).frame(width: columns.harness, alignment: .leading)
            label(NowCopy.columnDoing).frame(maxWidth: .infinity, alignment: .leading)
            label(NowCopy.columnTurn).frame(width: columns.turn, alignment: .leading)
            label(NowCopy.columnContext).frame(width: columns.context, alignment: .leading)
            Color.clear.frame(width: columns.action, height: 1)
        }
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .tracking(0.66)
            .foregroundStyle(AuspexPalette.text3)
            .lineLimit(1)
    }
}

private struct NowProjectCell: View {
    let row: BoardRow
    let width: CGFloat

    var body: some View {
        Text(row.project ?? row.shortID)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AuspexPalette.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }
}

private struct NowHarnessCell: View {
    let harness: Harness
    let width: CGFloat

    var body: some View {
        Text(harness.displayName)
            .font(.system(size: 12))
            .foregroundStyle(AuspexPalette.text3)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

/// `WebSearch 「OpenAI Dots API」` — the tool in mono, its argument after it.
private struct NowActivityText: View {
    let activity: NowFrame.Activity

    var body: some View {
        Group {
            switch (activity.tool, activity.detail) {
            case let (tool?, detail?) where !detail.isEmpty:
                Text("\(NowRow.mono(tool)) \(PathDisplay.condense(detail, limit: 80))")
            case let (tool?, _):
                Text(tool).font(.system(size: 12.5, design: .monospaced))
            case let (nil, detail):
                Text(detail ?? "…")
            }
        }
        .nowLine()
    }
}

/// The context window as a bar and a percentage, accented once it is warm.
private struct NowContextBar: View {
    let gauge: ContextGauge?

    var body: some View {
        if let fraction = gauge?.fraction {
            let warm = fraction >= ContextGauge.warmThreshold
            HStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AuspexPalette.bg2)
                        Capsule()
                            .fill(warm ? AuspexPalette.accent : AuspexPalette.text)
                            .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 4)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .auspexTabularDigits()
                    .foregroundStyle(warm ? AuspexPalette.nowNeedsInk : AuspexPalette.text3)
                    .frame(width: 32, alignment: .trailing)
            }
            .help(gauge?.helpText ?? "")
        } else {
            Text(verbatim: "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AuspexPalette.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("This harness does not record its context window.")
        }
    }
}

/// A stopwatch, in the compact form the lists use.
///
/// A leaf, and the only thing on the screen that reads ``BoardClock``: the
/// clock ticks every five seconds and re-evaluates these labels and nothing
/// above them.
struct NowElapsed: View {
    let since: Date
    var suffix = ""

    @Environment(BoardClock.self) private var clock: BoardClock?

    var body: some View {
        let now = clock?.now ?? Date()
        Text(NowFrame.compactDuration(now.timeIntervalSince(since)) + suffix)
            .nowMetric()
    }
}

// MARK: - Styling

private extension View {
    func nowLine() -> some View {
        font(.system(size: 13))
            .foregroundStyle(AuspexPalette.text)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    func nowMetric() -> some View {
        font(.system(size: 12, design: .monospaced))
            .auspexTabularDigits()
            .foregroundStyle(AuspexPalette.text3)
            .lineLimit(1)
    }

    /// A row's card: white on the board, a tinted hairline, and the tone's
    /// rule down the left for the three lists that are about the person.
    func nowRowChrome(tone: NowFrame.Tone, isSelected: Bool) -> some View {
        let ruled = NowTone.isRuled(tone)
        let mark = NowTone.mark(tone)
        return padding(.vertical, 12)
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AuspexPalette.selection : AuspexPalette.panel)
            )
            .overlay(alignment: .leading) {
                if ruled {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous
                    )
                    .fill(mark)
                    .frame(width: 3)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? AuspexPalette.accent
                            : (ruled ? mark.opacity(0.28) : AuspexPalette.line),
                        lineWidth: 1
                    )
            )
    }
}
