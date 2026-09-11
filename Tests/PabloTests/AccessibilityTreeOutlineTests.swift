import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@Test("Collapsed accessibility branches hide all descendants instead of promoting them to roots")
func accessibilityOutlineHonorsCollapsedBranches() {
    let step = outlineStep([
        outlineNode("root", children: ["branch", "sibling"]),
        outlineNode("branch", parent: "root", children: ["leaf"]),
        outlineNode("leaf", parent: "branch"),
        outlineNode("sibling", parent: "root")
    ])
    #expect(accessibilityTreeEntries(step: step, expandedNodeIDs: []).map(\.id) == ["root"])
    #expect(accessibilityTreeEntries(step: step, expandedNodeIDs: ["root"]).map(\.id) == ["root", "branch", "sibling"])
    let expanded = accessibilityTreeEntries(step: step, expandedNodeIDs: ["root", "branch"])
    #expect(expanded.map(\.id) == ["root", "branch", "leaf", "sibling"])
    #expect(expanded.map(\.depth) == [0, 1, 2, 1])
    #expect(accessibilityTreeEntries(step: step, expandedNodeIDs: ["branch"]).map(\.id) == ["root"])
}

@Test("Disconnected accessibility components stay reachable without duplicating cyclic nodes")
func accessibilityOutlineRetainsDisconnectedNodes() {
    let step = outlineStep([
        outlineNode("root", children: ["hidden"]), outlineNode("hidden", parent: "root"),
        outlineNode("orphan", parent: "missing", children: ["orphan-child"]),
        outlineNode("orphan-child", parent: "orphan"),
        outlineNode("cycle-a", parent: "cycle-b", children: ["cycle-b"]),
        outlineNode("cycle-b", parent: "cycle-a", children: ["cycle-a"])
    ])
    #expect(accessibilityTreeEntries(step: step, expandedNodeIDs: []).map(\.id) == ["root", "orphan", "cycle-a"])
    let all = accessibilityTreeEntries(step: step, expandedNodeIDs: Set(step.nodes.map(\.id)))
    #expect(Set(all.map(\.id)) == Set(step.nodes.map(\.id)))
    #expect(all.count == step.nodes.count)
}

private func outlineNode(_ id: String, parent: String? = nil, children: [String] = []) -> ReplayAccessibilityNode {
    .init(AXNode(id: id, parentID: parent, childIDs: children, role: "AXGroup", subrole: nil,
        title: id, label: nil, value: nil, identifier: nil, help: nil, enabled: true,
        focused: false, position: nil, size: nil), depth: 0)
}

private func outlineStep(_ nodes: [ReplayAccessibilityNode]) -> ReplayAccessibilityStep {
    .init(id: 0, timestampNs: 0, reason: "initial", kind: "full", applicationID: "app",
        applicationName: "Fixture", applicationBundleIdentifier: nil, applicationPID: 1,
        rootID: "root", nodes: nodes, changedNodes: [], changedNodeIDs: [], removedNodeIDs: [],
        totalNodeCount: nodes.count, truncated: false)
}
