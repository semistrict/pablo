import Foundation
import Testing
@testable import PabloApp
@testable import PabloCore

@MainActor
private final class FailingCaptureSession: RecorderSession {
    let packageURL = URL(fileURLWithPath: "/tmp/Fixture.pablo")
    let scopeName = "Fixture"
    let durationNs: UInt64 = 2_000_000_000
    let applicationIDs: [String] = []
    let captureEnded = false
    func start() async throws {}
    func stop() async throws { throw RecordingError.capture("fixture finalization failed") }
    func pause() {}
    func resume() {}
    func recordAutomationAction(_ action: PabloAutomationActionTrace, actionTargetPID: pid_t?) throws {}
}

@MainActor
private final class FailingSafariBridge: PabloSafariBridging {
    let spool: PabloRRWebSpoolStore?
    let acknowledgedEventCount: Int64
    init(spool: PabloRRWebSpoolStore? = nil, acknowledgedEventCount: Int64 = 1) {
        self.spool = spool
        self.acknowledgedEventCount = acknowledgedEventCount
    }
    func listTabs() async throws -> [PabloSafariTab] { [] }
    func perform(_ request: PabloSafariDOMRequest) async throws -> PabloControlOutput {
        .object([
            "recordingID": .string(request.recordingID!.uuidString),
            "status": .string("stopped"), "eventCount": .integer(acknowledgedEventCount), "nextSequence": .integer(1),
        ])
    }
    func prepareSpool(recordingID: UUID) throws {}
    func removeSpool(recordingID: UUID) throws {
        guard let spool else { Issue.record("A failed finalization must retain its spool."); return }
        try spool.remove(recordingID: recordingID)
    }
    func eventBatches(recordingID: UUID, expectedNextSequence: Int64?, expectedEventCount: Int?) throws -> [Data] {
        guard let spool else { throw RecordingError.capture("fixture spool unavailable") }
        return try spool.eventBatches(recordingID: recordingID,
                                     expectedNextSequence: expectedNextSequence, expectedEventCount: expectedEventCount)
    }
    func recordingError(recordingID: UUID) throws -> String? { nil }
}

@MainActor
@Test("Web stop only marks acknowledged, durable evidence complete", arguments: [true, false])
func webStopVerifiesDeliveryBeforeCompleting(matchesReceipt: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: recordingID, tab: .init(id: 42, title: "Fixture", url: "https://example.test"),
        directory: directory
    )
    let spool = PabloRRWebSpoolStore(rootDirectory: directory.appendingPathComponent("spool"))
    try spool.prepare(recordingID: recordingID)
    try spool.storeEventBatch(recordingID: recordingID, sequence: 0, events: [["type": 2, "timestamp": 1000]])
    let model = RecorderModel(startsServices: false, safariBridge: FailingSafariBridge(
        spool: spool, acknowledgedEventCount: matchesReceipt ? 1 : 2
    ))
    model.activeRRWebRecording = recording
    do {
        try await model.stopRRWebRecording()
        #expect(matchesReceipt)
    } catch {
        #expect(!matchesReceipt)
        #expect(error is PabloRRWebSpoolError)
    }
    let finalized = try PabloRRWebRecordingStorage.load(recording.packageURL)
    #expect(finalized.manifest.state == (matchesReceipt ? .complete : .interrupted))
    #expect(finalized.manifest.eventCount == 1)
    #expect(model.activeRRWebRecording == nil)
    #expect(model.controlResult().lastRecordingCompletion?.state == (matchesReceipt ? .complete : .interrupted))
    #expect(FileManager.default.fileExists(atPath: spool.recordingDirectory(recordingID: recordingID).path) == !matchesReceipt)
}

@MainActor
@Test("A web stop with unreadable evidence fails visibly and preserves the package for recovery")
func webFinalizationFailureReachesCaller() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: PabloSafariTab(id: 42, title: "Fixture", url: "https://example.test"),
        directory: directory
    )
    let model = RecorderModel(startsServices: false, safariBridge: FailingSafariBridge())
    model.activeRRWebRecording = recording
    do {
        try await model.stopRRWebRecording()
        Issue.record("Unavailable web evidence must not be reported as a successful stop.")
    } catch {
        #expect(error.localizedDescription.contains("fixture spool unavailable"))
    }
    #expect(model.activeRRWebRecording?.packageURL == recording.packageURL)
    #expect(model.errorMessage?.contains("fixture spool unavailable") == true)
    #expect(try PabloRRWebRecordingStorage.load(recording.packageURL).manifest.state != .complete)
}

