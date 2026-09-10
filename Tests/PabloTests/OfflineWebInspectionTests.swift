import Foundation
import Testing
@testable import PabloCore

@Test("Ordinary offline inspection reads web evidence and notes without contacting the app")
func offlineInspectionSupportsWebPackages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":3,"timestamp":2250,"data":{"source":2,"type":2}}]"#.utf8)
    ])
    _ = try RecordingAnnotationStore.add(to: recording.packageURL, draft: .init(
        kind: .observation, text: "Web note", startTimestampNs: 1_250_000_000, endTimestampNs: 1_250_000_000,
        applicationIDs: [], accessibilityReferences: [], accessibilityNodeIDs: [], trace: nil), author: .localHuman)
    let summary = try JSONSerialization.jsonObject(with: Data(CLI.inspect(recording.packageURL).utf8)) as? [String: Any]
    #expect(summary?["webEventCount"] as? Int == 2)
    let events = try JSONSerialization.jsonObject(with: Data(CLI.events(recording.packageURL, limit: 1, json: true).utf8)) as? [[String: Any]]
    #expect(events?.count == 1)
    #expect(events?.first?["reference"] as? String == "rrweb:0")
    let notes = try CLI.annotations(recording.packageURL, json: false)
    #expect(notes.contains("NOTE-001"))
    #expect(notes.contains("00:01.250"))
    do {
        _ = try CLI.frames(recording.packageURL, json: true)
        Issue.record("A web source has no native AX frames.")
    } catch {
        #expect(error.localizedDescription.contains("native accessibility"))
    }
}

@Test("Preparing a web annotation uses web time and rejects native-only anchors")
func webAnnotationPreparationUsesSourceTime() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    var options = AnnotationOptions()
    options.recordingURL = recording.packageURL
    options.text = "A web observation"
    options.at = 1.25
    let request = try CLI.prepareAnnotation(options)
    #expect(request.draft?.startTimestampNs == 1_250_000_000)
    #expect(request.draft?.endTimestampNs == 1_250_000_000)
    #expect(request.draft?.applicationIDs == ["SAFARI-TAB-42"])
    #expect(!FileManager.default.fileExists(atPath: recording.packageURL.appendingPathComponent("annotations.pb").path))
    options.accessibilityReferences = ["A11Y-001"]
    #expect(throws: RecordingError.self) { try CLI.prepareAnnotation(options) }
    options.accessibilityReferences = []
    options.at = .infinity
    #expect(throws: RecordingError.self) { try CLI.prepareAnnotation(options) }
}
