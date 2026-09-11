import AppKit
import AVFoundation
import Combine
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
@Test("Display videos share a timeline and desktop coordinates without stale frames outside their lifetimes")
func displayVideosComposeOnOneTimeline() async throws {
    let package = try await makeMultiDisplayReplayPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let recording = try ReplayRecording.load(from: package)
    let item = try await ReplayVideoComposition.makeItem(recording: recording)
    let generator = AVAssetImageGenerator(asset: item.asset)
    generator.videoComposition = item.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 30)).image
    let together = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 30)).image
    let after = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 30)).image
    #expect(before.width == 160)
    #expect(before.height == 120)
    try expectPixel(before, x: 40, y: 30, red: true)
    try expectPixel(before, x: 120, y: 90, black: true)
    try expectPixel(together, x: 40, y: 30, red: true)
    try expectPixel(together, x: 120, y: 90, green: true)
    try expectPixel(after, x: 40, y: 30, black: true)
    try expectPixel(after, x: 120, y: 90, green: true)
}

@MainActor
@Test("Focusing windows preserves time and maps annotations through the recording canvas")
func replayWindowFocusPreservesTimeAndCoordinates() async throws {
    let package = try await makeMultiDisplayReplayPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package))
    let recording = try #require(model.recording)
    model.seek(to: 1.5)
    model.updateCurrentVideoTime()
    model.focusWindow("APP-001:WIN-2")
    #expect(model.currentVideoTime == 1.5)
    let viewport = try #require(model.focusedWindowFrame)
    #expect(viewport == RecordingRect(x: 0, y: 0, width: 40, height: 30))
    let center = recording.captureFrame.normalizedPoint(x: 0.5, y: 0.5, from: viewport)
    #expect(center == CGPoint(x: 0.75, y: 0.75))

    model.focusWindow("APP-001:WIN-1")
    model.seek(to: 2.5)
    #expect(model.focusedWindowFrame == nil)
    #expect(model.focusedWindowID == "APP-001:WIN-1")
    model.focusWindow(nil)
    #expect(model.currentVideoTime == 2.5)
    #expect(model.videoViewport == recording.captureFrame)
}

@MainActor
@Test("Review image export returns the settled crop with matching provenance and immutable evidence")
func reviewImageExportMatchesCrop() async throws {
    let package = try await makeMultiDisplayReplayPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let before = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    defer { registry.remove(model.reviewID) }
    var state = try registry.state(model.reviewID)
    let command = PabloReviewCommandRequest(reviewID: model.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .seek, seconds: 1.5))
    let settled = try await registry.perform(command, caller: "Fixture app")
    #expect(settled.status == .completed)
    model.focusWindow("APP-001:WIN-2")
    state = try registry.state(model.reviewID)
    let request = PabloReviewEvidenceRequest(reviewID: model.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        kind: .image, maxPixelDimension: 160)
    let result = try await registry.evidence(request)
    #expect(result.state.source == state.source)
    #expect(result.state.viewport == RecordingRect(x: 0, y: 0, width: 40, height: 30))
    let exported = try #require(result.image)
    #expect(exported.width == 80)
    #expect(exported.height == 60)
    #expect(abs(exported.renderedSeconds - 1.5) < 0.04)
    let bytes = try #require(Data(base64Encoded: exported.base64))
    let image = try #require(NSBitmapImageRep(data: bytes)?.cgImage)
    try expectPixel(image, x: 40, y: 30, green: true)
    #expect(try Data(contentsOf: package.appendingPathComponent("manifest.json")) == before)
    #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("annotations.pb").path))
}

@Test("Stored annotation coordinates survive expansion of the recording canvas")
func annotationCoordinatesSurviveDisplayChanges() throws {
    let originalCanvas = RecordingRect(x: 0, y: 0, width: 100, height: 100)
    let expandedCanvas = RecordingRect(x: -100, y: 0, width: 200, height: 100)
    let trace = RecordingAnnotationTrace(
        samples: [.init(timestampNs: 100, x: 0.5, y: 0.5)],
        lineWidth: 0.01, coordinateFrame: originalCanvas
    )
    #expect(trace.samples(trace.samples, in: expandedCanvas) == [.init(timestampNs: 100, x: 0.75, y: 0.5)])
    #expect(trace.lineWidth(in: expandedCanvas) == 0.01)
}

