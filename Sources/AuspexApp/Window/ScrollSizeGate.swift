import SwiftUI

/// Stops the window's sizing pass from walking a long lazy list.
///
/// ## The measurement nobody asked for
///
/// A `ScrollView` answers "how tall would you be" by asking its content, and a
/// `LazyVStack` answers *that* by measuring every row it has — laziness is a
/// property of drawing, not of sizing. So the innocent-looking question a
/// `VStack` asks each of its children in order to divide the space between
/// them turns into a full pass over every session in the sidebar and every row
/// in the trace, and it is asked again on every graph update:
///
/// ```text
/// RootGeometry.value.getter
///  └ _FlexFrameLayout.sizeThatFits            ← the window's minWidth/minHeight
///     └ StackLayout.sizeChildrenGenerally…    ← dividing the column
///        └ NavigationStackLayout.sizeThatFits
///           └ ScrollViewUtilities.sizeThatFits(in:contentComputer:axes:)
///              └ LazyVStackLayout.sizeThatFits
///                 └ LazyStack.measureEstimates
///                    └ ForEachList.applyNodes ← every row, materialised
/// ```
///
/// That stack is 15 % of a frozen board's main thread, and none of the work in
/// it changes an answer: the column is as tall as the column is.
///
/// ## What the gate does
///
/// It is a `Layout` that answers `sizeThatFits` **from the proposal alone** and
/// never touches `subviews`, then places its one child in the whole of the
/// bounds. A parent asking "how tall would you be with nothing in particular
/// proposed" gets `0`, an infinite proposal gets `.infinity` — which is exactly
/// the flexibility a scroll view already advertises — and a concrete proposal
/// gets itself back. The child then receives a *concrete* size, and a scroll
/// view given a concrete size does not measure its content at all.
///
/// It has to sit **outside** the scroll view, which is why this is a wrapper
/// rather than a modifier applied inside `BoardScroll`. A layout inside the
/// scroll view would be under the question rather than in front of it —
/// `docs/research/idle-window-minsize.md` records an attempt that failed for
/// that reason.
///
/// Both axes, and deliberately: every scroll view this wraps is inside a
/// `NavigationSplitView` column whose width the split view decides, so there is
/// no parent left that wants a content-derived width either.
///
/// It is inert in the offscreen renderers. Those draw into a bitmap with no
/// scroll view at all — `BoardScroll` swaps in an overlay that *wants* the
/// content's ideal height — and a gate in front of it would answer for a
/// measurement that has to be real.
struct ScrollSizeGate<Content: View>: View {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @ViewBuilder let content: Content

    var body: some View {
        if isSnapshotRender {
            content
        } else {
            ProposalOnlyLayout { content }
        }
    }
}

/// A container whose size is the proposal, whatever is inside it.
struct ProposalOnlyLayout: Layout {
    /// What an unspecified dimension is worth.
    ///
    /// Zero rather than SwiftUI's own 10 × 10: this stands in front of a scroll
    /// view, and a scroll view's honest answer to "how small could you be" is
    /// nothing at all. It is the number a stack uses as the low end of the
    /// range it distributes over, and the gate has to keep the scroll view's
    /// range rather than invent a floor for it.
    static let unspecified: CGFloat = 0

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        // `subviews` is not read. That is the entire point of the type, and it
        // is the line to check first if this ever stops working.
        CGSize(
            width: proposal.width ?? Self.unspecified,
            height: proposal.height ?? Self.unspecified
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let size = ProposedViewSize(width: bounds.width, height: bounds.height)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: size)
        }
    }
}
