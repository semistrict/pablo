import Foundation

public struct PabloRecordingCompletion: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case native, rrweb }
    public enum State: String, Codable, Sendable { case complete, interrupted, failed }

    public let source: Source
    public let recordingPath: String?
    public let state: State
    public let error: String?
    public let finishedAt: Date
    public let streamIssues: [PabloRecordingStreamIssue]

    public init(source: Source, recordingPath: String?, state: State, error: String? = nil, streamIssues: [PabloRecordingStreamIssue] = []) {
        self.streamIssues = streamIssues
        self.source = source
        self.recordingPath = recordingPath
        self.state = state
        self.error = error
        finishedAt = Date()
    }
}