@MainActor
@Test("An invalid recording target leaves the shared lifecycle ready for another start")
func recorderInitializationFailureRestoresIdle() async throws {
    let model = RecorderModel(startsServices: false)
    var options = RecordOptions()
    options.pid = Int32.max
    do {
        try await model.beginRecording(options)
        Issue.record("The nonexistent target must be rejected.")
    } catch {}
    #expect(model.status == .idle)
    #expect(model.canStartScreen)
    #expect(model.activeScopeName == nil)
    #expect(model.controlResult().lastRecordingCompletion?.state == .failed)
}

@MainActor
@Test("Finalization failure reaches callers after the shared recorder returns to idle")
func recorderFinalizationFailureReachesCaller() async throws {
    let capture = FailingCaptureSession()
    let model = RecorderModel(startsServices: false, makeSession: { _ in capture })
    var options = RecordOptions()
    options.scope = .display
    try await model.beginRecording(options)
    do {
        try await model.stopRecording()
        Issue.record("A failed finalization must not acknowledge a successful stop.")
    } catch {
        #expect(error.localizedDescription.contains("fixture finalization failed"))
    }
    #expect(model.status == .idle)
    #expect(model.errorMessage?.contains("fixture finalization failed") == true)
    #expect(model.lastRecordingURL == capture.packageURL)
    #expect(model.activeScopeName == nil)
    let outcome = try #require(model.controlResult().lastRecordingCompletion)
    #expect(outcome.state == .failed)
    #expect(outcome.recordingPath == capture.packageURL.path)
    #expect(outcome.error?.contains("fixture finalization failed") == true)
}

@MainActor
private final class LifecycleSafariBridge: PabloSafariBridging {
    var tabs: [PabloSafariTab] = []
    var tabFailure: Error?
    var tabRequests = 0
    var suspendTabs = false
    var pendingTabs: CheckedContinuation<Void, Never>?
    var requests: [PabloSafariDOMRequest] = []
    var failure: Error? = RecordingError.capture("fixture acknowledgment lost")
    var suspended = false
    var pending: CheckedContinuation<Void, Never>?
    var removedSpools: [UUID] = []
    var preparedSpools: [UUID] = []
    var spool: PabloRRWebSpoolStore?
    var eventBatchError: Error?
    func listTabs() async throws -> [PabloSafariTab] {
        tabRequests += 1
        if suspendTabs { await withCheckedContinuation { pendingTabs = $0 } }
        if let tabFailure { throw tabFailure }
        return tabs
    }
    func perform(_ request: PabloSafariDOMRequest) async throws -> PabloControlOutput {
        requests.append(request)
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        let status: String
        switch request.kind {
        case .pauseRRWebRecording: status = "paused"
        case .stopRRWebRecording: status = "stopped"
        default: status = "recording"
        }
        return .object([
            "recordingID": .string(request.recordingID!.uuidString), "status": .string(status),
            "eventCount": .integer(0), "nextSequence": .integer(0),
        ])
    }
    func prepareSpool(recordingID: UUID) throws { preparedSpools.append(recordingID) }
    func removeSpool(recordingID: UUID) throws { removedSpools.append(recordingID) }
    func eventBatches(recordingID: UUID, expectedNextSequence: Int64?, expectedEventCount: Int?) throws -> [Data] {
        if let eventBatchError { throw eventBatchError }
        return try spool?.eventBatches(recordingID: recordingID, expectedNextSequence: expectedNextSequence, expectedEventCount: expectedEventCount) ?? []
    }
    func recordingError(recordingID: UUID) throws -> String? { nil }
}

@MainActor
@Test("Visible recording targets update after unlock and navigation without erasing recording errors")
func recordingTargetsRefreshAutomatically() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = LifecycleSafariBridge()
    let model = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    let now = Date()
    model.errorMessage = "Recording finalization failed"
    await model.refreshRecordingTargetsIfNeeded(now: now)
    #expect(model.safariTabs.isEmpty)
    bridge.tabs = [.init(id: 42, title: "Unlocked page", url: "https://example.test")]
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(1))
    #expect(model.safariTabs.map(\.title) == ["Unlocked page"])
    bridge.tabs = [] // Navigation ends the activeTab grant.
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(2))
    #expect(model.safariTabs.isEmpty)
    bridge.tabFailure = RecordingError.capture("Safari is unavailable")
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(3))
    #expect(model.safariTabsError?.contains("Safari is unavailable") == true)
    #expect(model.errorMessage == "Recording finalization failed")
    bridge.tabFailure = nil
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(4))
    #expect(model.safariTabsError == nil)
    #expect(model.errorMessage == "Recording finalization failed")
}

