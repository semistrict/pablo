import Foundation
import Testing
@testable import PabloCore

@Test("Annotations preserve captured evidence and materialize their latest state")
func annotationsPreserveEvidence() throws {
    let packageURL = try makeAnnotationTestPackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }
    let manifestURL = packageURL.appendingPathComponent("manifest.json")
    let accessibilityURL = packageURL.appendingPathComponent("accessibility.pb")
    let manifestBefore = try Data(contentsOf: manifestURL)
    let accessibilityBefore = try Data(contentsOf: accessibilityURL)
    let createdAt = Date(timeIntervalSince1970: 1_786_500_000)
    let resolvedAt = createdAt.addingTimeInterval(60)
    let agent = RecordingAnnotationAuthor(
        type: .application,
        displayName: "Example Agent",
        applicationIdentifier: "com.example.agent",
        developerName: "Example Developer",
        developerTeamIdentifier: "TEAM123"
    )

    let created = try RecordingAnnotationStore.add(
        to: packageURL,
        draft: RecordingAnnotationDraft(
            kind: .issue,
            text: "  Submit remains disabled.  ",
            startTimestampNs: 300_000_000,
            accessibilityReferences: ["1", "A11Y-001"],
            accessibilityNodeIDs: ["button", "button"],
            trace: RecordingAnnotationTrace(
                samples: [
                    .init(timestampNs: 300_000_000, x: 0.2, y: 0.3),
                    .init(timestampNs: 300_000_000, x: 0.4, y: 0.2),
                    .init(timestampNs: 300_000_000, x: 0.6, y: 0.3),
                ],
                lineWidth: 0.012
            )
        ),
        author: agent,
        now: createdAt
    )
    let resolved = try RecordingAnnotationStore.resolve(
        in: packageURL,
        reference: created.reference,
        author: .localHuman,
        now: resolvedAt
    )

    #expect(created.reference == "NOTE-001")
    #expect(created.text == "Submit remains disabled.")
    #expect(created.accessibilityReferences == ["A11Y-001"])
    #expect(created.accessibilityNodeIDs == ["button"])
    #expect(created.trace?.samples.count == 3)
    #expect(created.trace?.samples.allSatisfy { $0.timestampNs == 300_000_000 } == true)
    #expect(resolved.id == created.id)
    #expect(resolved.status == .resolved)
    #expect(resolved.createdBy == agent)
    #expect(resolved.updatedBy == .localHuman)
    #expect(try RecordingAnnotationStore.load(from: packageURL) == [resolved])
    #expect(try Data(contentsOf: manifestURL) == manifestBefore)
    #expect(try Data(contentsOf: accessibilityURL) == accessibilityBefore)

    let journal = try Data(
        contentsOf: packageURL.appendingPathComponent(RecordingAnnotationStore.filename)
    )
    #expect(try ProtobufStream.count(in: journal) == 2)
    #expect(try ReplayRecording.load(from: packageURL).annotations == [resolved])
    #expect(try CLI.annotations(packageURL, json: false).contains("NOTE-001"))
    #expect(try CLI.annotations(packageURL, json: true).contains("Submit remains disabled."))
}

@Test("Annotation anchors must refer to valid evidence")
func annotationAnchorsAreValidated() throws {
    let packageURL = try makeAnnotationTestPackage()
    defer { try? FileManager.default.removeItem(at: packageURL) }

    #expect(throws: RecordingError.self) {
        try RecordingAnnotationStore.add(
            to: packageURL,
            draft: RecordingAnnotationDraft(
                kind: .observation,
                text: "Out of range",
                accessibilityReferences: ["A11Y-002"]
            ),
            author: .localHuman
        )
    }
    #expect(throws: RecordingError.self) {
        try RecordingAnnotationStore.add(
            to: packageURL,
            draft: RecordingAnnotationDraft(
                kind: .highlight,
                text: "Invalid trace",
                trace: RecordingAnnotationTrace(samples: [
                    .init(timestampNs: 100, x: 1.2, y: 0.8),
                ])
            ),
            author: .localHuman
        )
    }
    #expect(throws: RecordingError.self) {
        try RecordingAnnotationStore.add(
            to: packageURL,
            draft: RecordingAnnotationDraft(
                kind: .highlight,
                text: "Time runs backward",
                trace: RecordingAnnotationTrace(samples: [
                    .init(timestampNs: 200, x: 0.1, y: 0.1),
                    .init(timestampNs: 100, x: 0.2, y: 0.2),
                ])
            ),
            author: .localHuman
        )
    }
}

@Test("Paused traces are one-frame shapes and moving traces reveal through time")
func traceTemporalSlicing() {
    let paused = RecordingAnnotationTrace(samples: [
        .init(timestampNs: 1_000, x: 0.1, y: 0.2),
        .init(timestampNs: 1_000, x: 0.5, y: 0.1),
        .init(timestampNs: 1_000, x: 0.9, y: 0.2),
    ])
    #expect(paused.visibleSamples(at: 1_000, pointToleranceNs: 10) == paused.samples)
    #expect(paused.visibleSamples(at: 1_011, pointToleranceNs: 10).isEmpty)

    let moving = RecordingAnnotationTrace(samples: [
        .init(timestampNs: 1_000, x: 0.0, y: 0.0),
        .init(timestampNs: 2_000, x: 1.0, y: 0.5),
        .init(timestampNs: 3_000, x: 1.0, y: 1.0),
    ])
    let halfway = moving.visibleSamples(
        at: 1_500,
        pointToleranceNs: 10,
        tailDurationNs: 100
    )
    #expect(halfway.count == 2)
    #expect(halfway.last == .init(timestampNs: 1_500, x: 0.5, y: 0.25))
    #expect(moving.visibleSamples(
        at: 3_100,
        pointToleranceNs: 10,
        tailDurationNs: 100
    ) == moving.samples)
    #expect(moving.visibleSamples(
        at: 3_101,
        pointToleranceNs: 10,
        tailDurationNs: 100
    ).isEmpty)
}

private func makeAnnotationTestPackage() throws -> URL {
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-annotations-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    let manifest = RecordingManifest(
        schemaVersion: 2,
        startedAt: "2026-08-12T12:00:00Z",
        endedAt: "2026-08-12T12:00:01Z",
        durationNs: 1_000_000_000,
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
    try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent("manifest.json"))
    let root = AXNode(
        id: "root",
        parentID: nil,
        childIDs: ["button"],
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
    let button = AXNode(
        id: "button",
        parentID: "root",
        childIDs: [],
        role: "AXButton",
        subrole: nil,
        title: "Submit",
        label: nil,
        value: nil,
        identifier: "submit",
        help: nil,
        enabled: false,
        focused: false,
        position: nil,
        size: nil
    )
    let record = AXSnapshotRecord(
        schemaVersion: 2,
        timestampNs: 200_000_000,
        reason: "initial",
        kind: "full",
        rootID: root.id,
        upserts: [root, button],
        removed: [],
        truncated: false
    )
    try PabloProtobufCodec.encode(record).write(
        to: packageURL.appendingPathComponent("accessibility.pb")
    )
    try Data().write(to: packageURL.appendingPathComponent("events.pb"))
    try Data().write(to: packageURL.appendingPathComponent("video.mov"))
    return packageURL
}
