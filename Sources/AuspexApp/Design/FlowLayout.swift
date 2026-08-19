import SwiftUI

/// A row of things that wraps.
///
/// ## Why not `LazyVGrid`
///
/// Chips are the one thing in this window whose width is their content: an
/// MCP server called `github` and one called `cloudflare-observability` are
/// eleven characters apart, and a grid — which is what `LazyVGrid(.adaptive)`
/// is — gives them the same column and truncates the second to `clou…lity`.
/// A truncated identifier is worse than an absent one: it looks like data and
/// cannot be read.
///
/// So the chip rows lay out like text instead. Each item takes the width it
/// asks for, the line breaks when the next one will not fit, and nothing is
/// ever cut to fit a column that was sized by something else.
struct FlowLayout: Layout {
    /// Space between two items on a line.
    var spacing: CGFloat = 6
    /// Space between lines.
    var lineSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = layout(subviews: subviews, in: width)
        let height = lines.reduce(into: CGFloat.zero) { total, line in
            total += line.height + (total > 0 ? lineSpacing : 0)
        }
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for line in layout(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in line.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// One wrapped line: which subviews are on it, and how big it is.
    private struct Line {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    /// Breaks the subviews into lines that fit `width`.
    ///
    /// An item wider than the whole line still gets a line of its own rather
    /// than being dropped, so a very long server name overflows visibly
    /// instead of disappearing.
    private func layout(subviews: Subviews, in width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var x: CGFloat = 0
        var height: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = x == 0 ? size.width : x + spacing + size.width
            if needed > width, index > start {
                lines.append(Line(range: start..<index, width: x, height: height))
                start = index
                x = size.width
                height = size.height
            } else {
                x = needed
                height = max(height, size.height)
            }
        }
        if start < subviews.count {
            lines.append(Line(range: start..<subviews.count, width: x, height: height))
        }
        return lines
    }
}
