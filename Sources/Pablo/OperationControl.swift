import Foundation

public struct PabloOperationExecuteRequest: Codable, Sendable {
    public let serviceID: UUID
    public let operationID: UUID
    public let issuedAt: Date
    public let method: PabloControlMethod
    public let payload: PabloControlOutput

    public init(serviceID: UUID, operationID: UUID = UUID(), issuedAt: Date = Date(),
                method: PabloControlMethod, payload: PabloControlOutput = .object([:])) {
        self.serviceID = serviceID
        self.operationID = operationID
        self.issuedAt = issuedAt
        self.method = method
        self.payload = payload
    }

    public func validatedRequest() throws -> PabloControlRequest {
        switch method {
        case .startRecording, .pauseRecording, .resumeRecording, .stopRecording,
             .addAnnotation, .resolveAnnotation, .actLive, .safariDOM,
             .rrwebStart, .rrwebPause, .rrwebResume, .rrwebStop, .rrwebRecover, .openRecording: break
        default:
            throw RecordingError.usage("operation.execute accepts recording, annotation, live action, Safari mutation, and recording.open methods. Review commands have their own receipt contract.")
        }
        let data = try JSONEncoder().encode(payload)
        let request = try PabloControlRequest.decodePayload(method: method, data: data)
        if method == .safariDOM, request.safariDOMRequest?.kind.isMutation != true {
            throw RecordingError.usage("Only Safari mutations use operation.execute.")
        }
        return request
    }
}

public struct PabloOperationLookupRequest: Codable, Sendable {
    public let serviceID: UUID
    public let operationID: UUID
    public init(serviceID: UUID, operationID: UUID) {
        self.serviceID = serviceID
        self.operationID = operationID
    }
}

public struct PabloOperationReceipt: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case awaitingHuman, running, cancellationRequested, completed, rejected, interrupted, outcomeUnknown
    }
    public let serviceID: UUID
    public let operationID: UUID
    public let method: PabloControlMethod
    public var status: Status
    public let expiresAt: Date
    public var response: PabloControlResponse?
    public var resultOmitted: Bool

    public init(serviceID: UUID, operationID: UUID, method: PabloControlMethod, expiresAt: Date) {
        self.serviceID = serviceID
        self.operationID = operationID
        self.method = method
        self.expiresAt = expiresAt
        status = .awaitingHuman
        response = nil
        resultOmitted = false
    }
}
