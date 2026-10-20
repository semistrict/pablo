import AppKit
import ApplicationServices

@MainActor
protocol LiveActivatableApplication {
    var isTerminated: Bool { get }
    var isActive: Bool { get }
    /// Asks the application to become frontmost through its accessibility element.
    func requestFrontmost() -> AXError
}

/// Brings a live target forward for an Accessibility client that is never itself active.
///
/// macOS 14 cooperative activation honors `NSRunningApplication.activate` only when the active
/// application yields, so a menu-bar agent acting while another app is frontmost is refused.
/// Setting `AXFrontmost` on the target's application element does not depend on that yield.
@MainActor
enum LiveApplicationActivation {
    static func activate(
        _ application: some LiveActivatableApplication,
        pollInterval: Duration = .milliseconds(50),
        attempts: Int = 20
    ) async throws {
        guard !application.isTerminated else {
            throw RecordingError.targetNotFound("The target application stopped running before activation.")
        }
        if application.isActive { return }
        let status = application.requestFrontmost()
        guard status == .success else {
            throw RecordingError.capture(
                "The target application rejected accessibility activation (AXFrontmost error \(status.rawValue))."
            )
        }
        for _ in 0..<attempts {
            if application.isActive { return }
            try await Task.sleep(for: pollInterval)
        }
        throw RecordingError.capture("The target application did not become active.")
    }
}

struct NativeLiveActivatableApplication: LiveActivatableApplication {
    let application: NSRunningApplication

    var isTerminated: Bool { application.isTerminated }
    var isActive: Bool { application.isActive }

    func requestFrontmost() -> AXError {
        // Address the existing process. Opening its bundle could relaunch an app the human just quit.
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(application.processIdentifier),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
    }
}
