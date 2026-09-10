import Foundation
import Testing
@testable import PabloCore

private func temporaryRRWebDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-rrweb-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private let rrwebTestTab = PabloSafariTab(
    id: 42,
    windowID: 7,
    title: "Example / Account: Overview",
    url: "https://example.com/account"
)

@Test("rrweb packages name Safari and the tab and record masked-input metadata")
func rrwebPackageManifestAndFilename() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let startedAt = Date(timeIntervalSince1970: 1_787_000_000)
    let recordingID = UUID()

    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: recordingID,
        tab: rrwebTestTab,
        at: startedAt,
        directory: directory
    )

    #expect(recording.packageURL.pathExtension == "pablo")
    #expect(recording.packageURL.lastPathComponent.hasPrefix("Safari Example - Account- Overview Web Recording "))
    #expect(recording.manifest.recordingID == recordingID)
    #expect(recording.manifest.tab == rrwebTestTab)
    #expect(recording.manifest.state == .recording)
    #expect(recording.manifest.inputsMasked)
    #expect(recording.manifest.rrwebVersion == "2.1.1")
    #expect(try String(contentsOf: recording.eventsURL, encoding: .utf8) == "[]\n")

    let manifest = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: recording.packageURL.appendingPathComponent("manifest.json")))
            as? [String: Any]
    )
    #expect(manifest["schemaVersion"] as? Int == 3)
    #expect(manifest["dataSource"] as? String == "rrweb")
    #expect((manifest["files"] as? [String: String]) == ["rrweb": "events.json"])
}

@Test("rrweb events become shared timeline lanes and inspectable selections")
func rrwebEventsBuildSharedTimelineData() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, directory: directory
    )
    let finalized = try PabloRRWebRecordingStorage.finalize(
        packageURL: recording.packageURL,
        batches: [Data(#"""
        [
          {"type":4,"timestamp":1000,"data":{"href":"https://example.com"}},
          {"type":2,"timestamp":1100,"data":{}},
          {"type":3,"timestamp":1250,"data":{"source":2,"type":2}},
          {"type":3,"timestamp":1500,"data":{"source":0,"adds":[{}],"removes":[],"texts":[],"attributes":[]}}
        ]
        """#.utf8)]
    )

    let replay = try PabloRRWebReplayData(recording: finalized)

    #expect(replay.duration == 0.5)
    #expect(replay.timelineItems.map(\.lane) == [.workspace, .document, .input, .document])
    #expect(replay.timelineItems.map(\.timestampNs) == [0, 100_000_000, 250_000_000, 500_000_000])
    #expect(replay.event(index: 2)?.title == "Click")
    #expect(replay.event(index: 2)?.formattedJSON.contains(#""source" : 2"#) == true)
}

@Test("standalone legacy web manifests and extensions have no compatibility path")
func legacyWebFormatsAreRejected() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldExtension = directory.appendingPathComponent("Old.pabloweb", isDirectory: true)
    try FileManager.default.createDirectory(at: oldExtension, withIntermediateDirectories: false)
    #expect(throws: RecordingError.self) {
        try PabloRRWebRecordingStorage.load(oldExtension)
    }

    let oldManifest = directory.appendingPathComponent("Old.pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: oldManifest, withIntermediateDirectories: false)
    try Data(#"{"schemaVersion":1,"recordingID":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        .write(to: oldManifest.appendingPathComponent("manifest.json"))
    #expect(throws: (any Error).self) {
        try PabloRRWebRecordingStorage.load(oldManifest)
    }
}

@Test("rrweb package names remain unique when recordings begin together")
func rrwebPackageNamesRemainUnique() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let startedAt = Date(timeIntervalSince1970: 1_787_000_000)

    let first = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, at: startedAt, directory: directory
    )
    let second = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, at: startedAt, directory: directory
    )

    #expect(first.packageURL != second.packageURL)
    #expect(second.packageURL.deletingPathExtension().lastPathComponent.hasSuffix(" 2"))
}

@Test("finalizing an rrweb package preserves batch and event order")
func rrwebFinalizationPreservesEventOrder() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, directory: directory
    )
    let endedAt = Date(timeIntervalSince1970: 1_787_000_100)
    let batches = [
        Data(#"[{"type":2,"timestamp":10},{"type":3,"timestamp":20}]"#.utf8),
        Data(#"[{"type":4,"timestamp":30}]"#.utf8),
    ]

    let finalized = try PabloRRWebRecordingStorage.finalize(
        packageURL: recording.packageURL,
        batches: batches,
        endedAt: endedAt
    )
    let events = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: finalized.eventsURL)) as? [[String: Any]]
    )

    #expect(events.compactMap { $0["timestamp"] as? Int } == [10, 20, 30])
    #expect(finalized.manifest.state == .complete)
    #expect(finalized.manifest.endedAt == endedAt)
    #expect(finalized.manifest.eventCount == 3)
    #expect(try PabloRRWebRecordingStorage.load(recording.packageURL).manifest.eventCount == 3)
    let unifiedManifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: recording.packageURL.appendingPathComponent("manifest.json"))
    ) as? [String: Any]
    #expect((unifiedManifest?["durationNs"] as? NSNumber)?.uint64Value == 20_000_000)
}

@Test("invalid rrweb batches fail without replacing prior events")
func invalidRRWebBatchDoesNotReplaceEvents() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, directory: directory
    )

    #expect(throws: RecordingError.self) {
        try PabloRRWebRecordingStorage.finalize(
            packageURL: recording.packageURL,
            batches: [Data(#"{"not":"an array"}"#.utf8)]
        )
    }

    #expect(try String(contentsOf: recording.eventsURL, encoding: .utf8) == "[]\n")
    #expect(try PabloRRWebRecordingStorage.load(recording.packageURL).manifest.state == .recording)
}

@Test("rrweb recording discovery ignores malformed packages")
func rrwebDiscoveryIgnoresMalformedPackages() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let valid = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, directory: directory
    )
    let invalid = directory.appendingPathComponent("Broken.pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)

    let recordings = try PabloRRWebRecordingStorage.recordings(directory: directory)

    #expect(recordings.map { $0.packageURL.resolvingSymlinksInPath() } == [
        valid.packageURL.resolvingSymlinksInPath(),
    ])
}

@Test("out-of-range rrweb timestamps fail without replacing saved evidence")
func invalidRRWebTimestampsPreserveEvidence() throws {
    let directory = try temporaryRRWebDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: rrwebTestTab, directory: directory
    )
    let originalEvents = try Data(contentsOf: recording.eventsURL)
    let manifestURL = recording.packageURL.appendingPathComponent("manifest.json")
    let originalManifest = try Data(contentsOf: manifestURL)
    let invalidEvents = Data(#"[{"type":2,"timestamp":0},{"type":3,"timestamp":1e100}]"#.utf8)

    #expect(throws: RecordingError.self) {
        try PabloRRWebRecordingStorage.finalize(
            packageURL: recording.packageURL, batches: [invalidEvents]
        )
    }
    #expect(try Data(contentsOf: recording.eventsURL) == originalEvents)
    #expect(try Data(contentsOf: manifestURL) == originalManifest)

    try invalidEvents.write(to: recording.eventsURL)
    #expect(throws: RecordingError.self) {
        try PabloRRWebReplayData(recording: recording)
    }
}
