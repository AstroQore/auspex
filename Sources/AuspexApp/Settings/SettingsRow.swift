import SwiftUI

/// The three column widths every settings list shares.
///
/// In one place because the point of them is that two different lists — the
/// pieces Auspex installs into a harness, and the character each harness wears
/// — line up with each other when a person switches panes.
enum SettingsLayout {
    /// Wide enough for the longest piece name at 12 pt.
    static let labelWidth: CGFloat = 148
    /// Wide enough for "installed" beside a Remove button, which is the widest
    /// pair of controls any row has.
    static let actionWidth: CGFloat = 150
    /// A pop-up naming a character package. Wider than a pair of buttons
    /// because the names in it are not Auspex's to shorten.
    static let pickerWidth: CGFloat = 210
    static let columnSpacing: CGFloat = 12
    /// The narrowest the middle column is any use at.
    ///
    /// It holds a file path, a list of hook events, and sometimes a sentence.
    /// Below this the sentence becomes a word per line and the path becomes an
    /// ellipsis, so a row this narrow stacks instead — see ``SettingsRow``.
    static let detailWidth: CGFloat = 220
}

/// One row of a settings list: what it is, what is true about it, and the one
/// control that changes it.
///
/// ## Why the action column has a width
///
/// Every list in Settings is read down its right-hand edge — *which of these is
/// installed*, *which one has a button I have not pressed*. That read only
/// works if the buttons are in a line, and they were not: an installed row put
/// the word "installed" beside a Remove button, a blocked row put a two-line
/// sentence in the same place, and the column zig-zagged by two hundred points
/// between one row and the next.
///
/// So the third column is a fixed width and holds nothing but controls. A
/// *reason* is not a control; it is something true about the row, and it
/// belongs in the middle column with the path and the note. That single move is
/// what makes the edge straight.
///
/// ## Why the label column has one too
///
/// The same read, one column over. A label column that sizes to its content
/// puts "MCP server" and "Task-protocol note" at different indents, so the
/// detail beside them starts somewhere different on every row.
struct SettingsRow<Label: View, Detail: View, Action: View>: View {
    var labelWidth: CGFloat = SettingsLayout.labelWidth
    var actionWidth: CGFloat = SettingsLayout.actionWidth
    /// What the row is. A name, usually; a mark and a name where the thing has
    /// a mark of its own.
    @ViewBuilder var label: Label
    /// Everything true about the row: the file it writes, what it covers, what
    /// stopped it. Wraps freely — this is the column with width to spare.
    @ViewBuilder var detail: Detail
    /// The control, and only the control. Empty is a perfectly good answer.
    @ViewBuilder var action: Action

    var body: some View {
        ViewThatFits(in: .horizontal) {
            columns
            stacked
        }
        .padding(.vertical, 3)
    }

    /// Three columns, when three columns fit.
    private var columns: some View {
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            labelColumn.frame(width: labelWidth, alignment: .leading)
            detailColumn
                // A real ideal width, so the ladder above can tell a row that
                // fits from one that has been squeezed into fitting. Without
                // it the middle column reports nothing, the three-column
                // layout is chosen at any width at all, and a card 440 points
                // wide gives the path and the hook list ninety points to wrap
                // a word at a time in.
                .frame(
                    idealWidth: SettingsLayout.detailWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            actionColumn.frame(width: actionWidth, alignment: .trailing)
        }
    }

    /// The same row in a column too narrow for three: what it is and the
    /// control on one line, everything true about it underneath.
    ///
    /// The control keeps the right-hand edge, because the read that the fixed
    /// action column exists for — *which of these has a button I have not
    /// pressed* — is the one read that still works when the rows are in a
    /// grid.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.columnSpacing) {
                labelColumn.frame(maxWidth: .infinity, alignment: .leading)
                actionColumn.fixedSize()
            }
            detailColumn.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var labelColumn: some View {
        label
            // Wraps to as many lines as it needs, rather than to as many
            // as the row beside it happens to be tall — which is what an
            // `HStack` gives a `Text` with no opinion, and why one
            // "Register the Auspex MCP server" wrapped and the next one
            // truncated.
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            detail
        }
    }

    private var actionColumn: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            action
        }
    }
}

extension SettingsRow where Label == Text {
    init(
        title: String,
        labelWidth: CGFloat = SettingsLayout.labelWidth,
        actionWidth: CGFloat = SettingsLayout.actionWidth,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder action: () -> Action
    ) {
        self.init(
            labelWidth: labelWidth,
            actionWidth: actionWidth,
            label: {
                Text(title)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text)
            },
            detail: detail,
            action: action
        )
    }
}

/// A settings list's own heading rule: a name, and what the rows under it are.
struct SettingsSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            if let detail {
                Text(detail)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
    }
}
