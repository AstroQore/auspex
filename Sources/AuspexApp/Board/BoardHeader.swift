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

    var body: some View {
        HStack(spacing: 12) {
            heading
            if section == .live || section == .allSessions {
                // The chips are the first thing to give way. Every control to
                // their right is a thing a person operates, and a picker
                // squeezed to forty points is a picker nobody can hit; a chip
                // that is not on screen is a number they can still read off
                // the sidebar and the cards.
                ViewThatFits(in: .horizontal) {
                    SummaryChips(summary: model.summary)
                    SummaryChips(summary: model.summary, limit: 3)
                    SummaryChips(summary: model.summary, limit: 2)
                    SummaryChips(summary: model.summary, limit: 1)
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer(minLength: 8)
                SegmentedPicker(
                    selection: $model.viewMode,
                    options: BoardViewMode.pickerOrder.map { ($0, $0.title) }
                )
                .fixedSize()
                .help("Read the same board as a wall of cards or as a room")
                groupMenu.fixedSize()
                searchField
            } else {
                Text(subtitle)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(AuspexPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    // MARK: Pieces

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(AuspexType.windowTitle)
                .foregroundStyle(AuspexPalette.text)
            Text("\(headingCount)")
                .font(AuspexType.monoCount)
                .auspexTabularDigits()
                .foregroundStyle(AuspexPalette.text3)
        }
        .fixedSize()
    }

    private var headingCount: Int {
        switch section {
        case .allSessions: model.board.sessions.count
        default: model.summary.live
        }
    }

    private var subtitle: String {
        switch section {
        case .harnesses:
            "\(AuspexAdapters.featured.count) harnesses · what Auspex can see on this Mac, and how"
        default:
            ""
        }
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
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(fieldBackground)
        .help("Divide the board into sections")
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
                Text(model.searchQuery.isEmpty ? "Search sessions" : model.searchQuery)
                    .font(AuspexType.body)
                    .foregroundStyle(
                        model.searchQuery.isEmpty ? AuspexPalette.text3 : AuspexPalette.text
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField("Search sessions", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, idealWidth: 150, maxWidth: 150)
        .frame(height: 28)
        .background(fieldBackground)
        .help("Search every transcript")
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

/// The four numbers, each with a dot in its state's colour.
///
/// Zeroes are dropped for the three live kinds and kept for `done`, which is
/// ``BoardSummary/chips``' rule and not this view's: a red chip that is always
/// on screen is a red chip nobody looks at.
struct SummaryChips: View {
    let summary: BoardSummary
    /// How many chips to draw, most urgent first. `nil` draws every chip that
    /// has something to say.
    var limit: Int?

    var body: some View {
        HStack(spacing: 9) {
            ForEach(shown, id: \.kind) { chip in
                HStack(spacing: 5) {
                    StateDot(color: Self.color(for: chip.kind), glows: chip.kind == .needsYou)
                    Text("\(chip.value)")
                        .font(.system(size: 11.5, weight: .bold))
                        .auspexTabularDigits()
                        .foregroundStyle(
                            chip.kind == .done ? AuspexPalette.text3 : AuspexPalette.text
                        )
                    Text(chip.kind.label)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var shown: [(kind: BoardSummary.Kind, value: Int)] {
        guard let limit else { return summary.chips }
        return Array(summary.chips.prefix(limit))
    }

    /// One colour per kind, from the state palette — so the chip that says
    /// "needs you" is the same red as the pill on the card it is counting.
    static func color(for kind: BoardSummary.Kind) -> Color {
        switch kind {
        case .needsYou: AuspexPalette.statePermission
        case .working: AuspexPalette.stateTool
        case .idle: AuspexPalette.stateIdle
        case .done: AuspexPalette.stateEnded
        }
    }
}
