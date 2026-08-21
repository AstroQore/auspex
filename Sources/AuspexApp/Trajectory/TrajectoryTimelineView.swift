import AuspexCore
import SwiftUI

/// The waterfall over the step list: three lanes of bars, a time axis, and a
/// range the reader can drag to filter everything below.
///
/// ## Why a `Canvas`
///
/// A session can hold thousands of steps. As views that is thousands of layers
/// laid out, compared, and composited every time the brush moves a pixel; as a
/// `Canvas` it is one immediate-mode pass whose cost is a few thousand fills,
/// and — the part that matters for § 4.1 — it is *invalidated by data, not by
/// a clock*. There is no `TimelineView` here and there must not be one: the
/// bars only move when steps arrive, when the scale changes, or when the brush
/// does.
///
/// ## Why bars are merged before they are drawn
///
/// At five thousand steps across eight hundred points, most bars are narrower
/// than a pixel, and drawing them individually produces a grey smear that
/// costs five thousand fills to look worse than a hundred. Adjacent bars of
/// the same colour that would land on the same pixel are merged into one run —
/// which is also what makes a burst of tool calls read as a solid block rather
/// than as noise.
struct TrajectoryTimelineView: View {
    @Bindable var model: TrajectoryModel
    /// What the session is signalling, if anything, and when it said so.
    ///
    /// Drawn as one vertical rule in the attention's colour. A trajectory is
    /// read to answer *how did it get here*, and "here" is the moment it asked
    /// for you — a waterfall that shows every tool call and not that moment is
    /// missing the one instant the reader came for.
    var attention: AttentionState = .none
    var attentionAt: Date?

    /// Where a drag started, in unit coordinates. `nil` when nothing is being
    /// dragged.
    @State private var dragOrigin: Double?
    /// The bar under the pointer, for the tooltip.
    @State private var hovered: TrajectoryStep?
    @State private var hoverPoint: CGPoint = .zero

    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// The width of the lane-name column. Wide enough for "Model" at 9.5 pt.
    private static let gutter: CGFloat = 52
    private static let laneHeight: CGFloat = 22
    private static let laneGap: CGFloat = 5
    private static let axisHeight: CGFloat = 16
    /// Half the width of the widest axis label, so the first and last never
    /// leave the column.
    private static let labelInset: CGFloat = 16
    /// Below this, a bar is drawn at this width instead of disappearing. An
    /// event that took a millisecond still happened.
    private static let minimumBar: CGFloat = 2

