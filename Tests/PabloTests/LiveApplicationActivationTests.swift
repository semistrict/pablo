import ApplicationServices
import Testing
@testable import PabloCore

@MainActor
private final class ActivatableApplicationFixture: LiveActivatableApplication {
    var isTerminated = false
    var frontmostStatus = AXError.success
    /// `isActive` reads after the frontmost request until the target reports active; zero means already active.
    var readsUntilActive: Int?
    private(set) var frontmostRequests = 0
    private var readsSinceRequest = 0

    var isActive: Bool {
        guard let readsUntilActive else { return false }
        if readsUntilActive == 0 { return true }
        guard frontmostRequests > 0 else { return false }
        readsSinceRequest += 1
        return readsSinceRequest >= readsUntilActive
    }

    func requestFrontmost() -> AXError {
        frontmostRequests += 1
        return frontmostStatus
    }
}

@MainActor
@Test("An already active target is not asked to come forward")
func liveActivationSkipsActiveTarget() async throws {
    let application = ActivatableApplicationFixture()
    application.readsUntilActive = 0
    try await LiveApplicationActivation.activate(application, pollInterval: .zero)
    #expect(application.frontmostRequests == 0)
}

@MainActor
@Test("Activation asks Accessibility once and waits for the target to become active")
func liveActivationRequestsFrontmostOnce() async throws {
    let application = ActivatableApplicationFixture()
    application.readsUntilActive = 3
    try await LiveApplicationActivation.activate(application, pollInterval: .zero, attempts: 5)
    #expect(application.frontmostRequests == 1)
}

@MainActor
@Test("A rejected accessibility activation fails without waiting")
func liveActivationRejectionFailsClosed() async throws {
    let application = ActivatableApplicationFixture()
    application.frontmostStatus = .cannotComplete
    application.readsUntilActive = 1
    await #expect(throws: RecordingError.capture(
        "The target application rejected accessibility activation (AXFrontmost error -25204)."
    )) {
        try await LiveApplicationActivation.activate(application, pollInterval: .zero)
    }
    #expect(application.frontmostRequests == 1)
}

@MainActor
@Test("A target that never becomes active fails after the polling budget")
func liveActivationTimesOut() async throws {
    let application = ActivatableApplicationFixture()
    application.readsUntilActive = 4
    await #expect(throws: RecordingError.capture("The target application did not become active.")) {
        try await LiveApplicationActivation.activate(application, pollInterval: .zero, attempts: 3)
    }
    #expect(application.frontmostRequests == 1)
}

@MainActor
@Test("A terminated target is reported missing before activation")
func liveActivationRejectsTerminatedTarget() async throws {
    let application = ActivatableApplicationFixture()
    application.isTerminated = true
    await #expect(throws: RecordingError.targetNotFound("The target application stopped running before activation.")) {
        try await LiveApplicationActivation.activate(application, pollInterval: .zero)
    }
    #expect(application.frontmostRequests == 0)
}
