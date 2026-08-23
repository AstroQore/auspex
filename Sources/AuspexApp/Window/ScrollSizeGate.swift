import SwiftUI

/// Gives a scroll view one concrete viewport without measuring its contents.
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
/// `GeometryReader` is the system's viewport primitive: it accepts the space
/// the parent allocates without consulting its child, then hands the child a
/// finite width and height. The scroll view therefore knows its viewport
/// before it considers its lazy content.
///
/// It has to sit **outside** the scroll view, which is why this is a wrapper
/// rather than a modifier applied inside `BoardScroll`. A layout inside the
/// scroll view would be under the question rather than in front of it —
/// `docs/research/idle-window-minsize.md` records an attempt that failed for
/// that reason.
///
/// An earlier version used a custom `Layout` whose `sizeThatFits` ignored its
/// child. That looked equivalent, but `placeSubviews` still called
/// `LayoutSubview.place` on the scroll view. Under a busy Roost page, SwiftUI's
/// lazy prefetch path used that placement to request another hosting-view
/// update, producing an AttributeGraph transaction loop. A system viewport is
/// deliberately less clever: it has no custom placement callback for the lazy
/// layout to feed back into.
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
            GeometryReader { viewport in
                content
                    .frame(
                        width: viewport.size.width,
                        height: viewport.size.height,
                        alignment: .topLeading
                    )
            }
        }
    }
}
