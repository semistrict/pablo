import Foundation
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
    let application = testApplication

    let first = history.append(
        AXTreeSnapshot(
            rootID: "root",
            nodes: ["root": firstRoot, "child": child],
            truncated: false
        ),
        timestampNs: 10,
        reason: "live:frames",
        application: application
    )
    let second = history.append(
        AXTreeSnapshot(rootID: "root", nodes: ["root": secondRoot], truncated: false),
        timestampNs: 20,
        reason: "live:frames",
        application: application
    )
    let third = history.append(
        AXTreeSnapshot(rootID: "root", nodes: ["root": secondRoot], truncated: false),
        timestampNs: 30,
        reason: "live:frames",
        application: application
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

@Test("Live frame references cannot alias observations in a replacement session")
func liveReferencesRejectReplacementSessions() throws {
    var first = LiveAccessibilityHistory()
    var replacement = LiveAccessibilityHistory()
    let node = liveNode(id: "root", role: "AXApplication", title: "Fixture")
    let tree = AXTreeSnapshot(rootID: "root", nodes: ["root": node], truncated: false)
    let old = first.append(tree, timestampNs: 10, reason: "initial", application: testApplication)
    let fresh = replacement.append(tree, timestampNs: 20, reason: "initial", application: testApplication)
    let oldReference = first.reference(for: old)
    #expect(oldReference != replacement.reference(for: fresh))
    #expect(try first.step(reference: oldReference).timestampNs == 10)
    #expect(throws: (any Error).self) { try replacement.step(reference: oldReference) }
    #expect(throws: (any Error).self) { try replacement.step(reference: "A11Y-001") }
}

@Test("Live event cursors expose incremental pages and retention gaps without repeating old events")
func liveEventCursorPagesAndRetention() throws {
    var history = LiveEventHistory(maximumEvents: 3)
    func event(_ time: UInt64) -> InputEventRecord {
        .init(schemaVersion: 3, timestampNs: time, type: "mouseDown", targetPID: 42,
              applicationID: "APP-001", windowID: nil, x: nil, y: nil, deltaX: nil, deltaY: nil,
              keyCode: nil, text: nil, flags: 0, button: 0, clickCount: 1, automationAction: nil)
    }
    history.append(event(1)); history.append(event(2)); history.append(event(3))
    let first = try history.page(after: 0, limit: 2)
    #expect(first.events.map(\.sequence) == [1, 2])
    #expect(first.nextCursor == 2)
    #expect(!first.resyncRequired)
    history.append(event(4))
    let next = try history.page(after: first.nextCursor, limit: 2)
    #expect(next.events.map(\.sequence) == [3, 4])
    #expect(next.nextCursor == 4)
    #expect(!next.resyncRequired)
    let gap = try history.page(after: 0, limit: 3)
    #expect(gap.resyncRequired)
    #expect(gap.oldestSequence == 2)
    let empty = try history.page(after: 4, limit: 2)
    #expect(empty.events.isEmpty)
    #expect(empty.nextCursor == 4)
    #expect(throws: (any Error).self) { try history.page(after: 5, limit: 2) }
    #expect(throws: (any Error).self) { try history.page(after: 0, limit: -1) }
}

@Test("Explicit live window and frame targets require their inspection session")
func liveWindowTargetsRequireSessionContext() throws {
    let sessionID = UUID()
    try PabloLiveApplicationTarget(pid: 42, sessionID: sessionID, windowID: "window-1", frameReference: "LIVE-\(sessionID.uuidString)/A11Y-001").validate()
    #expect(throws: RecordingError.self) {
        try PabloLiveApplicationTarget(pid: 42, windowID: "window-1").validate()
    }
    #expect(throws: RecordingError.self) {
        try PabloLiveApplicationTarget(pid: 42, sessionID: sessionID, windowID: "").validate()
    }
    #expect(throws: RecordingError.self) {
        try PabloLiveApplicationTarget(pid: 42, frameReference: "A11Y-001").validate()
    }
}

@Test("Live frames retain observed accessibility action capabilities and reject stale frame preconditions")
func liveFrameCapabilitiesAndFreshness() throws {
    var history = LiveAccessibilityHistory()
    var button = liveNode(id: "button", role: "AXButton", title: "Save")
    button.actions = ["AXPress", "AXShowMenu"]
    let first = history.append(.init(rootID: "button", nodes: ["button": button], truncated: false), timestampNs: 1, reason: "inspect", application: testApplication)
    #expect(first.nodes.first?.actions == ["AXPress", "AXShowMenu"])
    try history.requireCurrentFrame(history.reference(for: first))
    button.actions = []
    let second = history.append(.init(rootID: "button", nodes: ["button": button], truncated: false), timestampNs: 2, reason: "inspect", application: testApplication)
    #expect(second.changedNodes.first?.actions?.isEmpty == true)
    #expect(throws: RecordingError.self) { try history.requireCurrentFrame(history.reference(for: first)) }
    try history.requireCurrentFrame(history.reference(for: second))
}

@Test("Invalid live cursors fail before observation or its privacy checks start")
func invalidLiveCursorDoesNotStartObservation() throws {
    var accessChecks = 0
    let session = LiveInspectionSession(target: .init(pid: getpid(), bundleIdentifier: nil, name: "Fixture"), requireEventAccess: {
        accessChecks += 1
        throw RecordingError.permission("Fixture never grants input access")
    })
    do {
        _ = try session.readEvents(limit: 10, after: UInt64.max, includeText: nil)
        Issue.record("The invalid cursor must be rejected")
    } catch {
        guard case RecordingError.usage = error else {
            Issue.record("Cursor validation must precede permission checks: \(error)")
            return
        }
    }
    #expect(accessChecks == 0)
    #expect(session.observationState == nil)
    #expect(throws: RecordingError.self) {
        _ = try session.readEvents(limit: 10, after: 0, includeText: false)
    }
    #expect(accessChecks == 1)
    #expect(session.observationState == nil)
}
