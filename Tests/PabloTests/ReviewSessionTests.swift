import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
private final class DelayedReviewRenderer: RRWebPlaybackControlling {
    var observedTime: Double = 0
    var observedPlaying = false
    var requestedTime: Double?
    func play() { observedPlaying = true }
    func pause() { observedPlaying = false }
    func seek(to seconds: TimeInterval) { requestedTime = seconds }
    func setPlaybackRate(_ rate: Float) {}
    func observedPlayback() async throws -> RRWebObservedPlayback {
        .init(time: observedTime, playing: observedPlaying)
    }
}

@MainActor
@Test("Review identity follows the window and changes source generation on reload")
func reviewSessionIdentityAndCoherentState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"),
        directory: directory
    )
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [Data("[{\"type\":2,\"timestamp\":1000},{\"type\":3,\"timestamp\":3000,\"data\":{\"source\":0}}]".utf8)])
    let registry = ReviewSessionRegistry()
    let first = ReplayModel()
    let second = ReplayModel()
    #expect(first.loadLatest(preferredURL: recording.packageURL, directory: directory))
    #expect(second.loadLatest(preferredURL: recording.packageURL, directory: directory))
    registry.register(first)
    registry.register(second)
    registry.activate(first.reviewID)
    first.videoTool = .comment
    first.inspectorVisible = true
    first.seek(to: 1.25)
    let state = try registry.state(first.reviewID)
    #expect(state.reviewID != second.reviewID)
    #expect(state.isActive)
    #expect(state.source?.sourceID == (try registry.state(second.reviewID)).source?.sourceID)
    #expect(state.playheadSeconds == 1.25)
    #expect(state.tool == "comment")
    #expect(state.inspectorVisible)
    #expect(state.renderer == .loading)
    let generation = state.source?.generation
    #expect(first.loadLatest(preferredURL: recording.packageURL, directory: directory))
    #expect(try registry.state(first.reviewID).source?.generation != generation)
    #expect(try registry.state(first.reviewID).reviewID == state.reviewID)
    registry.remove(first.reviewID)
    #expect(registry.states().count == 1)
    #expect(throws: (any Error).self) { try registry.state(first.reviewID) }
}

@MainActor
@Test("Selecting an event replaces a note selection; playback ticks preserve the context revision")
func reviewSelectionAndRevision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":3,"timestamp":3000,"data":{"source":2,"type":2}}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    #expect(model.addHumanAnnotation(text: "Note", kind: .observation, attachEvidence: true, lineWidth: 0.01))
    #expect(model.reviewState().selection?.kind == "annotation")
    let click = try #require(model.timelineItems.first { $0.title == "Click" })
    model.selectTimelineItem(click)
    #expect(model.selectedAnnotationID == nil)
    #expect(model.reviewState().selection?.kind == "event")
    #expect(model.reviewState().selection?.reference == click.id)
    model.updateWebRenderer(ready: true)
    model.updateWebPlayback(time: 0.4, playing: true)
    let revision = model.reviewState().revision
    model.updateWebPlayback(time: 0.5, playing: true)
    #expect(model.reviewState().revision == revision)
    model.seek(to: 0.6)
    #expect(model.reviewState().revision > revision)
    #expect(model.selectedTimelineItemID == nil)
}

