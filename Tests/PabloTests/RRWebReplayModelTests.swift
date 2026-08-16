import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
@Test("rrweb replay model discovers recordings and honors an external preferred package")
func rrwebReplayModelLoadsPreferredRecording() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-rrweb-model-\(UUID().uuidString)", isDirectory: true)
    let externalDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-rrweb-model-external-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: externalDirectory)
    }
    let tab = PabloSafariTab(id: 8, title: "Saved tab", url: "https://example.com")
    let discovered = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: tab, directory: directory
    )
    let preferred = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: tab, directory: externalDirectory
    )
    let model = RRWebReplayModel()

    model.load(preferredURL: preferred.packageURL, directory: directory)

    #expect(model.recordings.count == 2)
    #expect(model.recordings.contains(where: {
        $0.manifest.recordingID == discovered.manifest.recordingID
    }))
    #expect(model.selectedRecordingID == preferred.manifest.recordingID)
    #expect(model.selectedRecording?.packageURL.resolvingSymlinksInPath() ==
        preferred.packageURL.resolvingSymlinksInPath())
    #expect(model.errorMessage == nil)
}

@MainActor
@Test("rrweb replay model reports an empty recording library")
func rrwebReplayModelReportsEmptyLibrary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-empty-rrweb-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = RRWebReplayModel()

    model.load(directory: directory)

    #expect(model.recordings.isEmpty)
    #expect(model.selectedRecording == nil)
    #expect(model.errorMessage == "No Safari web recordings were found.")
}
