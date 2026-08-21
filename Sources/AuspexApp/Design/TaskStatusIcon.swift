import AuspexCore
import SwiftUI

/// The glyph that says where a task stands, in one 14 pt ring.
///
/// ## Why a ring and not a filled pill
///
/// Every state is the same two-point outline circle with something different
/// inside it, which is what makes the five read as one family from across a
/// wall: the reader learns *circle = a task*, and then only has to tell a dash
/// from a dot from a check. A set of differently-shaped badges would have to be
/// read one at a time.
///
/// The vocabulary is borrowed from Carbon (chunkburst/Carbon, MIT), whose task
/// tracking the user called 先进且直观, and the borrowing is of the *shape*:
/// dashed for not started, a dot for in flight, a check for finished. What is
/// ours is which colour each wears, and those come straight from the board's
/// own state palette — so the icon on a card and the chip counting it in the
/// header are the same colour, always.
struct TaskStatusIcon: View {
    let status: AuspexTaskStatus
    var size: CGFloat = 14
    /// Drawn muted, for a card that is finished and folded away.
    var isMuted = false

    var body: some View {
        let colour = isMuted ? AuspexPalette.stateEnded : Self.colour(status)
        ZStack {
            switch status {
            case .todo:
                // Dashed: an outline that has not been closed yet.
                Circle()
                    .strokeBorder(
                        colour,
                        style: StrokeStyle(
                            lineWidth: line,
                            lineCap: .round,
                            dash: dash(segments: 8)
                        )
                    )
            case .doing:
                Circle().strokeBorder(colour, lineWidth: line)
                Circle().fill(colour).frame(width: size * 0.3, height: size * 0.3)
            case .blocked:
                // The one glyph that is not a dot: an alert bar, because a
                // blocked task is the only state on this wall a person has to
                // act on and it must not read as "in flight, in red".
                Circle().strokeBorder(colour, lineWidth: line)
                Capsule()
                    .fill(colour)
                    .frame(width: line, height: size * 0.24)
                    .offset(y: -size * 0.13)
                Circle()
                    .fill(colour)
                    .frame(width: line, height: line)
                    .offset(y: size * 0.19)
            case .review:
                Circle().strokeBorder(colour, lineWidth: line)
                check(colour)
            case .done:
                // Filled, and the only one that is: a closed task is the one
                // state nothing further happens in, and a solid disc is what
                // says "this is not a thing to look at" at a glance.
                Circle().fill(colour.opacity(0.9))
                check(AuspexPalette.bg0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }

    private var line: CGFloat { max(1, size * 0.145) }

    /// A dashed ring of `segments` equal arcs, so the gaps stay even at every
    /// size. Two thirds mark, one third gap: any looser and the ring stops
    /// reading as a circle at 14 pt.
    private func dash(segments: Int) -> [CGFloat] {
        let circumference = .pi * (size - line)
        let step = circumference / CGFloat(segments)
        return [step * 0.62, step * 0.38]
    }

    private func check(_ colour: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.30, y: size * 0.51))
            path.addLine(to: CGPoint(x: size * 0.44, y: size * 0.66))
            path.addLine(to: CGPoint(x: size * 0.71, y: size * 0.36))
        }
        .stroke(colour, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
    }

    /// One colour per status, from the board's own state palette.
    ///
    /// The pairing is what makes the wall legible as one thing: the amber a
    /// card wears while it is running is the amber of the `working` chip; the
    /// red of a blocked task is the red of `needs you`; the green of a review
    /// is the green the board has always used for "an agent made something".
    static func colour(_ status: AuspexTaskStatus) -> Color {
        switch status {
        case .todo: AuspexPalette.text3
        case .doing: AuspexPalette.stateTool
        case .blocked: AuspexPalette.statePermission
        case .review: AuspexPalette.stateWriting
        case .done: AuspexPalette.stateEnded
        }
    }
}

/// How much a task matters, as a signal ramp.
///
/// Carbon's shape again: a baseline dot and bars that get taller, each level
/// simply truncating the ramp rather than greying part of it out. Urgent
/// breaks the pattern with an alert ring, because urgent is not "one more bar"
/// — it is a different claim.
///
/// **`normal` draws nothing.** A mark on every row is a mark nobody reads, and
/// the great majority of tasks are ordinary. The leading column is still
/// reserved at its width so the status icons beside it stay in a line.
struct TaskImportanceIcon: View {
    let importance: TaskImportance
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch importance {
            case .normal:
                Color.clear
            case .urgent:
                ZStack {
                    Circle().strokeBorder(colour, lineWidth: max(1, size * 0.17))
                    Capsule()
                        .fill(colour)
                        .frame(width: max(1, size * 0.17), height: size * 0.26)
                        .offset(y: -size * 0.12)
                    Circle()
                        .fill(colour)
                        .frame(width: max(1, size * 0.17), height: max(1, size * 0.17))
                        .offset(y: size * 0.22)
                }
            case .important, .low:
                bars
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(importance.label)
        .help("Importance: \(importance.label)")
    }

    /// The ramp: a dot on the baseline, then one bar per level.
    private var bars: some View {
        let width = max(1, size * 0.16)
        let filled = importance == .important ? 3 : 1
        return HStack(alignment: .bottom, spacing: size * 0.12) {
            Circle().fill(colour).frame(width: width, height: width)
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? colour : Color.clear)
                    .frame(width: width, height: size * (0.34 + CGFloat(index) * 0.24))
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
    }

    private var colour: Color {
        switch importance {
        case .urgent: AuspexPalette.statePermission
        case .important: AuspexPalette.text2
        case .normal, .low: AuspexPalette.text3
        }
    }
}

/// A task's handle, and everything a chip row says about it.
///
/// One place rather than four, because the wall, the Tasks page, the detail
/// header and the command palette all draw the same handful of facts and a
/// second implementation is a second chance for them to disagree.
struct TaskChips: View {
    let unit: TaskUnit
    /// Fewer chips, for a card in a grid cell rather than a page.
    var isCompact = false

    var body: some View {
        if unit.kind != nil || !labels.isEmpty || unit.isClaimOrphaned || !unit.waitingOn.isEmpty {
            HStack(spacing: 5) {
                if let kind = unit.kind {
                    FactChip(kind.label, tint: AuspexPalette.text3)
                        .fixedSize()
                }
                ForEach(labels, id: \.self) { label in
                    FactChip(label, tint: AuspexPalette.stateThinking)
                        .fixedSize()
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize()
                }
                if !unit.waitingOn.isEmpty { waits }
                if unit.isClaimOrphaned { orphan }
                Spacer(minLength: 0)
            }
        }
    }

    private var labels: [String] {
        Array(unit.labels.prefix(isCompact ? 2 : 5))
    }

    private var overflow: Int { max(0, unit.labels.count - labels.count) }

    /// What the task is waiting on, by handle. A dependency drawn as a number
    /// would be a number nobody can look up.
    private var waits: some View {
        FactChip(tint: AuspexPalette.stateStale) {
            Text("waits on \(unit.waitingOn.map(\.shortID).joined(separator: ", "))")
                .font(AuspexType.monoSmall)
        }
        .fixedSize()
        .help(
            "Blocked by "
                + unit.waitingOn.map { "\($0.shortID) \($0.title)" }.joined(separator: " · ")
        )
    }

    /// A claim its session did not live to finish.
    private var orphan: some View {
        FactChip("claim orphaned", tint: AuspexPalette.stateStale)
            .fixedSize()
            .help(
                "The session holding this claim ended without finishing. "
                    + "Release it so somebody else can take it."
            )
    }
}
