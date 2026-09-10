import AppKit
import ScreenCaptureKit
import Testing
@testable import PabloCore

private func display(_ id: UInt32, x: Double = 0, scale: Double = 1) -> RecordingDisplay {
    RecordingDisplay(id: id, name: "Display \(id)", frame: .init(x: x, y: 0, width: 640, height: 480), scale: scale, isPrimary: id == 1)
}

private final class TrackRecorderStub: RecordingVideoTrackCapturing {
    let display: RecordingDisplay
    let clock: SessionClock
    var firstFrameTimestampNs: UInt64?
    var captureEnded = false
    var paused = false
    var pausedAtStart = false
    var starts = 0
    var stops = 0
    var cancellations = 0
    var startError: Error?
    var stopError: Error?
    var suspendStart = false
    var startContinuation: CheckedContinuation<Void, Never>?

    init(display: RecordingDisplay, clock: SessionClock) {
        self.display = display
        self.clock = clock
    }

    func start() async throws -> VideoCaptureInfo {
        starts += 1
        pausedAtStart = paused
        if suspendStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startError { throw startError }
        firstFrameTimestampNs = clock.nowNanoseconds()
        return VideoCaptureInfo(
            frame: display.frame.cgRect, displayID: display.id,
            width: Int(display.frame.width * display.scale), height: Int(display.frame.height * display.scale),
            displayScale: display.scale, framesPerSecond: 30
        )
    }

    func stop(at timestampNs: UInt64) async throws {
        stops += 1
        captureEnded = true
        if let stopError { throw stopError }
    }
    func cancel() async { cancellations += 1; captureEnded = true }
    func pause() { paused = true }
    func resume() { paused = false }
}

@MainActor
@Test("A display that finishes starting after resume joins the resumed timeline")
func displayStartupReconcilesPauseState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var displays = [display(1)]
    var pending: TrackRecorderStub?
    let clock = SessionClock()
    let capture = VideoCaptureSession(
        scope: .application(42), directory: directory, clock: clock, framesPerSecond: 30,
        displays: { displays }, automaticallyRefresh: false
    ) { display, _, _, clock, _ in
        let recorder = TrackRecorderStub(display: display, clock: clock)
        if display.id == 2 { recorder.suspendStart = true; pending = recorder }
        return recorder
    }
    try await capture.start()
    clock.pause()
    capture.pause()
    displays.append(display(2))
    let refresh = Task { try await capture.refreshDisplays() }
    while pending?.startContinuation == nil { await Task.yield() }
    #expect(pending?.pausedAtStart == true)
    clock.resume()
    capture.resume()
    pending?.startContinuation?.resume()
    try await refresh.value
    #expect(pending?.paused == false)
    try await capture.stop()
}

@MainActor
@Test("Application capture follows every display through additions, moves, and removals")
func applicationCaptureTracksDisplayTopology() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-tracks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var displays = [display(1), display(2, x: -640, scale: 2)]
    var recorders: [TrackRecorderStub] = []
    var requestedPIDs: [pid_t?] = []
    let clock = SessionClock()
    let capture = VideoCaptureSession(
        scope: .application(42), directory: directory, clock: clock, framesPerSecond: 30,
        displays: { displays }, automaticallyRefresh: false
    ) { display, pid, _, clock, _ in
        requestedPIDs.append(pid)
        let recorder = TrackRecorderStub(display: display, clock: clock)
        recorders.append(recorder)
        return recorder
    }

    try await capture.start()
    #expect(capture.capture.videoTracks.map(\.displayID) == [1, 2])
    #expect(requestedPIDs == [42, 42])
    #expect(capture.captureFrame == nil) // App workspace must not be clipped to one display.

    clock.pause()
    capture.pause()
    displays.append(display(3, x: 640))
    try await capture.refreshDisplays()
    #expect(recorders.last?.pausedAtStart == true)
    #expect(recorders.allSatisfy { $0.paused })
    clock.resume()
    capture.resume()
    #expect(recorders.allSatisfy { !$0.paused })

    displays = [display(1, x: 100), display(3, x: 640)]
    recorders[1].stopError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)
    try await capture.refreshDisplays()
    let tracks = capture.capture.videoTracks
    #expect(tracks.count == 4)
    #expect(tracks[0].endReason == .displayChanged)
    #expect(tracks[1].endReason == .displayUnavailable)
    #expect(tracks[3].displayID == 1)
    #expect(tracks[3].frame.x == 100)
    #expect(tracks[3].startedTimestampNs >= tracks[0].endedTimestampNs!)
    #expect(!capture.captureEnded)

    try await capture.stop()
    #expect(recorders.allSatisfy { $0.stops == 1 })
    #expect(capture.capture.videoTracks.allSatisfy { $0.endedTimestampNs != nil })
    #expect(capture.capture.frame.x == -640)
}