@MainActor
@Test("Review commands reject stale context and human drafts, and receipts prevent repeat execution")
func reviewCommandsRespectContextAndReceipts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    let state = try registry.state(model.reviewID)
    let generation = try #require(state.source?.generation)
    let request = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: generation, expectedRevision: state.revision,
        command: .init(kind: .tool, tool: "comment"))
    let applied = try await registry.perform(request, caller: "Fixture app")
    #expect(applied.status == .completed)
    #expect(model.videoTool == .comment)
    let revision = model.reviewState().revision
    #expect(try await registry.perform(request, caller: "Fixture app") == applied)
    #expect(model.reviewState().revision == revision)
    let stale = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: generation, expectedRevision: state.revision,
        command: .init(kind: .tool, tool: "pen"))
    #expect(try await registry.perform(stale, caller: "Fixture app").status == .staleContext)
    #expect(model.videoTool == .comment)
    model.draftText = "A human is still writing"
    let conflict = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: generation, expectedRevision: model.reviewState().revision,
        command: .init(kind: .seek, seconds: 0))
    #expect(try await registry.perform(conflict, caller: "Fixture app").status == .draftConflict)
    #expect(model.draftText == "A human is still writing")
    #expect(throws: (any Error).self) {
        try registry.operation(.init(serviceID: registry.serviceID, operationID: request.operationID), caller: "Another app")
    }
}

@MainActor
@Test("Seek completion waits for renderer-observed time and yields to human changes", arguments: ["complete", "human", "cancel"])
func reviewSeekWaitsForRenderedTime(outcome: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":1,"timestamp":3000}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let renderer = DelayedReviewRenderer()
    model.attachWebPlaybackController(renderer)
    model.updateWebRenderer(ready: true)
    model.updateWebPlayback(time: 0, playing: false)
    let registry = ReviewSessionRegistry()
    registry.register(model)
    defer { registry.remove(model.reviewID) }
    let state = try registry.state(model.reviewID)
    let request = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .seek, seconds: 1.25))
    let execution = Task { try await registry.perform(request, caller: "Fixture app") }
    for _ in 0..<100 {
        if renderer.requestedTime == 1.25 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let pending = try registry.operation(.init(serviceID: registry.serviceID, operationID: request.operationID), caller: "Fixture app")
    #expect(pending.status == .running)
    #expect(model.reviewState().renderedSeconds == 0)
    let interrupted = outcome != "complete"
    if outcome == "human" { model.videoTool = .pen }
    if outcome == "cancel" {
        #expect(throws: (any Error).self) {
            try registry.cancel(.init(serviceID: registry.serviceID, operationID: request.operationID), caller: "Another app")
        }
        let cancelled = try registry.cancel(.init(serviceID: registry.serviceID, operationID: request.operationID), caller: "Fixture app")
        #expect(cancelled.status == .cancellationRequested)
    } else {
        renderer.observedTime = 1.25
    }
    let completed = try await execution.value
    #expect(completed.status == (interrupted ? .interrupted : .completed))
    if outcome == "human" {
        #expect(model.videoTool == .pen)
    } else if !interrupted {
        #expect(completed.state?.renderedSeconds == 1.25)
        #expect(completed.state?.renderer == .ready)
    }
}

@MainActor
@Test("Human note creation and resolution refresh every review of the same journal")
func humanNotesRefreshAllReviews() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    let first = ReplayModel()
    let second = ReplayModel()
    #expect(first.loadLatest(preferredURL: recording.packageURL, directory: directory))
    #expect(second.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let revision = second.reviewState().revision
    #expect(first.addHumanAnnotation(text: "Shared note", kind: .observation, attachEvidence: false, lineWidth: 0.01))
    let note = try #require(first.annotations.first)
    #expect(second.annotations.first?.id == note.id)
    #expect(second.reviewState().revision > revision)
    first.resolveSelectedAnnotation()
    #expect(second.annotations.first?.status == .resolved)
    #expect(second.timelineItems.contains { $0.id == "annotation:\(note.id.uuidString)" })
}

@MainActor
@Test("A human draft retains its original source and time while the playhead moves")
func humanDraftKeepsCapturedAnchor() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":1,"timestamp":3000}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    model.seek(to: 0.5)
    model.draftText = "What I saw here"
    let draft = try #require(model.reviewState().draft)
    #expect(draft.owner == "human")
    #expect(draft.sourceGeneration == model.reviewState().source?.generation)
    #expect(draft.anchorTimestampNs == 500_000_000)
    model.seek(to: 1.5)
    #expect(model.addHumanAnnotation(text: model.draftText, kind: .observation, attachEvidence: false, lineWidth: 0.01))
    #expect(model.annotations.first?.startTimestampNs == 500_000_000)
    #expect(model.reviewState().draft == nil)
}

