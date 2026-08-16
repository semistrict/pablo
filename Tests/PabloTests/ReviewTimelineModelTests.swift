import Foundation
import Testing
@testable import PabloCore

@Test("The review timeline builds ordered evidence lanes around one clock")
func timelineBuildsOrderedEvidenceLanesAroundOnePlayhead() throws {
    let packageURL = try makeTimelineRecording()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let replay = try ReplayRecording.load(from: packageURL)
    let items = replay.timelineItems()

    #expect(replay.inputEvents.count == 2)
    #expect(items.contains(where: { $0.lane == .workspace }))
    #expect(items.contains(where: { $0.lane == .input }))
    #expect(items.contains(where: { $0.lane == .accessibility }))
    #expect(items.map(\.timestampNs) == items.map(\.timestampNs).sorted())
    #expect(items.allSatisfy {
        replay.videoTime(forTimestampNs: $0.timestampNs) >= 0
    })
}

@Test("Dense timeline events cluster per lane and separate as zoom increases")
func denseEventsClusterAndExpandWithZoom() throws {
    let packageURL = try makeTimelineRecording()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let replay = try ReplayRecording.load(from: packageURL)
    let range = UInt64(300_000_000)...UInt64(400_000_000)

    let narrow = replay.timelineClusters(lane: .input, visibleTimestampRange: range, trackWidth: 8)
    let wide = replay.timelineClusters(lane: .input, visibleTimestampRange: range, trackWidth: 800)

    #expect(narrow.count == 1)
    #expect(narrow[0].memberCount == 2)
    #expect(wide.count == 2)
    #expect(wide.flatMap(\.items).map(\.id).sorted() == narrow.flatMap(\.items).map(\.id).sorted())
}

@Test("Meaningful timeline navigation data skips incidental accessibility snapshots")
func meaningfulChangeNavigationSkipsIncidentalSnapshots() throws {
    let packageURL = try makeTimelineRecording()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let replay = try ReplayRecording.load(from: packageURL)

    let accessibility = replay.timelineItems().filter { $0.lane == .accessibility }
    #expect(accessibility.count == 2)
    #expect(accessibility[0].importance == .technical)
    #expect(accessibility[1].importance == .meaningful)
    #expect(replay.meaningfulTimelineItems().contains(where: {
        $0.id == accessibility[1].id
    }))
    #expect(!replay.meaningfulTimelineItems().contains(where: {
        $0.id == accessibility[0].id
    }))
}

@Test("Input evidence becomes semantic interactions without crossing app or window identity")
func inputEventsBecomeTargetScopedInteractions() throws {
    let packageURL = try makeTimelineRecording(events: [
        timelineInput(100, "mouseDown", windowID: "APP-001:WIN-1", x: 10, y: 10, button: 0),
        timelineInput(120, "mouseUp", windowID: "APP-001:WIN-1", x: 11, y: 11, button: 0),
        timelineInput(200, "mouseDown", windowID: "APP-001:WIN-1", x: 10, y: 10, button: 0),
        timelineInput(220, "mouseDrag", windowID: "APP-001:WIN-1", x: 30, y: 30, button: 0),
        timelineInput(250, "mouseUp", windowID: "APP-001:WIN-1", x: 50, y: 50, button: 0),
        timelineInput(300, "scroll", windowID: "APP-001:WIN-1", deltaY: -2),
        timelineInput(400, "scroll", windowID: "APP-001:WIN-1", deltaY: -3),
        timelineInput(500, "scroll", windowID: "APP-001:WIN-2", deltaY: -4),
        timelineInput(600, "keyDown", windowID: "APP-001:WIN-1", keyCode: 0, text: "a"),
        timelineInput(650, "keyDown", windowID: "APP-001:WIN-1", keyCode: 11, text: "b"),
        timelineInput(700, "keyDown", windowID: "APP-001:WIN-2", keyCode: 8, text: "c"),
        timelineInput(800, "mouseMove", windowID: "APP-001:WIN-1", x: 1, y: 1),
        timelineInput(820, "mouseMove", windowID: "APP-001:WIN-1", x: 2, y: 2),
    ])
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let items = try ReplayRecording.load(from: packageURL).timelineItems()
        .filter { $0.lane == .input }

    #expect(items.filter { $0.title == "Click" }.count == 1)
    #expect(items.first(where: { $0.title == "Click" })?.memberCount == 2)
    #expect(items.filter { $0.title == "Drag" }.count == 1)
    #expect(items.first(where: { $0.title == "Drag" })?.memberCount == 3)
    #expect(items.filter { $0.title == "Scroll down" }.map(\.memberCount).sorted() == [1, 2])
    #expect(items.filter { $0.title.hasPrefix("Typed") }.map(\.memberCount).sorted() == [1, 2])
    #expect(items.first(where: { $0.title == "Pointer movement" })?.memberCount == 2)
    #expect(items.first(where: { $0.title == "Pointer movement" })?.importance == .technical)
    #expect(items.flatMap(\.references).count == 13)
}

