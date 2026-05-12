import SwiftUI

/// FlowLayout is a custom SwiftUI `Layout` that arranges child views
/// left-to-right, wrapping onto a new row whenever the next item would exceed
/// the available width — similar to CSS `flex-wrap: wrap`. Each row is as tall
/// as its tallest child, and `spacing` is applied both between items on the
/// same row and between rows. This is used to display variable-width label
/// badge chips that cannot be laid out with a fixed-column grid.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Does a dry run over all subviews to calculate the total height needed.
    /// It simulates placing items left-to-right; when adding the next item
    /// would exceed maxWidth, it starts a new row and accumulates that row's
    /// height. Returns the full bounding size so the parent knows how much
    /// space to allocate.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight

        return CGSize(width: maxWidth, height: height)
    }

    /// Does the real placement pass using the same wrapping logic, but this
    /// time calls subview.place(at:) to set each child's actual position within
    /// the given bounds rect.
    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
