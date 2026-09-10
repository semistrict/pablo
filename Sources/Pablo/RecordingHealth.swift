import Foundation

public enum PabloRecordingStream: String, Codable, Sendable { case input, accessibility, workspace, video, manifest }

public struct PabloRecordingStreamIssue: Codable, Equatable, Sendable {
    public let stream: PabloRecordingStream
    public var failureCount: UInt64
    public let firstFailureTimestampNs: UInt64
    public var lastFailureTimestampNs: UInt64
    public var lastError: String
}

/// Failures are sticky for the life of one capture, even if subsequent writes recover.
final class RecordingHealthTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var byStream: [PabloRecordingStream: PabloRecordingStreamIssue] = [:]

    var issues: [PabloRecordingStreamIssue] {
        lock.withLock { byStream.values.sorted { $0.stream.rawValue < $1.stream.rawValue } }
    }

    func recordFailure(stream: PabloRecordingStream, timestampNs: UInt64, error: Error) {
        lock.withLock {
            var issue = byStream[stream] ?? .init(stream: stream, failureCount: 0,
                firstFailureTimestampNs: timestampNs, lastFailureTimestampNs: timestampNs, lastError: "")
            if issue.failureCount < UInt64.max { issue.failureCount += 1 }
            issue.lastFailureTimestampNs = timestampNs
            issue.lastError = String(error.localizedDescription.prefix(1_024))
            byStream[stream] = issue
        }
    }

    func requireComplete() throws {
        let failures = issues
        guard failures.isEmpty else {
            throw RecordingError.capture("Recording evidence is incomplete: " + failures.map { $0.stream.rawValue }.joined(separator: ", ") + ". The package was retained for inspection.")
        }
    }
}