@Test("Automation requests and outcomes are one provenance-preserving timeline item")
func automationRecordsPairByActionID() throws {
    let actionID = UUID()
    let failedActionID = UUID()
    let caller = PabloAutomationCaller(
        displayName: "Agent Host",
        applicationIdentifier: "com.example.agent",
        developerName: "Example Developer",
        developerTeamIdentifier: "TEAM123",
        verified: true
    )
    let request = PabloLiveActionRequest(kind: .click, target: .init(appName: "Example"))
    let succeeded = [
        PabloAutomationActionTrace(
            actionID: actionID, phase: .requested, request: request, caller: caller,
            transport: "http+unix", recordingWasPaused: false
        ),
        PabloAutomationActionTrace(
            actionID: actionID, phase: .succeeded, request: request, caller: caller,
            transport: "http+unix", recordingWasPaused: false
        ),
    ]
    let failed = PabloAutomationActionTrace(
        actionID: failedActionID, phase: .requested, request: request, caller: caller,
        transport: "http+unix", recordingWasPaused: true
    )
    let events = [
        InputEventRecord.automationAction(
            timestampNs: 100, targetPID: 42, applicationID: testApplication.id, trace: succeeded[0]
        ),
        InputEventRecord.automationAction(
            timestampNs: 140, targetPID: 42, applicationID: testApplication.id, trace: succeeded[1]
        ),
        InputEventRecord.automationAction(
            timestampNs: 200, targetPID: 42, applicationID: testApplication.id, trace: failed
        ),
    ]
    let packageURL = try makeTimelineRecording(events: events)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let items = try ReplayRecording.load(from: packageURL).timelineItems()
        .filter { $0.lane == .automation }

    #expect(items.count == 2)
    #expect(items.first(where: { $0.id == "automation:\(actionID.uuidString)" })?.title == "Click succeeded")
    #expect(items.first(where: { $0.id == "automation:\(actionID.uuidString)" })?.timestampNs == 100)
    #expect(items.first(where: { $0.id == "automation:\(actionID.uuidString)" })?.endTimestampNs == 140)
    #expect(items.first(where: { $0.id == "automation:\(actionID.uuidString)" })?.memberCount == 1)
    #expect(items.first(where: { $0.id == "automation:\(actionID.uuidString)" })?.subtitle?.contains("Example Developer") == true)
    #expect(items.first(where: { $0.id == "automation:\(failedActionID.uuidString)" })?.importance == .warning)
    #expect(items.first(where: { $0.id == "automation:\(failedActionID.uuidString)" })?.subtitle?.contains("while paused") == true)
    #expect(try ReplayRecording.load(from: packageURL).timelineItems().filter { $0.lane == .input }.isEmpty)
}

@Test("Workspace timeline omits no-op snapshots but exposes semantic window mutations")
func workspaceTimelineDetectsSemanticWindowMutations() throws {
    let originalWindow = RecordingWindow(
        id: "APP-001:WIN-7", applicationID: testApplication.id, systemWindowID: 7,
        title: "Document", frame: .init(x: 10, y: 20, width: 300, height: 200),
        layer: 0, isOnScreen: true, zOrder: 0
    )
    let movedWindow = RecordingWindow(
        id: originalWindow.id, applicationID: testApplication.id, systemWindowID: 7,
        title: "Renamed", frame: .init(x: 20, y: 20, width: 300, height: 200),
        layer: 0, isOnScreen: true, zOrder: 4
    )
    let workspace = [
        timelineWorkspace(100, reason: "initial", window: originalWindow, appeared: [originalWindow.id]),
        timelineWorkspace(200, reason: "periodic", window: originalWindow),
        timelineWorkspace(300, reason: "periodic", window: movedWindow),
    ]
    let packageURL = try makeTimelineRecording(events: [], workspace: workspace)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let items = try ReplayRecording.load(from: packageURL).timelineItems()
        .filter { $0.lane == .workspace }

    #expect(items.count == 2)
    #expect(items.map(\.timestampNs) == [100, 300])
    #expect(items[1].title == "\u{201c}Renamed\u{201d} changed")
    #expect(items[1].subtitle == "1 window changes")
    #expect(items[1].importance == .meaningful)
}

