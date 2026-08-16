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

@Test("rrweb packages use the tab title and record masked-input metadata")
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

    #expect(recording.packageURL.pathExtension == "pabloweb")
    #expect(recording.packageURL.lastPathComponent.hasPrefix("Example - Account- Overview Web Recording "))
    #expect(recording.manifest.recordingID == recordingID)
    #expect(recording.manifest.tab == rrwebTestTab)
    #expect(recording.manifest.state == .recording)
    #expect(recording.manifest.inputsMasked)
    #expect(recording.manifest.rrwebVersion == "2.1.1")
    #expect(try String(contentsOf: recording.eventsURL, encoding: .utf8) == "[]\n")
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
    let invalid = directory.appendingPathComponent("Broken.pabloweb", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)

    let recordings = try PabloRRWebRecordingStorage.recordings(directory: directory)

    #expect(recordings.map { $0.packageURL.resolvingSymlinksInPath() } == [
        valid.packageURL.resolvingSymlinksInPath(),
    ])
}
