import Foundation
import Testing
@testable import PabloCore

@Test func replayLoaderReturnsEveryAccessibilityStep() throws {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-replay-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let manifest = testManifest()
    try JSONEncoder().encode(manifest).write(
        to: packageURL.appendingPathComponent("manifest.json")
    )

    let root = AXNode(
        id: "root",
        parentID: nil,
        childIDs: [],
        role: "AXApplication",
        subrole: nil,
        title: "Example",
        label: nil,
        value: nil,
        identifier: nil,
        help: nil,
        enabled: true,
        focused: false,
        position: .init(x: 10, y: 20),
        size: .init(width: 400, height: 300)
    )
    let updatedRoot = AXNode(
        id: "root",
        parentID: nil,
        childIDs: [],
        role: "AXApplication",
        subrole: nil,
        title: "Updated Example",
        label: nil,
        value: nil,
        identifier: nil,
        help: nil,
        enabled: true,
        focused: true,
        position: .init(x: 12, y: 20),
        size: .init(width: 400, height: 300)
    )
    let records = [
        AXSnapshotRecord(
            schemaVersion: 3,
            timestampNs: 200_000_000,
            reason: "initial",
            kind: "full",
            application: testApplication,
            rootID: root.id,
            upserts: [root],
            removed: [],
            truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 3,
            timestampNs: 1_100_000_000,
            reason: "input:mouseUp",
            kind: "delta",
            application: testApplication,
            rootID: root.id,
            upserts: [updatedRoot],
            removed: [],
            truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 3,
            timestampNs: 1_500_000_000,
            reason: "periodic",
            kind: "delta",
            application: testApplication,
            rootID: root.id,
            upserts: [],
            removed: [root.id],
            truncated: false
        ),
    ]
    var accessibilityData = Data()
    for record in records {
        accessibilityData.append(try PabloProtobufCodec.encode(record))
    }
    try accessibilityData.write(to: packageURL.appendingPathComponent("accessibility.pb"))
    try Data().write(to: packageURL.appendingPathComponent("events.pb"))
    try writeTestWorkspace(to: packageURL)
    FileManager.default.createFile(
        atPath: packageURL.appendingPathComponent("video.mov").path,
        contents: Data()
    )

    let replay = try ReplayRecording.load(from: packageURL)

    #expect(replay.accessibilitySteps.count == 3)
    #expect(replay.accessibilitySteps[0].reference == "A11Y-001")
    #expect(replay.accessibilitySteps[1].reference == "A11Y-002")
    #expect(replay.accessibilitySteps[0].changedNodes.count == 1)
    #expect(replay.accessibilitySteps[0].nodes.count == 1)
    #expect(replay.accessibilitySteps[0].totalNodeCount == 1)
    #expect(replay.accessibilitySteps[0].nodes[0].frame == ReplayAccessibilityFrame(
        x: 10, y: 20, width: 400, height: 300
    ))
    let initialChanges = replay.accessibilitySteps[0].changes(from: nil)
    #expect(initialChanges.count == 1)
    #expect(initialChanges[0].kind == .appeared)
    let updatedChanges = replay.accessibilitySteps[1].changes(from: replay.accessibilitySteps[0])
    #expect(updatedChanges.count == 1)
    #expect(updatedChanges[0].kind == .updated)
    #expect(updatedChanges[0].changedProperties.contains("title"))
    #expect(updatedChanges[0].changedProperties.contains("focused"))
    #expect(updatedChanges[0].changedProperties.contains("frame"))
    let removedChanges = replay.accessibilitySteps[2].changes(from: replay.accessibilitySteps[1])
    #expect(removedChanges.count == 1)
    #expect(removedChanges[0].kind == .removed)
    #expect(replay.accessibilitySteps[2].removedNodeIDs == ["root"])
    #expect(replay.accessibilitySteps[2].totalNodeCount == 0)
    #expect(replay.accessibilitySteps[2].nodes.isEmpty)
    #expect(replay.videoTime(for: replay.accessibilitySteps[1]) == 1)
    #expect(replay.accessibilityStep(atVideoTime: 0)?.reference == "A11Y-001")
    #expect(replay.accessibilityStep(atVideoTime: 0.99)?.reference == "A11Y-001")
    #expect(replay.accessibilityStep(atVideoTime: 1)?.reference == "A11Y-002")
    #expect(replay.accessibilityStep(atVideoTime: 1.4)?.reference == "A11Y-003")
    let exactSecondFrameTime = replay.videoTime(for: replay.accessibilitySteps[1])
    #expect(replay.accessibilityStep(atVideoTime: exactSecondFrameTime)?.reference == "A11Y-002")

    let frameList = try CLI.frames(packageURL, json: false)
    #expect(frameList.contains("A11Y-001"))
    #expect(frameList.contains("A11Y-002"))
    let frame = try CLI.frame(
        reference: "A11Y-001",
        requestedURL: packageURL,
        changedOnly: false,
        json: false
    )
    #expect(frame.contains("Accessibility tree:"))
    #expect(frame.contains("AXApplication"))
}

