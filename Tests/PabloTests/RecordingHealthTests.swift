import Foundation
import Testing
@testable import PabloCore
@testable import PabloApp

@Test("Stopping input drains the current delivery and rejects later callbacks")
func inputStopDrainsPendingDelivery() async throws {
    let gate = InputDeliveryGate()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let delivered = Task.detached {
        gate.deliver { started.signal(); release.wait() }
    }
    #expect(await waitForInputSignal(started, timeout: 2) == .success)
    let stopped = DispatchSemaphore(value: 0)
    let stop = Task.detached { gate.stopAndDrain(); stopped.signal() }
    #expect(await waitForInputSignal(stopped, timeout: 0.05) == .timedOut)
    release.signal()
    await delivered.value
    await stop.value
    #expect(await waitForInputSignal(stopped, timeout: 2) == .success)
    var lateDelivery = false
    gate.deliver { lateDelivery = true }
    #expect(!lateDelivery)
}

@Test("A stream write failure remains visible even after later writes succeed")
func recordingStreamFailuresRemainDegraded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let health = RecordingHealthTracker()
    let writer = try ProtobufStreamWriter<Int>(url: directory.appendingPathComponent("fixture.pb"), encode: { value in
        if value < 0 { throw RecordingError.capture("fixture encoding failed") }
        return Data([UInt8(value)])
    }, onFailure: { error in health.recordFailure(stream: .input, timestampNs: 25, error: error) })
    #expect(throws: (any Error).self) { try writer.append(-1) }
    try writer.append(1)
    try writer.close()
    #expect(throws: (any Error).self) { try writer.append(2) }
    #expect(health.issues.count == 1)
    #expect(health.issues.first?.stream == .input)
    #expect(health.issues.first?.failureCount == 2)
    #expect(health.issues.first?.firstFailureTimestampNs == 25)
    #expect(throws: (any Error).self) { try health.requireComplete() }
    var manifest = testManifest()
    manifest.streamIssues = health.issues
    #expect(try JSONDecoder().decode(RecordingManifest.self, from: JSONEncoder().encode(manifest)).streamIssues == health.issues)
}

@MainActor
private final class DegradedCaptureSession: RecorderSession {
    let packageURL = URL(fileURLWithPath: "/tmp/DegradedFixture.pablo")
    let scopeName = "Fixture"
    let durationNs: UInt64 = 100
    let applicationIDs: [String] = []
    let captureEnded = false
    let health = RecordingHealthTracker()
    var streamIssues: [PabloRecordingStreamIssue] { health.issues }
    func start() async throws { health.recordFailure(stream: .accessibility, timestampNs: 50, error: RecordingError.capture("fixture disk failure")) }
    func stop() async throws {}
    func pause() {}
    func resume() {}
    func recordAutomationAction(_ action: PabloAutomationActionTrace, actionTargetPID: pid_t?) throws {}
}

@MainActor
@Test("Recording status and final completion cannot hide degraded evidence")
func recordingStatusExposesStreamDegradation() async throws {
    let fixture = DegradedCaptureSession()
    let model = RecorderModel(startsServices: false, makeSession: { _ in fixture })
    var options = RecordOptions()
    options.scope = .display
    try await model.beginRecording(options)
    #expect(model.controlResult().streamIssues?.first?.stream == .accessibility)
    await #expect(throws: (any Error).self) { try await model.stopRecording() }
    #expect(model.controlResult().lastRecordingCompletion?.state == .interrupted)
    #expect(model.controlResult().lastRecordingCompletion?.streamIssues.first?.stream == .accessibility)
}


private func waitForInputSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}
