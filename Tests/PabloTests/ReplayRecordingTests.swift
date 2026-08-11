import Foundation
import Testing
@testable import PabloCore

@Test func replayLoaderReturnsEveryAccessibilityStep() throws {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-replay-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    let manifest = RecordingManifest(
        schemaVersion: 1,
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
            "events": "events.jsonl",
            "accessibility": "accessibility.jsonl",
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
        position: nil,
        size: nil
    )
    let records = [
        AXSnapshotRecord(
            schemaVersion: 1,
            timestampNs: 200_000_000,
            reason: "initial",
            kind: "full",
            rootID: root.id,
            upserts: [root],
            removed: [],
            truncated: false
        ),
        AXSnapshotRecord(
            schemaVersion: 1,
            timestampNs: 1_100_000_000,
            reason: "input:mouseUp",
            kind: "delta",
            rootID: root.id,
            upserts: [],
            removed: [root.id],
            truncated: false
        ),
    ]
    let encoder = JSONEncoder()
    var accessibilityData = Data()
    for record in records {
        accessibilityData.append(try encoder.encode(record))
        accessibilityData.append(0x0A)
    }
    try accessibilityData.write(to: packageURL.appendingPathComponent("accessibility.jsonl"))
    FileManager.default.createFile(
        atPath: packageURL.appendingPathComponent("video.mov").path,
        contents: Data()
    )

    let replay = try ReplayRecording.load(from: packageURL)

    #expect(replay.accessibilitySteps.count == 2)
    #expect(replay.accessibilitySteps[0].reference == "A11Y-001")
    #expect(replay.accessibilitySteps[1].reference == "A11Y-002")
    #expect(replay.accessibilitySteps[0].changedNodes.count == 1)
    #expect(replay.accessibilitySteps[0].nodes.count == 1)
    #expect(replay.accessibilitySteps[0].totalNodeCount == 1)
    #expect(replay.accessibilitySteps[1].removedNodeIDs == ["root"])
    #expect(replay.accessibilitySteps[1].totalNodeCount == 0)
    #expect(replay.accessibilitySteps[1].nodes.isEmpty)
    #expect(replay.videoTime(for: replay.accessibilitySteps[1]) == 1)

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