@Test("Cached timeline items can be clustered without rebuilding evidence semantics")
func cachedTimelineItemsCanBeClustered() throws {
    let packageURL = try makeTimelineRecording()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let replay = try ReplayRecording.load(from: packageURL)
    let items = replay.timelineItems()
    let range = UInt64(300_000_000)...UInt64(400_000_000)

    let cached = replay.timelineClusters(
        from: items,
        lane: .input,
        visibleTimestampRange: range,
        trackWidth: 8
    )
    let convenience = replay.timelineClusters(
        lane: .input,
        visibleTimestampRange: range,
        trackWidth: 8
    )

    #expect(cached.map(\.id) == convenience.map(\.id))
    #expect(cached.flatMap(\.items).map(\.id) == convenience.flatMap(\.items).map(\.id))
}

private func makeTimelineRecording(
    events suppliedEvents: [InputEventRecord]? = nil,
    workspace suppliedWorkspace: [WorkspaceSnapshotRecord]? = nil
) throws -> URL {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-timeline-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(testManifest()).write(to: packageURL.appendingPathComponent("manifest.json"))

    let defaultEvents = [
        InputEventRecord(
            schemaVersion: 3, timestampNs: 300_000_000, type: "mouseUp",
            targetPID: 42, applicationID: testApplication.id, windowID: nil,
            x: 10, y: 10, deltaX: nil, deltaY: nil, keyCode: nil, text: nil,
            flags: 0, button: 0, clickCount: 1, automationAction: nil
        ),
        InputEventRecord(
            schemaVersion: 3, timestampNs: 310_000_000, type: "keyDown",
            targetPID: 42, applicationID: testApplication.id, windowID: nil,
            x: nil, y: nil, deltaX: nil, deltaY: nil, keyCode: 0, text: "a",
            flags: 0, button: nil, clickCount: nil, automationAction: nil
        ),
    ]
    var eventData = Data()
    for event in suppliedEvents ?? defaultEvents { eventData.append(try PabloProtobufCodec.encode(event)) }
    try eventData.write(to: packageURL.appendingPathComponent("events.pb"))

    func node(title: String, focused: Bool) -> AXNode {
        AXNode(
            id: "root", parentID: nil, childIDs: [], role: "AXApplication", subrole: nil,
            title: title, label: nil, value: nil, identifier: nil, help: nil,
            enabled: true, focused: focused, position: nil, size: nil
        )
    }
    let snapshots = [
        AXSnapshotRecord(
            schemaVersion: 3, timestampNs: 200_000_000, reason: "initial", kind: "full",
            application: testApplication, rootID: "root", upserts: [node(title: "Example", focused: false)],
            removed: [], truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 3, timestampNs: 900_000_000, reason: "input:keyDown", kind: "delta",
            application: testApplication, rootID: "root", upserts: [node(title: "Changed", focused: true)],
            removed: [], truncated: false
        ),
    ]
    var accessibilityData = Data()
    for snapshot in snapshots { accessibilityData.append(try PabloProtobufCodec.encode(snapshot)) }
    try accessibilityData.write(to: packageURL.appendingPathComponent("accessibility.pb"))
    if let suppliedWorkspace {
        var workspaceData = Data()
        for step in suppliedWorkspace { workspaceData.append(try PabloProtobufCodec.encode(step)) }
        try workspaceData.write(to: packageURL.appendingPathComponent("workspace.pb"))
    } else {
        try writeTestWorkspace(to: packageURL)
    }
    try Data().write(to: packageURL.appendingPathComponent("video.mov"))
    return packageURL
}

private func timelineInput(
    _ milliseconds: UInt64,
    _ type: String,
    windowID: String? = nil,
    x: Double? = nil,
    y: Double? = nil,
    deltaY: Double? = nil,
    keyCode: Int64? = nil,
    text: String? = nil,
    button: Int64? = nil
) -> InputEventRecord {
    InputEventRecord(
        schemaVersion: 3,
        timestampNs: milliseconds * 1_000_000,
        type: type,
        targetPID: 42,
        applicationID: testApplication.id,
        windowID: windowID,
        x: x,
        y: y,
        deltaX: nil,
        deltaY: deltaY,
        keyCode: keyCode,
        text: text,
        flags: 0,
        button: button,
        clickCount: nil,
        automationAction: nil
    )
}

private func timelineWorkspace(
    _ timestampNs: UInt64,
    reason: String,
    window: RecordingWindow,
    appeared: [String] = []
) -> WorkspaceSnapshotRecord {
    WorkspaceSnapshotRecord(
        schemaVersion: 3,
        timestampNs: timestampNs,
        reason: reason,
        frontmostApplicationID: testApplication.id,
        applications: [testApplication],
        windows: [window],
        appearedApplicationIDs: [],
        removedApplicationIDs: [],
        appearedWindowIDs: appeared,
        removedWindowIDs: []
    )
}
