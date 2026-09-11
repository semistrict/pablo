import Foundation

public struct PabloLiveActionResult: Codable, Sendable {
    public enum DispatchMethod: String, Codable, Sendable {
        case accessibility, foregroundInput
    }

    public struct Target: Codable, Sendable {
        public let pid: Int32
        public let bundleIdentifier: String?
        public let applicationName: String
        public let sessionID: UUID
        public let windowID: String?
        public let inspectionFrameReference: String?
    }

    public let actionID: UUID
    public let target: Target
    public let dispatchMethod: DispatchMethod
    public let dispatchStatus: String
    public let effectStatus: String
    public let characterCount: Int?
    public let summary: String
    public internal(set) var observation: PabloLiveObservation?
    public internal(set) var observationFailure: ObservationFailure?
    public internal(set) var clipboardRestoration: PabloLiveClipboardRestoration?

    public struct ObservationFailure: Codable, Sendable {
        public let code: PabloControlFailure.Code
        public let message: String

        init(_ error: Error) {
            code = PabloControlFailure(afterDispatch: error).code
            message = "The action was dispatched, but its subsequent observation could not be collected. Inspect the target before deciding whether another action is needed."
        }
    }

    init(actionID: UUID, target: Target, dispatchMethod: DispatchMethod, characterCount: Int?, summary: String) {
        self.actionID = actionID
        self.target = target
        self.dispatchMethod = dispatchMethod
        dispatchStatus = "dispatched"
        effectStatus = "unverified"
        self.characterCount = characterCount
        self.summary = summary
    }
}