@MainActor
@Test("Selecting a note while native video loads settles at the note's exact time")
func initialNativeNoteSelectionSettlesAtRequestedTime() async throws {
    let package = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-initial-seek-\(UUID()).pablo")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: package) }
    // A variable frame rate keeps annotation times independent of encoded sample boundaries.
    try await writeSolidTestVideo(to: package.appendingPathComponent("video.mov"), width: 160, height: 120,
        color: .green, duration: 4, framesPerSecond: 15,
        frameTimes: (0..<56).map { Double($0) * 0.0715 })
    var manifest = testManifest()
    manifest.capture = .native(tracks: [.init(id: "VIDEO-001", displayID: 1, file: "video.mov",
        frame: .init(x: 0, y: 0, width: 160, height: 120), width: 160, height: 120, displayScale: 1,
        framesPerSecond: 15, startedTimestampNs: 0, firstFrameTimestampNs: 346_085_834,
        endedTimestampNs: 4_346_085_834, endReason: .recordingStopped)], framesPerSecond: 15)
    manifest.durationNs = 4_346_085_834
    try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
    for file in ["events.pb", "workspace.pb", "accessibility.pb"] { try Data().write(to: package.appendingPathComponent(file)) }
    let note = try RecordingAnnotationStore.add(to: package,
        draft: .init(kind: .observation, text: "Between encoded frames", startTimestampNs: 2_346_085_834),
        author: .localHuman)
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package))
    let openingDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.player.currentItem == nil, ContinuousClock.now < openingDeadline { await Task.yield() }
    _ = try #require(model.player.currentItem)
    let registry = ReviewSessionRegistry()
    registry.register(model)
    defer { registry.remove(model.reviewID) }
    let state = try registry.state(model.reviewID)
    let result = try await registry.perform(.init(reviewID: model.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .selectAnnotation, reference: note.reference)), caller: "Fixture app")
    #expect(result.status == .completed)
    let settled = try registry.state(model.reviewID)
    #expect(settled.selection?.reference == note.reference)
    #expect(abs(settled.playheadSeconds - 2) <= 0.06)
    #expect(abs(try #require(settled.renderedSeconds) - 2) <= 0.06)
}

@MainActor
@Test("Native replay can seek beyond the final video track without inventing available video")
func nativeReplaySeeksBeyondCapturedVideo() async throws {
    let package = try await makeMultiDisplayReplayPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let manifestURL = package.appendingPathComponent("manifest.json")
    var manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
    manifest.durationNs = 5_000_000_000
    try JSONEncoder().encode(manifest).write(to: manifestURL)
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    defer { registry.remove(model.reviewID) }
    let state = try registry.state(model.reviewID)
    let result = try await registry.perform(.init(reviewID: model.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .seek, seconds: 4)), caller: "Fixture app")
    #expect(result.status == .completed)
    let settled = try registry.state(model.reviewID)
    #expect(abs(settled.playheadSeconds - 4) <= 0.06)
    #expect(abs(try #require(settled.renderedSeconds) - 4) <= 0.06)
    #expect(settled.videoAvailability == .unavailable)
    #expect(settled.accessibilityAvailability == .unavailable)
    #expect(settled.observations.isEmpty)
    let item = try #require(model.player.currentItem)
    let generator = AVAssetImageGenerator(asset: item.asset)
    generator.videoComposition = item.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let frame = try await generator.image(at: CMTime(seconds: 4, preferredTimescale: 30)).image
    try expectPixel(frame, x: 40, y: 30, black: true)
    try expectPixel(frame, x: 120, y: 90, black: true)
}

