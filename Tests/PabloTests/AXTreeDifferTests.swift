import XCTest
@testable import PabloCore

final class AXTreeDifferTests: XCTestCase {
    func testDiffReportsChangedAddedAndRemovedNodes() {
        let oldRoot = node(id: "root", title: "Before", children: ["removed"])
        let removed = node(id: "removed", title: "Old")
        let newRoot = node(id: "root", title: "After", children: ["added"])
        let added = node(id: "added", title: "New")

        let diff = AXTreeDiffer.diff(
            previous: [oldRoot.id: oldRoot, removed.id: removed],
            current: [newRoot.id: newRoot, added.id: added]
        )

        XCTAssertEqual(diff.upserts.map(\.id), ["added", "root"])
        XCTAssertEqual(diff.removed, ["removed"])
    }

    func testDiffOmitsUnchangedNodes() {
        let root = node(id: "root", title: "Same")
        let diff = AXTreeDiffer.diff(previous: [root.id: root], current: [root.id: root])
        XCTAssertTrue(diff.upserts.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    private func node(id: String, title: String, children: [String] = []) -> AXNode {
        AXNode(
            id: id,
            parentID: nil,
            childIDs: children,
            role: "AXButton",
            subrole: nil,
            title: title,
            label: nil,
            value: nil,
            identifier: nil,
            help: nil,
            enabled: true,
            focused: false,
            position: nil,
            size: nil
        )
    }
}
