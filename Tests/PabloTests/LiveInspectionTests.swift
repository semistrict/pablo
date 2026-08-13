import Testing
@testable import PabloCore

@Test("Live accessibility history keeps stable frame references and bounded snapshots")
func liveAccessibilityHistoryIsStableAndBounded() throws {
    var history = LiveAccessibilityHistory(maximumSteps: 2)
    let child = liveNode(id: "child", parentID: "root", role: "AXButton", title: "Save")
    let firstRoot = liveNode(
        id: "root",
        childIDs: ["child"],
        role: "AXApplication",
        title: "Before"
    )
    let secondRoot = liveNode(id: "root", role: "AXApplication", title: "After")

    let first = history.append(
        AXTreeSnapshot(
            rootID: "root",
            nodes: ["root": firstRoot, "child": child],
            truncated: false
        ),
        timestampNs: 10,
        reason: "live:frames"
    )
    let second = history.append(
        AXTreeSnapshot(rootID: "root", nodes: ["root": secondRoot], truncated: false),
        timestampNs: 20,
        reason: "live:frames"
    )
    let third = history.append(
        AXTreeSnapshot(rootID: "root", nodes: ["root": secondRoot], truncated: false),
        timestampNs: 30,
        reason: "live:frames"
    )

    #expect(first.reference == "A11Y-001")
    #expect(first.kind == "full")
    #expect(first.totalNodeCount == 2)
    #expect(second.reference == "A11Y-002")
    #expect(second.kind == "delta")
    #expect(second.changedNodeIDs == ["root"])
    #expect(second.removedNodeIDs == ["child"])
    #expect(third.reference == "A11Y-003")
    #expect(third.changedNodeIDs.isEmpty)
    #expect(history.steps.map(\.reference) == ["A11Y-002", "A11Y-003"])
    #expect(history.step(id: 0)?.reference == nil)
    #expect(history.step(id: 1)?.reference == "A11Y-002")
    #expect(history.nextStepID == 3)
}

private func liveNode(
    id: String,
    parentID: String? = nil,
    childIDs: [String] = [],
    role: String,
    title: String
) -> AXNode {
    AXNode(
        id: id,
        parentID: parentID,
        childIDs: childIDs,
        role: role,
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