    private static var plotHeight: CGFloat {
        CGFloat(TrajectoryLane.allCases.count) * laneHeight
            + CGFloat(TrajectoryLane.allCases.count - 1) * laneGap
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                laneLabels
                plot
            }
            .frame(height: Self.plotHeight)
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter, height: Self.axisHeight)
                axis
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(AuspexPalette.bg0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    // MARK: Lanes

    private var laneLabels: some View {
        VStack(alignment: .leading, spacing: Self.laneGap) {
            ForEach(TrajectoryLane.allCases) { lane in
                Text(lane.title)
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .frame(height: Self.laneHeight, alignment: .leading)
            }
        }
        .frame(width: Self.gutter, alignment: .leading)
    }

    private var plot: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
                    draw(in: &context, size: canvasSize)
                }
                brushOverlay(in: size)
                cursorLine(in: size)
                if let hovered, !isSnapshotRender { tooltip(for: hovered, in: size) }
            }
            .contentShape(Rectangle())
            .gesture(brushGesture(in: size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    hovered = step(at: point, in: size)
                case .ended:
                    hovered = nil
                }
            }
        }
    }

    /// One pass over the spans: lane beds, then merged runs of bars.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        for (index, _) in TrajectoryLane.allCases.enumerated() {
            let rect = CGRect(
                x: 0,
                y: CGFloat(index) * (Self.laneHeight + Self.laneGap),
                width: size.width,
                height: Self.laneHeight
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 4, style: .continuous),
                with: .color(AuspexPalette.bg2)
            )
        }

        for tick in model.ticks where tick.isDivider {
            let x = tick.position * size.width
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: Self.plotHeight))
                },
                with: .color(AuspexPalette.line),
                lineWidth: 1
            )
        }

        if let x = attentionX(in: size), let colour = AttentionStyle.colour(attention) {
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: Self.plotHeight))
                },
                with: .color(colour),
                lineWidth: 1.5
            )
        }

        for run in runs(in: size) {
            let path = Path(roundedRect: run.rect, cornerRadius: 1.5, style: .continuous)
            context.fill(path, with: .color(run.color))
            // The selected bar keeps its role's colour and gains an outline.
            // Repainting it white would take the one piece of information the
            // lane exists to carry away from the bar the reader just clicked.
            if run.tone.isSelected {
                context.stroke(
                    Path(roundedRect: run.rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3),
                    with: .color(AuspexPalette.text),
                    lineWidth: 1
                )
            }
        }
    }

    /// Where the marker goes, in points across the plot.
    ///
    /// Placed by *time* when the waterfall is measured in time, and at the
    /// newest step otherwise. Under the step and turn scales the x axis is a
    /// count rather than a clock, and interpolating a wall-clock instant onto
    /// it would put the rule somewhere that means nothing — whereas "the most
    /// recent thing this session did" is exactly where a call for a person
    /// sits.
    private func attentionX(in size: CGSize) -> CGFloat? {
        guard attention.isSignalling, !model.spans.isEmpty else { return nil }
        guard model.scale == .duration,
              let at = attentionAt,
              let first = model.steps.first?.start,
              let last = model.steps.map({ $0.end ?? $0.start }).max(),
              last > first
        else { return (model.spans.last?.end).map { CGFloat($0) * size.width } }
        let fraction = at.timeIntervalSince(first) / last.timeIntervalSince(first)
        return CGFloat(min(max(fraction, 0), 1)) * size.width
    }

    /// One drawable run per group of bars that would land on the same pixels.
    private func runs(in size: CGSize) -> [Run] {
        var runs: [Run] = []
        runs.reserveCapacity(min(model.spans.count, 512))
        let selected = model.selectedID
        let hasQuery = !model.matches.isEmpty
        // Lane order is fixed, so one pass per lane keeps runs contiguous
        // without sorting the spans.
        for (laneIndex, lane) in TrajectoryLane.allCases.enumerated() {
            let y = CGFloat(laneIndex) * (Self.laneHeight + Self.laneGap) + 4
            let height = Self.laneHeight - 8
            var open: Run?
            for span in model.spans where span.lane == lane {
                let tone = Tone(
                    span: span,
                    isSelected: span.id == selected,
                    isMatch: !hasQuery || model.matches.contains(span.id),
                    hasQuery: hasQuery
                )
                let x = span.start * size.width
                let width = max(Self.minimumBar, (span.end - span.start) * size.width)
                if var current = open, current.tone == tone, x <= current.rect.maxX + 0.75 {
                    current.rect.size.width = max(current.rect.width, x + width - current.rect.minX)
                    open = current
                    continue
                }
                if let current = open { runs.append(current) }
                open = Run(
                    rect: CGRect(x: x, y: y, width: width, height: height),
                    tone: tone
                )
            }
            if let current = open { runs.append(current) }
        }
        return runs
    }

    // MARK: Brush

    private func brushGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? fraction(value.startLocation.x, in: size)
                dragOrigin = origin
                let current = fraction(value.location.x, in: size)
                guard abs(value.translation.width) > 3 else { return }
                model.brush = min(origin, current)...max(origin, current)
            }
            .onEnded { value in
                defer { dragOrigin = nil }
                // A press with no travel is a click, not a zero-width brush:
                // it selects the bar under the pointer, or clears the range if
                // there is no bar there.
                guard abs(value.translation.width) <= 3 else { return }
                if let step = step(at: value.location, in: size) {
                    model.selectedID = step.id
                    model.showsInspector = true
                } else {
                    model.brush = nil
                }
            }
    }

    @ViewBuilder
    private func brushOverlay(in size: CGSize) -> some View {
        if let brush = model.brush {
            let left = brush.lowerBound * size.width
            let right = brush.upperBound * size.width
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(AuspexPalette.bg0.opacity(0.62))
                    .frame(width: max(0, left), height: Self.plotHeight)
                Rectangle()
                    .fill(AuspexPalette.bg0.opacity(0.62))
                    .frame(width: max(0, size.width - right), height: Self.plotHeight)
                    .offset(x: right)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(AuspexPalette.text.opacity(0.35), lineWidth: 1)
                    .frame(width: max(1, right - left), height: Self.plotHeight)
                    .offset(x: left)
            }
            .allowsHitTesting(false)
        }
    }

    /// Where the session is *now*.
    ///
    /// Only Duration has a place to put it, and it is a line rather than an
    /// animation: the axis already ends at the present, so a cursor that
    /// crawled towards it would be a clock drawn to say what the right-hand
    /// edge says.
    @ViewBuilder
    private func cursorLine(in size: CGSize) -> some View {
        if let cursor = model.cursor {
            Rectangle()
                .fill(AuspexPalette.stateWriting.opacity(0.75))
                .frame(width: 1, height: Self.plotHeight)
                .offset(x: min(size.width - 1, cursor * size.width))
                .allowsHitTesting(false)
        }
    }

    // MARK: Axis

    private var axis: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(model.ticks) { tick in
                    Text(tick.label)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .fixedSize()
                        // Centred on its tick and clamped to the column, so
                        // the label at `1.0` sits inside the axis instead of
                        // hanging half of itself off the right-hand edge.
                        .position(
                            x: min(
                                max(Self.labelInset, tick.position * geometry.size.width),
                                max(Self.labelInset, geometry.size.width - Self.labelInset)
                            ),
                            y: Self.axisHeight / 2
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: Self.axisHeight)
    }

    // MARK: Hit testing

    private func fraction(_ x: CGFloat, in size: CGSize) -> Double {
        guard size.width > 0 else { return 0 }
        return min(1, max(0, x / size.width))
    }

    private func lane(at y: CGFloat) -> TrajectoryLane? {
        let pitch = Self.laneHeight + Self.laneGap
        let index = Int(y / pitch)
        guard TrajectoryLane.allCases.indices.contains(index) else { return nil }
        return TrajectoryLane.allCases[index]
    }

    /// The step whose bar is under a point, if any.
    ///
    /// A tolerance of two points either side, because a bar can legitimately
    /// be one pixel wide and nobody can hit a one-pixel target.
    private func step(at point: CGPoint, in size: CGSize) -> TrajectoryStep? {
        guard let lane = lane(at: point.y), size.width > 0 else { return nil }
        let tolerance = 2 / size.width
        let x = fraction(point.x, in: size)
        for (index, span) in model.spans.enumerated() where span.lane == lane {
            guard span.start - tolerance <= x, span.end + tolerance >= x else { continue }
            guard model.steps.indices.contains(index) else { continue }
            return model.steps[index]
        }
        return nil
    }

    private func tooltip(for step: TrajectoryStep, in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TrajectoryRoleChip(role: step.role, isError: step.isError)
                Text("Turn \(step.turn)")
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                if let duration = step.duration {
                    Text(DurationFormat.short(duration))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
                }
            }
            Text(step.title)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text)
                .lineLimit(2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: 300, alignment: .leading)
        .panelChrome(cornerRadius: 8)
        .shadow(color: AuspexPalette.shade, radius: 12, y: 4)
        .fixedSize(horizontal: false, vertical: true)
        .offset(x: min(max(0, hoverPoint.x - 40), max(0, size.width - 300)), y: Self.plotHeight + 2)
        .allowsHitTesting(false)
    }

    // MARK: Drawing values

    /// A merged run of bars.
    private struct Run {
        var rect: CGRect
        let tone: Tone
        var color: Color { tone.color }
    }

    /// What a bar is drawn in — the role's colour, dimmed when a search has
    /// pushed it into the background and lit when it is the selection.
    private struct Tone: Equatable {
        let role: TrajectoryRole
        let isError: Bool
        let isSelected: Bool
        let isDimmed: Bool

        init(span: TrajectorySpan, isSelected: Bool, isMatch: Bool, hasQuery: Bool) {
            self.role = span.role
            self.isError = span.isError
            self.isSelected = isSelected
            self.isDimmed = hasQuery && !isMatch
        }

        var color: Color {
            let base = isError ? AuspexPalette.statePermission : TrajectoryStyle.color(for: role)
            if isSelected { return base }
            return base.opacity(isDimmed ? 0.22 : 0.9)
        }
    }
}