@Test("Recordings with unsupported schema versions are rejected")
func unsupportedRecordingVersionsAreRejected() throws {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-unsupported-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let manifest = testManifest(schemaVersion: 2)
    try JSONEncoder().encode(manifest).write(
        to: packageURL.appendingPathComponent("manifest.json")
    )

    #expect(throws: RecordingError.self) {
        try ReplayRecording.load(from: packageURL)
    }
}

@Test("Interleaved application deltas materialize independently in a display recording")
func multiApplicationReplayKeepsTreesSeparate() throws {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-multi-app-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let secondApplication = RecordingApplication(
        id: "APP-002",
        pid: 84,
        bundleIdentifier: "example.second",
        name: "Second",
        firstSeenTimestampNs: 500_000_000,
        lastSeenTimestampNs: nil
    )
    var manifest = testManifest()
    manifest = RecordingManifest(
        schemaVersion: 3,
        startedAt: manifest.startedAt,
        endedAt: manifest.endedAt,
        durationNs: manifest.durationNs,
        scope: .init(kind: .display, selectedApplicationID: nil, selectedDisplayID: 1),
        displays: [],
        applications: [testApplication, secondApplication],
        capture: manifest.capture,
        files: manifest.files
    )
    try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent("manifest.json"))

    func node(_ id: String, _ title: String) -> AXNode {
        AXNode(
            id: id, parentID: nil, childIDs: [], role: "AXApplication", subrole: nil,
            title: title, label: nil, value: nil, identifier: nil, help: nil,
            enabled: true, focused: true, position: nil, size: nil
        )
    }
    let records = [
        AXSnapshotRecord(
            schemaVersion: 3, timestampNs: 100_000_000, reason: "initial", kind: "full",
            application: testApplication, rootID: "APP-001:root",
            upserts: [node("APP-001:root", "A one")], removed: [], truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 3, timestampNs: 600_000_000, reason: "appeared", kind: "full",
            application: secondApplication, rootID: "APP-002:root",
            upserts: [node("APP-002:root", "B one")], removed: [], truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 3, timestampNs: 1_100_000_000, reason: "input:keyDown", kind: "delta",
            application: testApplication, rootID: "APP-001:root",
            upserts: [node("APP-001:root", "A two")], removed: [], truncated: false
        ),
    ]
    var accessibilityData = Data()
    for record in records { accessibilityData.append(try PabloProtobufCodec.encode(record)) }
    try accessibilityData.write(to: packageURL.appendingPathComponent("accessibility.pb"))

    let workspaceRecords = [
        WorkspaceSnapshotRecord(
            schemaVersion: 3, timestampNs: 100_000_000, reason: "initial",
            frontmostApplicationID: testApplication.id, applications: [testApplication], windows: [],
            appearedApplicationIDs: [testApplication.id], removedApplicationIDs: [],
            appearedWindowIDs: [], removedWindowIDs: []
        ),
        WorkspaceSnapshotRecord(
            schemaVersion: 3, timestampNs: 600_000_000, reason: "app-switch",
            frontmostApplicationID: secondApplication.id,
            applications: [testApplication, secondApplication], windows: [],
            appearedApplicationIDs: [secondApplication.id], removedApplicationIDs: [],
            appearedWindowIDs: [], removedWindowIDs: []
        ),
    ]
    var workspaceData = Data()
    for record in workspaceRecords { workspaceData.append(try PabloProtobufCodec.encode(record)) }
    try workspaceData.write(to: packageURL.appendingPathComponent("workspace.pb"))
    try Data().write(to: packageURL.appendingPathComponent("events.pb"))
    try Data().write(to: packageURL.appendingPathComponent("video.mov"))

    let replay = try ReplayRecording.load(from: packageURL)
    let visible = replay.accessibilitySteps(atVideoTime: 1.1)
    #expect(visible.count == 2)
    #expect(visible.first(where: { $0.applicationID == "APP-001" })?.nodes.first?.title == "A two")
    #expect(visible.first(where: { $0.applicationID == "APP-002" })?.nodes.first?.title == "B one")
    #expect(replay.accessibilityStep(atVideoTime: 0.6)?.applicationID == "APP-002")
    #expect(replay.workspaceStep(atVideoTime: 0.6)?.appearedApplicationIDs == ["APP-002"])
    let workspaceOutput = try CLI.workspace(packageURL, json: false)
    #expect(workspaceOutput.contains("WKS-0002"))
    #expect(workspaceOutput.contains("frontmost=APP-002"))
    #expect(workspaceOutput.contains("appeared=APP-002"))
}
