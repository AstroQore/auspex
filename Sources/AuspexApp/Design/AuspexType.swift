import SwiftUI

/// The three type roles Auspex uses, and nothing else.
///
/// - **Label** — SF Pro *condensed*, uppercase, tracked out. Every piece of
///   chrome that names something rather than saying it: state pills, section
///   headers, column labels, filter chips, the toolbar's segmented control.
///   Condensed because an ops board is mostly labels and a condensed face
///   buys back the width they cost; uppercase because at 9–11 pt it is the
///   only way a label stays distinguishable from content at a glance.
/// - **Title** — SF Pro, the default width, for the one line on a card a
///   person actually reads.
/// - **Data** — SF Mono, for everything whose *characters* matter: paths,
///   pids, session ids, timestamps, durations, token counts. Monospace is not
///   decoration here. A column of `00:42` over `01:07` only scans if the
///   digits line up, and a truncated path is only readable if its slashes do.
///
/// Sizes are small and the steps between them are large. A dense board fails
/// when it has six type sizes that are all nearly the same.
enum AuspexType {
    // MARK: Label — condensed, uppercase, tracked

    /// The default label: section headers, pills, chips.
    static let label = Font.system(size: 10, weight: .semibold).width(.condensed)
    /// A smaller label for a card's footer keys and the trace gutter's header.
    static let labelSmall = Font.system(size: 9, weight: .semibold).width(.condensed)
    /// A label that is also a heading — the board's group titles.
    static let labelLarge = Font.system(size: 12, weight: .bold).width(.condensed)
    /// The big count in a section header and the empty state's headline.
    static let display = Font.system(size: 22, weight: .bold).width(.condensed)

    /// Tracking for uppercase labels. Uppercase text set tight is a smear;
    /// this is the amount that makes 10 pt caps legible without looking spaced
    /// out as an effect.
    static let labelTracking: CGFloat = 0.9

    // MARK: Title — what a person reads

    /// A card's title line.
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    /// A trace row's summary line.
    static let rowTitle = Font.system(size: 12, weight: .medium)
    /// Body copy — the empty state's paragraph, an expanded assistant message.
    static let body = Font.system(size: 12)

    // MARK: Data — monospace

    /// Paths, targets, ids.
    static let mono = Font.system(size: 11, design: .monospaced)
    /// The same, one step down, for a card's footer.
    static let monoSmall = Font.system(size: 10, design: .monospaced)
    /// The trace gutter's timestamps.
    static let monoTime = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// An expanded row's pretty-printed payload.
    static let monoBlock = Font.system(size: 10.5, design: .monospaced)
    /// The card's elapsed-in-state stopwatch — the one number on a card meant
    /// to be read from across the room.
    static let monoClock = Font.system(size: 19, weight: .medium, design: .monospaced)
}

extension View {
    /// Sets a condensed uppercase label in one call, so no call site can
    /// forget the tracking and produce a label that looks like a different
    /// design system.
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