@MainActor
@Test("Recording target polling coalesces multiple visible views and never overlaps bridge requests")
func recordingTargetsCoalescePolling() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = LifecycleSafariBridge()
    bridge.suspendTabs = true
    let model = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    let now = Date()
    let first = Task { await model.refreshRecordingTargetsIfNeeded(now: now) }
    for _ in 0..<100 where bridge.pendingTabs == nil { await Task.yield() }
    #expect(bridge.pendingTabs != nil)
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(2))
    await model.refreshSafariTabs()
    #expect(bridge.tabRequests == 1)
    bridge.pendingTabs?.resume()
    await first.value
    bridge.suspendTabs = false
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(0.5))
    #expect(bridge.tabRequests == 1)
    await model.refreshRecordingTargetsIfNeeded(now: now.addingTimeInterval(2))
    #expect(bridge.tabRequests == 2)
}

@MainActor
@Test("A missing web stop acknowledgment retains active recovery context and does not finalize evidence")
func webUnknownStopRetainsRecoveryContext() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), directory: directory
    )
    let bridge = LifecycleSafariBridge()
    let model = RecorderModel(startsServices: false, safariBridge: bridge)
    model.activeRRWebRecording = recording
    do { try await model.stopRRWebRecording(); Issue.record("A missing stop acknowledgment must throw.") }
    catch { #expect(error.localizedDescription.contains("acknowledgment lost")) }
    #expect(model.activeRRWebRecording?.manifest.recordingID == recording.manifest.recordingID)
    #expect(try PabloRRWebRecordingStorage.load(recording.packageURL).manifest.state == .recording)
    #expect(bridge.removedSpools.isEmpty)
    #expect(model.lastRecordingURL == nil)
}

@MainActor
@Test("A pending or ambiguously acknowledged web start reserves its package and blocks another start")
func webStartReservesRecoveryContextBeforeAwait() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = LifecycleSafariBridge()
    bridge.suspended = true
    let model = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    let tab = PabloSafariTab(id: 42, title: "Fixture", url: "https://example.test")
    let first = Task { try await model.startRRWebRecording(tab: tab) }
    while bridge.pending == nil { await Task.yield() }
    let package = try #require(model.activeRRWebRecording?.packageURL)
    #expect(model.rrwebIsActive)
    #expect(model.rrwebTransition == .starting)
    do { try await model.startRRWebRecording(tab: tab); Issue.record("Concurrent start must be rejected.") }
    catch { #expect(bridge.requests.count == 1) }
    bridge.pending?.resume()
    bridge.pending = nil
    do { try await first.value; Issue.record("A lost start acknowledgment must reach the caller.") }
    catch { #expect(error.localizedDescription.contains("acknowledgment lost")) }
    #expect(model.activeRRWebRecording?.packageURL == package)
    #expect(FileManager.default.fileExists(atPath: package.path))
    #expect(bridge.removedSpools.isEmpty)
    #expect(model.rrwebRecoveryNeeded)
    bridge.suspended = false
    for _ in 0..<4 { await model.refreshActiveRRWebStatus(reportErrors: false) }
    #expect(model.activeRRWebRecording?.packageURL == package)
    #expect(try PabloRRWebRecordingStorage.load(package).manifest.state == .recording)
    #expect(bridge.removedSpools.isEmpty)
    #expect(model.lastRecordingURL == nil)
}

@Test("Service readiness is available without approval and excludes private recording state")
@MainActor
func serviceReadinessBeforeApproval() async throws {
    let model = RecorderModel(startsServices: false)
    model.lastRecordingURL = URL(fileURLWithPath: "/private/recording.pablo")
    let response = await model.handleControlRequest(.init(method: .serviceInfo),
        from: .init(processIdentifier: nil, userIdentifier: getuid()))
    #expect(response.error == nil)
    let result = try #require(response.result)
    #expect(result.recordingPath == nil)
    let data = try JSONEncoder().encode(result.output)
    let info = try JSONDecoder().decode(PabloServiceInfo.self, from: data)
    #expect(info.approval.state == .humanActionRequired)
    #expect(info.approval.verified == false)
    #expect(info.methods.contains("targets.list"))
    #expect(info.permissions.count == 4)
    #expect(info.permissions.allSatisfy { $0.state == .granted || $0.humanAction != nil })
}

@Test("Selecting an unresolved Safari package preserves every other package and spool")
@MainActor
func safariRecoverySelectionPreservesOrphans() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let bridge = LifecycleSafariBridge()
    let first = try PabloRRWebRecordingStorage.create(recordingID: UUID(),
        tab: .init(id: 1, title: "First", url: "https://example.test/first"), directory: directory)
    let second = try PabloRRWebRecordingStorage.create(recordingID: UUID(),
        tab: .init(id: 2, title: "Second", url: "https://example.test/second"), directory: directory)
    let model = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    try model.selectRRWebRecovery(recordingID: first.manifest.recordingID)
    try model.selectRRWebRecovery(recordingID: second.manifest.recordingID)
    #expect(model.activeRRWebRecording?.manifest.recordingID == second.manifest.recordingID)
    #expect(model.rrwebRecoveryNeeded)
    #expect(try PabloRRWebRecordingStorage.load(first.packageURL).manifest.state == .recording)
    #expect(try PabloRRWebRecordingStorage.load(second.packageURL).manifest.state == .recording)
    #expect(bridge.requests.isEmpty)
    #expect(bridge.removedSpools.isEmpty)
    let healthy = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    healthy.activeRRWebRecording = first
    #expect(throws: Error.self) { try healthy.selectRRWebRecovery(recordingID: second.manifest.recordingID) }
    #expect(healthy.activeRRWebRecording?.manifest.recordingID == first.manifest.recordingID)
}


