import Foundation
import PabloCore
import Testing

@Test("Two review windows arrange side by side")
func twoReviewWindowsArrangeSideBySide() {
    let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let layout = PabloReviewWindowLayout.tiled(windowCount: 2, in: bounds)

    #expect(layout.columns == 2)
    #expect(layout.rows == 1)
    #expect(layout.frames.count == 2)
    #expect(layout.frames[0].maxX < layout.frames[1].minX)
}

@Test("Dense review workspaces use a balanced grid")
func denseReviewWorkspacesUseBalancedGrid() {
    let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let layout = PabloReviewWindowLayout.tiled(windowCount: 5, in: bounds)

    #expect(layout.columns == 3)
    #expect(layout.rows == 2)
    #expect(layout.frames.count == 5)
    #expect(layout.frames.allSatisfy { bounds.contains($0) })
}

@Test("Review window layout preserves display coordinates")
func reviewWindowLayoutPreservesDisplayCoordinates() {
    let bounds = CGRect(x: -1_920, y: 120, width: 1_920, height: 1_080)
    let layout = PabloReviewWindowLayout.tiled(windowCount: 4, in: bounds)

    #expect(layout.columns == 2)
    #expect(layout.rows == 2)
    #expect(layout.frames.allSatisfy { bounds.contains($0) })
    #expect(layout.frames.allSatisfy { $0.maxX <= 0 && $0.minY >= 120 })
}

@Test("Review window layout handles an empty workspace")
func reviewWindowLayoutHandlesEmptyWorkspace() {
    let layout = PabloReviewWindowLayout.tiled(
        windowCount: 0,
        in: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    #expect(layout.columns == 0)
    #expect(layout.rows == 0)
    #expect(layout.frames.isEmpty)
}