@MainActor
private func makeMultiDisplayReplayPackage() async throws -> URL {
    let package = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-composition-\(UUID().uuidString).pablo", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    do {
        let tracks = [
            RecordingVideoTrack(
                id: "VIDEO-001", displayID: 1, file: "left.mov",
                frame: .init(x: -40, y: -30, width: 40, height: 30), width: 80, height: 60,
                displayScale: 2, framesPerSecond: 30, startedTimestampNs: 0,
                firstFrameTimestampNs: 0, endedTimestampNs: 2_000_000_000, endReason: .displayUnavailable
            ),
            RecordingVideoTrack(
                id: "VIDEO-002", displayID: 2, file: "right.mov",
                frame: .init(x: 0, y: 0, width: 40, height: 30), width: 40, height: 30,
                displayScale: 1, framesPerSecond: 30, startedTimestampNs: 1_000_000_000,
                firstFrameTimestampNs: 1_000_000_000, endedTimestampNs: 3_000_000_000, endReason: .recordingStopped
            ),
        ]
        for (index, track) in tracks.enumerated() {
            try await writeSolidTestVideo(
                to: package.appendingPathComponent(track.file), width: track.width, height: track.height,
                color: index == 0 ? .red : .green, duration: 2
            )
        }
        var manifest = testManifest()
        manifest.capture = .native(tracks: tracks, framesPerSecond: 30)
        manifest.durationNs = 3_000_000_000
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        for file in ["accessibility.pb", "events.pb"] { try Data().write(to: package.appendingPathComponent(file)) }
        let windows = tracks.enumerated().map { index, track in
            RecordingWindow(
                id: "APP-001:WIN-\(index + 1)", applicationID: testApplication.id,
                systemWindowID: UInt32(index + 1), title: "Window \(index + 1)",
                frame: track.frame, layer: 0, isOnScreen: true, zOrder: UInt32(index)
            )
        }
        let snapshot = WorkspaceSnapshotRecord(
            schemaVersion: 3, timestampNs: 0, reason: "initial", frontmostApplicationID: testApplication.id,
            applications: [testApplication], windows: windows, appearedApplicationIDs: [testApplication.id],
            removedApplicationIDs: [], appearedWindowIDs: windows.map(\.id), removedWindowIDs: []
        )
        try PabloProtobufCodec.encode(snapshot).write(to: package.appendingPathComponent("workspace.pb"))
        return package
    } catch {
        try? FileManager.default.removeItem(at: package)
        throw error
    }
}

func writeSolidTestVideo(to url: URL, width: Int, height: Int, color: NSColor, duration: Double,
                         framesPerSecond: Int = 30, frameTimes: [Double]? = nil) async throws {
    let pipeline = try VideoWriterPipeline.prepare(
        outputURL: url, width: width, height: height, framesPerSecond: framesPerSecond, expectsMediaDataInRealTime: false
    )
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(result == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let data = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let rgb = try #require(color.usingColorSpace(.deviceRGB))
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * CVPixelBufferGetBytesPerRow(pixels) + column * 4
            data[offset] = UInt8(rgb.blueComponent * 255)
            data[offset + 1] = UInt8(rgb.greenComponent * 255)
            data[offset + 2] = UInt8(rgb.redComponent * 255)
            data[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    pipeline.writer.startSession(atSourceTime: .zero)
    for seconds in frameTimes ?? [0, duration - 1.0 / 30] {
        let deadline = Date().addingTimeInterval(5)
        while !pipeline.input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pipeline.adaptor.append(pixels, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000)))
    }
    pipeline.writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 30))
    pipeline.input.markAsFinished()
    await pipeline.writer.finishWriting()
    #expect(pipeline.writer.status == .completed)
}

func expectPixel(_ image: CGImage, x: Int, y: Int, red: Bool = false, green: Bool = false, blue: Bool = false, black: Bool = false) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    if red { #expect(color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.3) }
    if green { #expect(color.greenComponent > 0.7 && color.redComponent < 0.3 && color.blueComponent < 0.3) }
    if blue { #expect(color.blueComponent > 0.7 && color.redComponent < 0.3 && color.greenComponent < 0.3) }
    if black { #expect(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.15) }
}

@MainActor
@Test("Paused native playback ticks do not invalidate the replay view when time is unchanged")
func pausedReplayTicksDoNotPublishUnchangedState() async throws {
    let package = try await makeMultiDisplayReplayPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: package, directory: package))
    for _ in 0..<300 where model.videoIsLoading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.videoIsLoading)
    #expect(!model.isPlaying)
    model.updateCurrentVideoTime()
    var notifications = 0
    let subscription = model.objectWillChange.sink { notifications += 1 }
    defer { subscription.cancel() }
    for _ in 0..<120 { model.updateCurrentVideoTime() }
    #expect(notifications == 0)
    #expect(model.renderedSeconds == model.player.currentTime().seconds)
}