@MainActor
@Test("Missing Safari extension has actionable readiness guidance without disguising other failures")
func safariMissingExtensionHasHumanAction() {
    let missing = PabloSafariDOMBridge.extensionReadinessError(NSError(domain: "SFErrorDomain", code: 1))
    guard case RecordingError.permission(let detail) = missing else {
        Issue.record("Missing extension must report its human setup requirement")
        return
    }
    #expect(detail.contains("matching Pablo app"))
    #expect(detail.contains("Settings > Extensions"))
    #expect(detail.contains("unlock the intended tab"))
    let interrupted = NSError(domain: "SFErrorDomain", code: 3)
    #expect((PabloSafariDOMBridge.extensionReadinessError(interrupted) as NSError) == interrupted)
}

@MainActor
@Test("Explicit recovery saves interrupted Safari evidence, retains its spool, and permits another recording")
func webRecoveryCanFinishWithoutDestroyedRecorder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = try PabloRRWebRecordingStorage.create(recordingID: UUID(),
        tab: .init(id: 42, title: "Closed tab", url: "https://example.test"), directory: directory)
    let bridge = LifecycleSafariBridge()
    let spool = PabloRRWebSpoolStore(rootDirectory: directory.appendingPathComponent("spool"))
    bridge.spool = spool
    try spool.prepare(recordingID: recording.manifest.recordingID)
    try spool.storeEventBatch(recordingID: recording.manifest.recordingID, sequence: 0,
        events: [["type": 2, "timestamp": 1000], ["type": 3, "timestamp": 2000]])
    let model = RecorderModel(startsServices: false, safariBridge: bridge, rrwebDirectory: directory)
    model.activeRRWebRecording = recording
    do { try await model.finishRRWebRecovery(recordingID: recording.manifest.recordingID); Issue.record("Healthy recordings must not be abandoned") }
    catch {}
    do { try await model.stopRRWebRecording(); Issue.record("The destroyed recorder cannot acknowledge stop") }
    catch {}
    #expect(model.rrwebRecoveryNeeded)
    do { try await model.finishRRWebRecovery(recordingID: UUID()); Issue.record("A stale recording ID must not finalize the selected package") }
    catch {}
    bridge.eventBatchError = RecordingError.capture("Fixture spool cannot be read")
    do { try await model.finishRRWebRecovery(recordingID: recording.manifest.recordingID); Issue.record("Unreadable evidence must leave recovery active") }
    catch {}
    #expect(model.activeRRWebRecording?.manifest.recordingID == recording.manifest.recordingID)
    #expect(model.rrwebRecoveryNeeded)
    #expect(try PabloRRWebRecordingStorage.load(recording.packageURL).manifest.state == .recording)
    bridge.eventBatchError = nil
    let commandCount = bridge.requests.count
    try await model.finishRRWebRecovery(recordingID: recording.manifest.recordingID)
    #expect(bridge.requests.count == commandCount)
    let saved = try PabloRRWebRecordingStorage.load(recording.packageURL)
    #expect(saved.manifest.state == .interrupted)
    #expect(saved.manifest.eventCount == 2)
    #expect(model.activeRRWebRecording == nil)
    #expect(!model.rrwebRecoveryNeeded)
    #expect(model.lastRecordingCompletion?.state == .interrupted)
    #expect(try spool.eventBatches(recordingID: recording.manifest.recordingID).count == 1)
    #expect(bridge.removedSpools.isEmpty)
    bridge.failure = nil
    try await model.startRRWebRecording(tab: .init(id: 43, title: "New tab", url: "https://example.test/next"))
    #expect(model.activeRRWebRecording?.manifest.tab.id == 43)
    #expect(model.activeRRWebRecording?.manifest.recordingID != recording.manifest.recordingID)
}
