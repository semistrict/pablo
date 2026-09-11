import Foundation

public struct PabloControlFailure: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidRequest, denied, awaitingHuman, permissionRequired, targetUnavailable, staleContext, busy, cancelled, interrupted, failed, outcomeUnknown
    }
    public enum DispatchStatus: String, Codable, Sendable { case notDispatched, outcomeUnknown }
    public let code: Code
    public let dispatchStatus: DispatchStatus
    public let humanAction: String?

    public init(code: Code, dispatchStatus: DispatchStatus, humanAction: String? = nil) {
        self.code = code
        self.dispatchStatus = dispatchStatus
        self.humanAction = humanAction
    }

    /// Dispatch may already have produced effects; a typed cause does not imply rollback.
    public init(afterDispatch error: Error) {
        if let paste = error as? LivePasteFailure {
            self.init(afterDispatch: paste.underlying)
            return
        }
        // This type is emitted only for an extension acknowledgment of no dispatch.
        if case PabloSafariCommandError.permissionRequired = error {
            self.init(code: .permissionRequired, dispatchStatus: .notDispatched,
                      humanAction: error.localizedDescription)
            return
        }
        // The extension confirms that a stale DOM target was rejected before input.
        if case PabloSafariCommandError.staleContext = error {
            self.init(code: .staleContext, dispatchStatus: .notDispatched)
            return
        }
        let code: Code
        switch error {
        case is CancellationError, RecordingError.interrupted: code = .interrupted
        case RecordingError.permission, PabloSafariCommandError.permissionRequired: code = .permissionRequired
        case RecordingError.targetNotFound: code = .targetUnavailable
        case RecordingError.staleContext: code = .staleContext
        default: code = .outcomeUnknown
        }
        self.init(code: code, dispatchStatus: .outcomeUnknown,
                  humanAction: code == .permissionRequired ? error.localizedDescription : nil)
    }
}
