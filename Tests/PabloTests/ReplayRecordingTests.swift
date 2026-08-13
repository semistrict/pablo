import Foundation
import Testing
@testable import PabloCore

@Test func replayLoaderReturnsEveryAccessibilityStep() throws {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-replay-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let manifest = RecordingManifest(
        schemaVersion: 2,
        startedAt: "2026-08-11T16:20:09.844Z",
        endedAt: "2026-08-11T16:20:11.844Z",
        durationNs: 2_000_000_000,
        target: .init(pid: 42, bundleIdentifier: "example.app", name: "Example"),
        capture: .init(
            displayScale: 2,
            width: 100,
            height: 100,
            framesPerSecond: 30,
            firstFrameTimestampNs: 100_000_000
        ),
        files: [
            "video": "video.mov",
            "events": "events.pb",
            "accessibility": "accessibility.pb",
        ]
    )
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
            schemaVersion: 2,
            timestampNs: 200_000_000,
            reason: "initial",
            kind: "full",
            rootID: root.id,
            upserts: [root],
            removed: [],
            truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 2,
            timestampNs: 1_100_000_000,
            reason: "input:mouseUp",
            kind: "delta",
            rootID: root.id,
            upserts: [updatedRoot],
            removed: [],
            truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 2,
            timestampNs: 1_500_000_000,
            reason: "periodic",
            kind: "delta",
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
    let manifest = RecordingManifest(
        schemaVersion: 1,
        startedAt: "2026-08-11T16:20:09.844Z",
        endedAt: nil,
        durationNs: nil,
        target: .init(pid: 42, bundleIdentifier: "example.app", name: "Example"),
        capture: .init(
            displayScale: 2,
            width: 100,
            height: 100,
            framesPerSecond: 30,
            firstFrameTimestampNs: nil
        ),
        files: ["video": "video.mov", "events": "events.pb", "accessibility": "accessibility.pb"]
    )
    try JSONEncoder().encode(manifest).write(
        to: packageURL.appendingPathComponent("manifest.json")
    )

    #expect(throws: RecordingError.self) {
        try ReplayRecording.load(from: packageURL)
    }
}
