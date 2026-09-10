import Foundation
@testable import PabloCore

let testApplication = RecordingApplication(
    id: "APP-001",
    pid: 42,
    bundleIdentifier: "example.app",
    name: "Example",
    firstSeenTimestampNs: 0,
    lastSeenTimestampNs: nil
)

func testManifest(schemaVersion: Int = 3) -> RecordingManifest {
    RecordingManifest(
        schemaVersion: schemaVersion,
        dataSource: .native,
        startedAt: "2026-08-11T16:20:09.844Z",
        endedAt: "2026-08-11T16:20:11.844Z",
        durationNs: 2_000_000_000,
        scope: .init(
            kind: .application,
            selectedApplicationID: testApplication.id,
            selectedDisplayID: nil
        ),
        displays: [],
        applications: [testApplication],
        capture: .init(
            frame: RecordingRect(x: 10, y: 20, width: 50, height: 50),
            displayScale: 2,
            width: 100,
            height: 100,
            framesPerSecond: 30,
            firstFrameTimestampNs: 100_000_000,
            videoTracks: [RecordingVideoTrack(
                id: "VIDEO-001", displayID: 1, file: "video.mov",
                frame: RecordingRect(x: 10, y: 20, width: 50, height: 50),
                width: 100, height: 100, displayScale: 2, framesPerSecond: 30,
                startedTimestampNs: 0, firstFrameTimestampNs: 100_000_000,
                endedTimestampNs: 2_000_000_000, endReason: .recordingStopped
            )]
        ),
        files: [
            "events": "events.pb",
            "accessibility": "accessibility.pb",
            "workspace": "workspace.pb",
        ],
        web: nil
    )
}

func writeTestWorkspace(to packageURL: URL) throws {
    let record = WorkspaceSnapshotRecord(
        schemaVersion: 3,
        timestampNs: 0,
        reason: "initial",
        frontmostApplicationID: testApplication.id,
        applications: [testApplication],
        windows: [],
        appearedApplicationIDs: [testApplication.id],
        removedApplicationIDs: [],
        appearedWindowIDs: [],
        removedWindowIDs: []
    )
    try PabloProtobufCodec.encode(record).write(
        to: packageURL.appendingPathComponent("workspace.pb")
    )
}