@MainActor
@Test("An explicit display capture never expands to other displays")
func displayCaptureRemainsScoped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-display-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = VideoCaptureSession(
        scope: .display(2), directory: directory, clock: SessionClock(), framesPerSecond: 30,
        displays: { [display(1), display(2, x: -640)] }, automaticallyRefresh: false
    ) { display, pid, _, clock, _ in
        #expect(pid == nil)
        return TrackRecorderStub(display: display, clock: clock)
    }
    try await capture.start()
    #expect(capture.capture.videoTracks.map(\.displayID) == [2])
    #expect(capture.captureFrame == display(2, x: -640).frame.cgRect)
    try await capture.stop()
}

@MainActor
@Test("Ending system sharing never restarts a capture stream")
func applicationCaptureHonorsSystemStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-stopped-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = SessionClock()
    let recorder = TrackRecorderStub(display: display(1), clock: clock)
    let capture = VideoCaptureSession(
        scope: .application(42), directory: directory, clock: clock, framesPerSecond: 30,
        displays: { [display(1)] }, automaticallyRefresh: false,
        makeRecorder: { _, _, _, _, _ in recorder }
    )
    try await capture.start()
    recorder.captureEnded = true
    try await capture.refreshDisplays()
    try await capture.refreshDisplays()
    #expect(capture.captureEnded)
    #expect(recorder.starts == 1)
    try await capture.stop()
    #expect(capture.capture.videoTracks.first?.endReason == .captureStopped)
}

@MainActor
@Test("A partially started application capture cancels every stream on failure")
func partialApplicationCaptureIsCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-failed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var recorders: [TrackRecorderStub] = []
    let capture = VideoCaptureSession(
        scope: .application(42), directory: directory, clock: SessionClock(), framesPerSecond: 30,
        displays: { [display(1), display(2)] }, automaticallyRefresh: false
    ) { display, _, _, clock, _ in
        let recorder = TrackRecorderStub(display: display, clock: clock)
        if display.id == 2 { recorder.startError = RecordingError.capture("Display unavailable") }
        recorders.append(recorder)
        return recorder
    }
    await #expect(throws: RecordingError.self) { try await capture.start() }
    #expect(recorders.count == 2)
    #expect(recorders.allSatisfy { $0.cancellations == 1 })
    #expect(capture.capture.videoTracks.isEmpty)
}

@Test("Application workspace keeps every owned window and records visibility separately from lifetime")
func applicationWorkspaceFollowsAllWindows() throws {
    let registry = RecordingApplicationRegistry()
    func window(_ id: UInt32, pid: pid_t = 42, x: Double = 0, visible: Bool = true) -> RecordingWindowObservation {
        RecordingWindowObservation(pid: pid, systemID: id, title: "Window \(id)", frame: CGRect(x: x, y: 0, width: 200, height: 200), layer: 0, isOnScreen: visible, zOrder: id)
    }
    func snapshot(_ time: UInt64, _ windows: [RecordingWindowObservation]) -> WorkspaceSnapshotRecord {
        registry.snapshot(timestampNs: time, reason: "test", captureFrame: nil, applicationPID: 42, observations: windows, frontmostPID: 84)
    }
    let first = snapshot(0, [window(1), window(2, x: -1000), window(3, pid: 84)])
    #expect(first.windows.map(\.systemWindowID) == [1, 2])
    #expect(first.applications.map(\.pid) == [42])
    #expect(first.frontmostApplicationID == nil)
    let second = snapshot(100, [window(1, visible: false), window(2, x: -900), window(4)])
    #expect(second.windows.first?.isOnScreen == false)
    #expect(second.removedWindowIDs.isEmpty)
    #expect(second.appearedWindowIDs == ["APP-001:WIN-4"])
    #expect(second.windows[1].id == first.windows[1].id)
    let last = snapshot(200, [window(4)])
    #expect(last.removedWindowIDs == ["APP-001:WIN-1", "APP-001:WIN-2"])
}

@Test("Application input follows the receiving process across windows without collecting another app")
func applicationInputFollowsReceivingProcess() {
    let secondWindowPID = InputRecordingPolicy.receivingPID(eventPID: 42, frontmostPID: 84, hitTestPID: nil, isPointer: true)
    #expect(InputRecordingPolicy.accepts(scope: .application, selectedPID: 42, receivingPID: secondWindowPID))
    let otherApplicationPID = InputRecordingPolicy.receivingPID(eventPID: 84, frontmostPID: 42, hitTestPID: 42, isPointer: true)
    #expect(!InputRecordingPolicy.accepts(scope: .application, selectedPID: 42, receivingPID: otherApplicationPID))
    let occludingWindowPID = InputRecordingPolicy.receivingPID(eventPID: 0, frontmostPID: 42, hitTestPID: 84, isPointer: true)
    #expect(!InputRecordingPolicy.accepts(scope: .application, selectedPID: 42, receivingPID: occludingWindowPID))
    #expect(!InputRecordingPolicy.accepts(scope: .application, selectedPID: 42, receivingPID: nil))
}
