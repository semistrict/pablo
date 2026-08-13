import Foundation

public struct PabloReviewWindowLayout: Equatable, Sendable {
    public static let preferredMinimumSize = CGSize(width: 640, height: 480)

    public let columns: Int
    public let rows: Int
    public let frames: [CGRect]

    public static func tiled(
        windowCount: Int,
        in bounds: CGRect,
        gap: CGFloat = 8
    ) -> PabloReviewWindowLayout {
        guard windowCount > 0, bounds.width > 0, bounds.height > 0 else {
            return PabloReviewWindowLayout(columns: 0, rows: 0, frames: [])
        }

        let gap = max(0, gap)
        let preferredAspectRatio: CGFloat = 1.55
        var bestColumns = 1
        var bestRows = windowCount
        var bestScore = CGFloat.greatestFiniteMagnitude

        for columns in 1...windowCount {
            let rows = Int(ceil(Double(windowCount) / Double(columns)))
            let width = max(
                1,
                (bounds.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            )
            let height = max(
                1,
                (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            )
            let widthDeficit = max(
                0,
                (preferredMinimumSize.width - width) / preferredMinimumSize.width
            )
            let heightDeficit = max(
                0,
                (preferredMinimumSize.height - height) / preferredMinimumSize.height
            )
            let minimumSizePenalty = 4 * (
                widthDeficit * widthDeficit + heightDeficit * heightDeficit
            )
            let aspectPenalty = abs(log((width / height) / preferredAspectRatio))
            let unusedCellPenalty = CGFloat(columns * rows - windowCount) * 0.02
            let score = minimumSizePenalty + aspectPenalty + unusedCellPenalty

            if score < bestScore || (score == bestScore && columns > bestColumns) {
                bestScore = score
                bestColumns = columns
                bestRows = rows
            }
        }

        let width = max(
            1,
            (bounds.width - gap * CGFloat(bestColumns + 1)) / CGFloat(bestColumns)
        )
        let height = max(
            1,
            (bounds.height - gap * CGFloat(bestRows + 1)) / CGFloat(bestRows)
        )
        let frames = (0..<windowCount).map { index in
            let row = index / bestColumns
            let column = index % bestColumns
            let windowsInRow = min(bestColumns, windowCount - row * bestColumns)
            let rowWidth = CGFloat(windowsInRow) * width +
                CGFloat(max(0, windowsInRow - 1)) * gap
            let rowStartX = bounds.midX - rowWidth / 2
            return CGRect(
                x: rowStartX + CGFloat(column) * (width + gap),
                y: bounds.maxY - gap - CGFloat(row + 1) * height - CGFloat(row) * gap,
                width: width,
                height: height
            )
        }

        return PabloReviewWindowLayout(
            columns: bestColumns,
            rows: bestRows,
            frames: frames
        )
    }
}
