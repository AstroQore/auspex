import SwiftUI

/// The three type roles Auspex uses, and nothing else.
///
/// - **Label** — SF Pro, semibold, tracked out, and uppercased at the call
///   site by ``SwiftUI/View/auspexLabel(_:)``. Every piece of chrome that
///   *names* something rather than saying it: sidebar section headers, column
///   headers, the "TURN 3" rule.
/// - **Title** — SF Pro, for the lines a person actually reads: the window
///   heading, a card's headline, a trace row's summary.
/// - **Data** — SF Mono, for everything whose *characters* matter: paths,
///   pids, session ids, timestamps, durations, token counts. Monospace is not
///   decoration here. A column of `00:42` over `01:07` only scans if the
///   digits line up, and a truncated path is only readable if its slashes do.
///
/// Sizes are small and the steps between them are large. A dense board fails
/// when it has six type sizes that are all nearly the same.
///
/// Nothing is condensed. Condensed faces buy width back, but they also make
/// two harnesses' names look like the same word at a glance, and on a wall the
/// reader is scanning rather than reading that is the wrong trade.
enum AuspexType {
    // MARK: Label — uppercase, tracked

    /// The default label: column headers, the trace's turn rule.
    static let label = Font.system(size: 10, weight: .semibold)
    /// A smaller label for a card's footer keys and dense chrome.
    static let labelSmall = Font.system(size: 9.5, weight: .semibold)
    /// A label that is also a heading — the sidebar's `PROJECTS` rule.
    static let labelLarge = Font.system(size: 10.5, weight: .semibold)
    /// The big count in an empty state's headline.
    static let display = Font.system(size: 22, weight: .bold)

    /// Tracking for uppercase labels. Uppercase text set tight is a smear;
    /// this is the amount that makes 10 pt caps legible without looking spaced
    /// out as an effect. It is the mock's `letter-spacing: 0.08em`.
    static let labelTracking: CGFloat = 0.85

    // MARK: Title — what a person reads

    /// The window heading over the board — "Live", "Harnesses".
    static let windowTitle = Font.system(size: 16, weight: .bold)
    /// The trace header's session name.
    static let paneTitle = Font.system(size: 15, weight: .bold)
    /// A card's title line.
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    /// A sidebar row, and a menu bar row's session name.
    static let row = Font.system(size: 12.5, weight: .medium)
    /// A sidebar row that is selected, and a board group's header.
    static let rowStrong = Font.system(size: 12.5, weight: .semibold)
    /// A trace row's summary line.
    static let rowTitle = Font.system(size: 12)
    /// A state pill, a summary chip, a segmented control's segment.
    static let pill = Font.system(size: 11, weight: .semibold)
    /// Body copy — the empty state's paragraph, an expanded assistant message.
    static let body = Font.system(size: 12)
    /// A card's footer keys and the counts beside them.
    static let caption = Font.system(size: 11)

    // MARK: Data — monospace

    /// A card's activity line and the trace's row text.
    static let mono = Font.system(size: 12, design: .monospaced)
    /// Ids, pids, models, branch names — the second line of a card.
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    /// A count that has to line up with the one above it.
    static let monoCount = Font.system(size: 11, weight: .semibold, design: .monospaced)
    /// The trace gutter's timestamps.
    static let monoTime = Font.system(size: 11, design: .monospaced)
    /// An expanded row's pretty-printed payload.
    static let monoBlock = Font.system(size: 10.5, design: .monospaced)
    /// A card's elapsed stopwatch.
    static let monoClock = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

extension View {
    /// Sets an uppercase tracked label in one call, so no call site can forget
    /// the tracking and produce a label that looks like a different design
    /// system.
    func auspexLabel(_ font: Font = AuspexType.label) -> some View {
        self.font(font)
            .textCase(.uppercase)
            .tracking(AuspexType.labelTracking)
    }

    /// Keeps digits from changing width as a counter ticks, which is what
    /// makes a wall of stopwatches sit still.
    func auspexTabularDigits() -> some View {
        monospacedDigit()
    }
}