@MainActor
@Test("A repeated review note operation appends exactly one caller-attributed note at its supplied anchor")
func reviewNoteOperationIsIdempotent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":1,"timestamp":3000}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    let state = try registry.state(model.reviewID)
    let command = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .annotate, text: "Discuss this point", timestampNs: 1_250_000_000))
    let author = RecordingAnnotationAuthor(type: .application, displayName: "Fixture app", applicationIdentifier: "example.fixture")
    let first = try await registry.perform(command, caller: "Fixture app", author: author)
    let repeated = try await registry.perform(command, caller: "Fixture app", author: author)
    #expect(first.status == .completed)
    #expect(repeated == first)
    #expect(first.annotation?.reference == "NOTE-001")
    #expect(first.annotation?.createdBy == author)
    #expect(model.annotations.count == 1)
    #expect(model.annotations.first?.startTimestampNs == 1_250_000_000)
    #expect(model.currentVideoTime == 0)
}

@MainActor
@Test("Review changes have bounded cursors, human origins, and explicit resynchronization gaps")
func reviewChangesAreBoundedAndSourceQualified() async throws {
    let registry = ReviewSessionRegistry(eventCapacity: 3)
    let model = ReplayModel()
    registry.register(model)
    let initial = try await registry.watch(.init(after: 0))
    #expect(initial.events.first?.reviewID == model.reviewID)
    model.videoTool = .pen
    let changed = try await registry.watch(.init(serviceID: registry.serviceID, after: initial.nextCursor, waitMs: 1_000))
    #expect(changed.events.contains { $0.reviewID == model.reviewID && $0.origin == .human })
    #expect(changed.events.last?.revision == model.reviewState().revision)
    registry.activate(model.reviewID)
    registry.deactivate(model.reviewID)
    let second = ReplayModel()
    registry.register(second)
    registry.remove(second.reviewID)
    let gap = try await registry.watch(.init(serviceID: registry.serviceID, after: 0))
    #expect(gap.events.count == 3)
    #expect(gap.resyncRequired)
    #expect(gap.oldestSequence > 1)
    let empty = try await registry.watch(.init(serviceID: registry.serviceID, after: gap.nextCursor))
    #expect(empty.events.isEmpty)
    #expect(empty.nextCursor == gap.nextCursor)
    let restarted = try await registry.watch(.init(serviceID: UUID(), after: gap.nextCursor))
    #expect(restarted.resyncRequired)
    #expect(restarted.serviceID == registry.serviceID)
}

@MainActor
@Test("Review timeline queries preserve source identity, range, and stable cursor bounds")
func reviewEvidenceRangeAndSourcePreconditions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":3,"timestamp":2000,"data":{"source":2,"type":2}},{"type":3,"timestamp":3000,"data":{"source":2,"type":2}}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    let state = try registry.state(model.reviewID)
    let request = PabloReviewEvidenceRequest(reviewID: model.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        kind: .timeline, fromSeconds: 0.5, toSeconds: 2, limit: 1)
    let page = try await registry.evidence(request)
    #expect(page.state.source == state.source)
    #expect(page.items.count == 1)
    #expect(page.items.first?.timestampNs == 1_000_000_000)
    #expect(page.nextCursor == 1)
    #expect(page.hasMore)
    var next = request
    next.after = page.nextCursor
    let last = try await registry.evidence(next)
    #expect(last.items.count == 1)
    #expect(last.items.first?.timestampNs == 2_000_000_000)
    #expect(!last.hasMore)
    model.videoTool = .pen
    await #expect(throws: (any Error).self) { try await registry.evidence(next) }
}

