import AuspexCore
import SwiftUI

/// The one colour per role, in one place.
///
/// It borrows the *state* palette rather than inventing a fourth scale:
/// a prompt is the blue the board uses for "the model is working on what you
/// said", a generation is the purple of delegation, a tool is the amber of a
/// tool, and anything that failed is the one red the wall is allowed. A reader
/// who has looked at the board already knows what these mean.
enum TrajectoryStyle {
    static func color(for role: TrajectoryRole) -> Color {
        switch role {
        case .system: AuspexPalette.text3
        case .user: AuspexPalette.stateThinking
        case .assistant: AuspexPalette.stateDelegating
        case .tool: AuspexPalette.stateTool
        }
    }
}

/// What the gutter draws beside a row.
enum TrajectoryRowMarker: Hashable, Sendable {
    /// The first row of a turn.
    case turn(Int)
    /// A new model request inside the turn, or a step that failed.
    case request(isError: Bool)
    /// Nothing: this row continues the one above it.
    case none
}

/// The `USER` / `TOOL` chip at the head of a row.
struct TrajectoryRoleChip: View {
    let role: TrajectoryRole
    var isError = false

    var body: some View {
        let color = isError ? AuspexPalette.statePermission : TrajectoryStyle.color(for: role)
        Text(role.label)
            .auspexLabel(AuspexType.labelSmall)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color.opacity(0.28), lineWidth: 1)
            )
            .accessibilityLabel(role.label)
    }
}

/// One step, as a row.
///
/// Four columns, in the order the eye needs them: *where am I* (the turn
/// gutter), *who did this* (the chip), *what was it* (the text), *what did it
/// cost* (the duration and the tokens). A trajectory is read by scanning down
/// a column, so every one of them is a fixed width.
///
/// `Equatable` and compared on its value rather than on the model, because a
/// list of five thousand of these re-renders whenever anything about the
/// trajectory changes and only the rows that actually differ should redraw.
struct TrajectoryRowView: View, Equatable {
    let step: TrajectoryStep
    let marker: TrajectoryRowMarker
    let isSelected: Bool
    let isDimmed: Bool
    let onSelect: () -> Void

    /// The gutter's width. Wide enough for "Turn 12".
    static let gutterWidth: CGFloat = 58
    /// The chip column's width, so the text of every row starts in one place.
    /// Wide enough for `ASSISTANT`, which is the longest of the four and the
    /// one a truncated column would turn into `ASSISTA…`.
    static let chipWidth: CGFloat = 88

    nonisolated static func == (lhs: TrajectoryRowView, rhs: TrajectoryRowView) -> Bool {
        lhs.step == rhs.step
            && lhs.marker == rhs.marker
            && lhs.isSelected == rhs.isSelected
            && lhs.isDimmed == rhs.isDimmed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            gutter
            TrajectoryRoleChip(role: step.role, isError: step.isError)
                .frame(width: Self.chipWidth, alignment: .leading)
            content
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? AuspexPalette.bg3 : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? AuspexPalette.text.opacity(0.22) : .clear,
                    lineWidth: 1
                )
        )
        .opacity(isDimmed ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Gutter

    @ViewBuilder
    private var gutter: some View {
        switch marker {
        case .turn(let index):
            Text(index == 0 ? "Pre" : "Turn \(index)")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(1)
                .frame(width: Self.gutterWidth, alignment: .leading)
        case .request(let isError):
            HStack {
                Spacer(minLength: 0)
                Circle()
                    .fill(isError ? AuspexPalette.statePermission : AuspexPalette.text3)
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 4)
            }
            .frame(width: Self.gutterWidth)
        case .none:
            Color.clear.frame(width: Self.gutterWidth, height: 1)
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(step.title)
                    .font(isProse ? AuspexType.rowTitle : AuspexType.mono)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: step.role == .tool, vertical: false)
                if let args = step.argsPreview {
                    let shown = PathDisplay.abbreviate(args)
                    Text(shown)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                        .truncationMode(PathDisplay.truncation(for: shown))
                }
            }
            if let result = step.resultPreview {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("→")
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(
                            step.isError ? AuspexPalette.statePermission : AuspexPalette.text3
                        )
                    Text(result)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(
                            step.isError ? AuspexPalette.statePermission : AuspexPalette.text2
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A prompt or a message is prose and is set in the system face.
    /// Everything else is something the machine wrote, and its characters are
    /// what matter.
    private var isProse: Bool {
        step.role == .user || step.role == .assistant
    }

    /// The prompt is the one row a person wrote, so it is the one drawn at
    /// full strength.
    private var titleColor: Color {
        if step.isError { return AuspexPalette.statePermission }
        return step.role == .user ? AuspexPalette.text : AuspexPalette.text2
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 10) {
            if let tokens = step.tokens {
                Text("\(TokenFormat.compact(tokens.output)) out")
                    .font(AuspexType.monoSmall)
                    .auspexTabularDigits()
                    .foregroundStyle(AuspexPalette.text3)
            }
            if let duration = step.duration {
                Text(DurationFormat.short(duration))
                    .font(AuspexType.monoTime)
                    .auspexTabularDigits()
                    .foregroundStyle(
                        step.isError ? AuspexPalette.statePermission : AuspexPalette.text3
                    )
            } else if step.isError {
                Text("failed")
                    .font(AuspexType.monoTime)
                    .foregroundStyle(AuspexPalette.statePermission)
            }
        }
        .fixedSize()
    }
}
