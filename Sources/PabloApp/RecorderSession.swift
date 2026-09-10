import Foundation
import PabloCore

/// The capture boundary used by the app's shared UI and control lifecycle.
@MainActor
protocol RecorderSession: AnyObject {
    var packageURL: URL { get }
    var scopeName: String { get }
    var durationNs: UInt64 { get }
    var applicationIDs: [String] { get }
    var captureEnded: Bool { get }
    var streamIssues: [PabloRecordingStreamIssue] { get }
    func start() async throws
    func stop() async throws
    func pause()
    func resume()
    func recordAutomationAction(_ action: PabloAutomationActionTrace, actionTargetPID: pid_t?) throws
}

extension RecorderSession {
    var streamIssues: [PabloRecordingStreamIssue] { [] }
}

extension RecordingSession: RecorderSession {}