@MainActor
@Test("Failed loads and source changes cannot lose an unsaved human draft")
func reviewSourceReplacementPreservesDraft() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "First", url: "https://example.test"), directory: directory)
    let second = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 43, title: "Second", url: "https://example.test"), directory: directory)
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: first.packageURL, directory: directory))
    let source = model.reviewState().source
    let bad = directory.appendingPathComponent("invalid.pablo")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    #expect(!model.loadLatest(preferredURL: bad, directory: directory))
    #expect(model.reviewState().source == source)
    model.draftText = "Keep this at its original source"
    let draft = model.reviewState().draft
    #expect(!model.loadLatest(preferredURL: second.packageURL, directory: directory))
    #expect(model.reviewState().source == source)
    #expect(model.reviewState().draft == draft)
}

@MainActor
@Test("Review activation reports observed completion and supports cancellation", arguments: ["complete", "failure", "cancel"])
func reviewActivationRequiresObservedWindow(outcome: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 1, title: "Fixture", url: "https://example.test"), directory: directory)
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    let registry = ReviewSessionRegistry()
    registry.register(model)
    var activationRequested = false
    var observed = false
    registry.activateWindow = { id in
        activationRequested = true
        while !observed { try await Task.sleep(for: .milliseconds(5)) }
        if outcome == "failure" { throw RecordingError.capture("The window did not become active.") }
        registry.activate(id)
    }
    let state = try registry.state(model.reviewID)
    let request = PabloReviewCommandRequest(reviewID: state.reviewID, serviceID: registry.serviceID,
        expectedSourceGeneration: try #require(state.source?.generation), expectedRevision: state.revision,
        command: .init(kind: .activate))
    let task = Task { try await registry.perform(request, caller: "Fixture app") }
    for _ in 0..<100 where !activationRequested { try await Task.sleep(for: .milliseconds(5)) }
    #expect(activationRequested)
    let lookup = PabloReviewOperationRequest(serviceID: registry.serviceID, operationID: request.operationID)
    #expect(try registry.operation(lookup, caller: "Fixture app").status == .running)
    #expect(try !registry.state(model.reviewID).isActive)
    if outcome == "cancel" { _ = try registry.cancel(lookup, caller: "Fixture app") }
    else { observed = true }
    let result = try await task.value
    #expect(result.status == (outcome == "complete" ? .completed : outcome == "cancel" ? .interrupted : .failed))
    #expect(result.state?.isActive == (outcome == "complete"))
}

@MainActor
@Test("Quick-note submission keeps its captured anchor and retains a draft after a failed write", arguments: [false, true])
func quickNoteKeepsCapturedAnchorAndFailedDraft(failsWrite: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory)
    _ = try PabloRRWebRecordingStorage.finalize(packageURL: recording.packageURL, batches: [
        Data(#"[{"type":2,"timestamp":1000},{"type":1,"timestamp":3000}]"#.utf8)
    ])
    let model = ReplayModel()
    #expect(model.loadLatest(preferredURL: recording.packageURL, directory: directory))
    model.seek(to: 0.5)
    model.draftText = "What I saw here"
    let draft = try #require(model.reviewState().draft)
    #expect(draft.owner == "human")
    #expect(draft.sourceGeneration == model.reviewState().source?.generation)
    #expect(draft.anchorTimestampNs == 500_000_000)
    model.seek(to: 1.5)
    if failsWrite {
        // A directory where the journal file belongs deterministically rejects the append.
        try FileManager.default.createDirectory(at: recording.packageURL.appendingPathComponent("annotations.pb"), withIntermediateDirectories: false)
    }
    #expect(model.saveQuickNote(kind: .observation, attachEvidence: false, lineWidth: 0.01) == !failsWrite)
    if failsWrite {
        #expect(model.draftText == "What I saw here")
        #expect(model.reviewState().draft?.anchorTimestampNs == 500_000_000)
        #expect(model.annotations.isEmpty)
    } else {
        #expect(model.annotations.first?.startTimestampNs == 500_000_000)
        #expect(model.reviewState().draft == nil)
    }
}
