import SwiftUI

/// A simple left-to-right layout that wraps its subviews onto new lines when
/// they run out of horizontal space — used for the "See also" chip cloud.
/// Requires iOS 16 / macOS 13 (the `Layout` protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.rowHeight } ?? 0
        let width = rows.map { $0.maxX }.max() ?? 0
        rows.removeAll()
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size)
                )
            }
        }
    }

    private struct Item { let index: Int; let x: CGFloat }
    private struct Row { var items: [Item] = []; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var maxX: CGFloat = 0 }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                current.y = y
                rows.append(current)
                y += current.rowHeight + spacing
                current = Row()
                x = 0
            }
            current.items.append(Item(index: index, x: x))
            current.rowHeight = max(current.rowHeight, size.height)
            x += size.width + spacing
            current.maxX = max(current.maxX, x - spacing)
        }
        if !current.items.isEmpty {
            current.y = y
            rows.append(current)
        }
        return rows
    }
}
