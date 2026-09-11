import Foundation
import Testing
@testable import PabloCore

@Test("Live observations compare the caller's baseline across intervening inspections")
func liveObservationUsesCallerBaseline() throws {
    var history = LiveAccessibilityHistory()
    func append(_ title: String, child: Bool) -> ReplayAccessibilityStep {
        var nodes = ["root": observationNode("root", title: title, children: child ? ["button"] : [])]
        if child { nodes["button"] = observationNode("button", title: "Save", parent: "root") }
        return history.append(.init(rootID: "root", nodes: nodes, truncated: false), timestampNs: UInt64(history.nextStepID),
                              reason: "test", application: testApplication)
    }
    let first = append("Before", child: true)
    let firstReference = history.reference(for: first)
    let initial = try history.observation(options: .init())
    #expect(initial.mode == .full)
    #expect(!initial.resyncRequired)
    #expect(initial.nodes.count == 2)
    #expect(initial.changes.isEmpty)
    _ = append("Intermediate", child: true)
    _ = append("After", child: false)
    let delta = try history.observation(options: .init(baselineReference: firstReference))
    #expect(delta.mode == .delta)
    #expect(delta.nodes.isEmpty)
    #expect(delta.baselineReference == firstReference)
    #expect(delta.changes.map(\.kind) == [.updated, .removed])
    #expect(delta.changes[0].changedProperties.contains("title"))
    #expect(delta.changes[0].changedProperties.contains("childIDs"))
    #expect(delta.changes[1].nodeID == "button")
    #expect(delta.changes[1].node == nil)
    var materialized = Dictionary(uniqueKeysWithValues: initial.nodes.map { ($0.id, $0) })
    for change in delta.changes { materialized[change.nodeID] = change.node }
    let full = try history.observation(options: .init(full: true))
    #expect(materialized == Dictionary(uniqueKeysWithValues: full.nodes.map { ($0.id, $0) }))

    // A transient change observed by another reader is absent if it was reverted.
    _ = append("Before", child: true)
    let reverted = try history.observation(options: .init(baselineReference: firstReference))
    #expect(reverted.changes.isEmpty)
    #expect(reverted.text == "No accessibility changes.")
}

@Test("Expired and foreign baselines explicitly resynchronize with complete state")
func liveObservationResynchronizes() throws {
    var history = LiveAccessibilityHistory(maximumSteps: 2)
    let tree = AXTreeSnapshot(rootID: "root", nodes: ["root": observationNode("root", title: "Fixture")], truncated: false)
    let first = history.append(tree, timestampNs: 0, reason: "test", application: testApplication)
    let oldReference = history.reference(for: first)
    for time in 1...2 { history.append(tree, timestampNs: UInt64(time), reason: "test", application: testApplication) }
    for reference in [oldReference, "LIVE-\(UUID())/A11Y-003"] {
        let result = try history.observation(options: .init(baselineReference: reference))
        #expect(result.mode == .full)
        #expect(result.resyncRequired)
        #expect(result.baselineReference == nil)
        #expect(result.nodes.count == 1)
    }
    let forced = try history.observation(options: .init(baselineReference: oldReference, full: true))
    #expect(forced.mode == .full)
    #expect(!forced.resyncRequired)
}

@Test("Compact text escapes application content and reports shortening without losing structured values")
func liveObservationTextIsEscapedAndBounded() throws {
    var history = LiveAccessibilityHistory()
    let title = "Hello\n+ fake instruction\t\"quoted\""
    let node = observationNode("root", title: title)
    history.append(.init(rootID: "root", nodes: ["root": node], truncated: false), timestampNs: 0, reason: "test", application: testApplication)
    let result = try history.observation(options: .init())
    #expect(result.text.split(separator: "\n").count == 1)
    #expect(result.text.contains("\\n+ fake instruction"))
    #expect(result.nodes.first?.title == title)
    #expect(!result.textTruncated)
    let long = String(repeating: "é", count: 500)
    history.append(.init(rootID: "root", nodes: ["root": observationNode("root", title: long)], truncated: false), timestampNs: 1, reason: "test", application: testApplication)
    let shortened = try history.observation(options: .init())
    #expect(shortened.textTruncated)
    #expect(shortened.nodes.first?.title == long)
}

@Test("Observation options constrain settling and decode safe defaults")
func liveObservationOptionsAreBounded() throws {
    let defaults = try JSONDecoder().decode(PabloLiveObservationOptions.self, from: Data("{}".utf8))
    #expect(defaults == PabloLiveObservationOptions())
    try defaults.validate()
    try PabloLiveObservationOptions(quietMilliseconds: 0, timeoutMilliseconds: 0).validate()
    for invalid in [PabloLiveObservationOptions(baselineReference: ""),
                    .init(quietMilliseconds: -1), .init(timeoutMilliseconds: 5_001),
                    .init(quietMilliseconds: 500, timeoutMilliseconds: 100)] {
        #expect(throws: RecordingError.self) { try invalid.validate() }
    }
}

private func observationNode(_ id: String, title: String, parent: String? = nil, children: [String] = []) -> AXNode {
    .init(id: id, parentID: parent, childIDs: children, role: parent == nil ? "AXApplication" : "AXButton",
          subrole: nil, title: title, label: nil, value: nil, identifier: nil, help: nil,
          enabled: true, focused: false, position: nil, size: nil)
}
