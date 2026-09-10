import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
@Test("unified replay model discovers web recordings and honors an external preferred package")
func unifiedReplayModelLoadsPreferredWebRecording() throws {
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
    let model = ReplayModel()

    #expect(model.loadLatest(preferredURL: preferred.packageURL, directory: directory))

    #expect(model.libraryItems.count == 2)
    #expect(model.libraryItems.contains(where: {
        $0.packageURL.resolvingSymlinksInPath() == discovered.packageURL.resolvingSymlinksInPath()
    }))
    #expect(model.selectedLibraryItemID == preferred.packageURL.standardizedFileURL.path)
    #expect(model.webRecording?.packageURL.resolvingSymlinksInPath() ==
        preferred.packageURL.resolvingSymlinksInPath())
    #expect(model.recording == nil)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test("unified replay model reports an empty recording library")
func unifiedReplayModelReportsEmptyLibrary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-empty-rrweb-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ReplayModel()

    #expect(!model.loadLatest(preferredURL: nil, directory: directory))

    #expect(model.libraryItems.isEmpty)
    #expect(model.webRecording == nil)
    #expect(model.recording == nil)
    #expect(model.errorMessage == "No Pablo recordings were found.")
}

@MainActor
private final class TestWebPlaybackController: RRWebPlaybackControlling {
    var playCount = 0
    var pauseCount = 0
    var seeks: [TimeInterval] = []
    var rates: [Float] = []

    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func setPlaybackRate(_ rate: Float) { rates.append(rate) }

    func observedPlayback() async throws -> RRWebObservedPlayback {
        .init(time: seeks.last ?? 0, playing: playCount > pauseCount)
    }

    func reset() {
        playCount = 0
        pauseCount = 0
        seeks = []
        rates = []
    }
}

@MainActor
@Test("shared transport drives an rrweb renderer and keeps timeline selection synchronized")
func sharedTransportDrivesRRWebRenderer() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-shared-web-transport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = PabloSafariTab(id: 9, title: "Shared player", url: "https://example.com")
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: tab, directory: directory
    )
    let finalized = try PabloRRWebRecordingStorage.finalize(
        packageURL: recording.packageURL,
        batches: [Data(#"""
        [
          {"type":2,"timestamp":1000,"data":{}},
          {"type":3,"timestamp":2000,"data":{"source":2,"type":2}}
        ]
        """#.utf8)]
    )
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: finalized.packageURL, directory: directory))
    let controller = TestWebPlaybackController()
    model.attachWebPlaybackController(controller)
    controller.reset()

    model.seek(to: 0.5)
    model.setPlaybackRate(4)
    model.togglePlayback()

    #expect(controller.pauseCount == 1)
    #expect(controller.seeks == [0.5])
    #expect(controller.rates == [4, 4])
    #expect(controller.playCount == 1)
    #expect(model.isPlaying)

    let click = try #require(model.timelineItems.first(where: { $0.title == "Click" }))
    model.selectTimelineItem(click)
    #expect(model.selectedWebEvent?.title == "Click")
    #expect(model.currentVideoTime == 1)
    #expect(!model.isPlaying)
}

@MainActor
@Test("web recordings use the shared time-anchored annotation journal")
func webRecordingsUseSharedAnnotations() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-web-annotations-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(),
        tab: PabloSafariTab(id: 12, title: "Notes", url: "https://example.com"),
        directory: directory
    )
    let finalized = try PabloRRWebRecordingStorage.finalize(
        packageURL: recording.packageURL,
        batches: [Data(#"[{"type":2,"timestamp":1000},{"type":1,"timestamp":3000}]"#.utf8)]
    )
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: finalized.packageURL, directory: directory))
    model.seek(to: 1.25)

    #expect(model.addHumanAnnotation(
        text: "Web note",
        kind: .observation,
        attachEvidence: true,
        lineWidth: 0.01
    ))

    let note = try #require(model.annotations.first)
    #expect(note.startTimestampNs == 1_250_000_000)
    #expect(note.trace == nil)
    #expect(model.timelineItems.contains(where: { $0.lane == .annotation }))
    #expect(try RecordingAnnotationStore.load(from: finalized.packageURL).count == 1)
}

@MainActor
@Test("one recording browser switches between native and rrweb pablo packages")
func unifiedRecordingBrowserSwitchesDataSources() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-unified-browser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let nativeURL = directory.appendingPathComponent("Native.pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: nativeURL, withIntermediateDirectories: false)
    try JSONEncoder().encode(testManifest()).write(to: nativeURL.appendingPathComponent("manifest.json"))
    for filename in ["video.mov", "events.pb", "accessibility.pb", "workspace.pb"] {
        try Data().write(to: nativeURL.appendingPathComponent(filename))
    }
    let web = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(),
        tab: PabloSafariTab(id: 20, title: "Web", url: "https://example.com"),
        directory: directory
    )

    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: nativeURL, directory: directory))
    #expect(model.libraryItems.map(\.kind).contains(.native))
    #expect(model.libraryItems.map(\.kind).contains(.web))
    #expect(model.recording != nil)
    #expect(model.webRecording == nil)

    model.selectLibraryItem(web.packageURL.standardizedFileURL.path)

    #expect(model.recording == nil)
    #expect(model.webRecording?.packageURL.standardizedFileURL == web.packageURL.standardizedFileURL)
}


@MainActor
@Test("Library discovery keeps unopened evidence lazy and opening reports corrupt evidence")
func libraryDiscoveryDefersEvidenceLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-lazy-library-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let selected = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 1, title: "Selected", url: "https://example.test"), directory: directory)
    let unopened = directory.appendingPathComponent("Unopened.pablo")
    try FileManager.default.createDirectory(at: unopened, withIntermediateDirectories: false)
    try JSONEncoder().encode(testManifest()).write(to: unopened.appendingPathComponent("manifest.json"))
    try Data([0xff]).write(to: unopened.appendingPathComponent("accessibility.pb"))
    for name in ["events.pb", "workspace.pb", "video.mov"] {
        try Data().write(to: unopened.appendingPathComponent(name))
    }
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: selected.packageURL, directory: directory))
    #expect(model.libraryItems.contains { $0.packageURL.standardizedFileURL == unopened.standardizedFileURL })
    model.selectLibraryItem(unopened.standardizedFileURL.path)
    #expect(model.errorMessage != nil)
    #expect(model.webRecording?.packageURL == selected.packageURL)
}
