import SwiftUI

/// Répartit des éléments en colonnes alignées, autant que la largeur disponible en permet.
///
/// Remplace `LazyVGrid`, qui ne supporte pas d'être dimensionné à sa hauteur naturelle
/// (`fixedSize`) : la mise en page de toute la fenêtre s'effondrait.
struct ColumnsLayout: Layout {
    var minColumnWidth: CGFloat = 280
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Largeur non précisée ou infinie (mesure de la taille idéale/maximale) : une seule colonne
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth(subviews)
        let grid = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: grid.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index % grid.columns
            let row = index / grid.columns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (grid.columnWidth + horizontalSpacing),
                y: bounds.minY + grid.rowOffsets[row]
            )
            subview.place(at: origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: grid.columnWidth, height: nil))
        }
    }

    // MARK: - Calcul

    private struct Grid {
        let columns: Int
        let columnWidth: CGFloat
        let rowOffsets: [CGFloat]
        let height: CGFloat
    }

    private func naturalWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Grid {
        guard !subviews.isEmpty else { return Grid(columns: 1, columnWidth: 0, rowOffsets: [], height: 0) }
        // Colonnes au moins aussi larges que le plus long libellé, et que minColumnWidth
        let itemWidth = max(minColumnWidth, naturalWidth(subviews))
        // Jamais plus étroit qu'une colonne : sinon, mesurées sur une largeur nulle, les cases
        // renvoient une hauteur démesurée (un caractère par ligne) et la fenêtre déborde.
        let width = width.isFinite ? max(width, itemWidth) : itemWidth
        let fitting = Int((width + horizontalSpacing) / (itemWidth + horizontalSpacing))
        let columns = max(1, min(subviews.count, fitting))
        let columnWidth = columns == 1
            ? width
            : (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns)

        let rowCount = (subviews.count + columns - 1) / columns
        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        for row in 0..<rowCount {
            offsets.append(y)
            let items = subviews[(row * columns)..<min(subviews.count, (row + 1) * columns)]
            let rowHeight = items
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            y += rowHeight + (row < rowCount - 1 ? verticalSpacing : 0)
        }
        return Grid(columns: columns, columnWidth: columnWidth, rowOffsets: offsets, height: y)
    }
}
