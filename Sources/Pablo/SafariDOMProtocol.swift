import Foundation

public struct PabloSafariDOMBridgeResponse: Sendable {
    public let id: UUID
    public let success: Bool
    public let jsonPayload: Data?
    public let error: String?
}

public enum PabloSafariCommandError: Error, LocalizedError, Sendable, Equatable {
    case rejected(String)
    case permissionRequired(String)
    case staleContext(String)
    case outcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let detail), .permissionRequired(let detail), .staleContext(let detail): return detail
        case .outcomeUnknown(let detail):
            return "The Safari command outcome is unknown: \(detail) Inspect current state before deciding whether to issue another action."
        }
    }
}

public enum PabloSafariDOMProtocol {
    public static func validate(_ request: PabloSafariDOMRequest) throws {
        guard (1...10_000).contains(request.maxNodes) else {
            throw RecordingError.usage("maxNodes must be from 1 to 10000.")
        }
        guard (1...50).contains(request.maxDepth) else {
            throw RecordingError.usage("maxDepth must be from 1 to 50.")
        }
        if let tabID = request.tabID, tabID <= 0 {
            throw RecordingError.usage("tabID must be positive.")
        }
        guard [request.selector, request.nodeID].allSatisfy({ ($0?.utf8.count ?? 0) <= 4_096 }) else {
            throw RecordingError.usage("Safari DOM selectors and node references must be at most 4 KiB.")
        }
        if request.kind.isMutation && !request.kind.isRRWebCommand && request.documentGeneration == nil {
            throw RecordingError.usage("DOM actions require documentGeneration from a fresh inspection.")
        }
        if (request.kind == .listTabs || request.kind.isRRWebCommand), request.documentGeneration != nil {
            throw RecordingError.usage("Tab discovery and rrweb commands do not accept documentGeneration.")
        }
        let selectorCount = [
            request.selector?.isEmpty == false,
            request.nodeID?.isEmpty == false,
        ].filter { $0 }.count
        switch request.kind {
        case .listTabs:
            guard selectorCount == 0, request.value == nil, request.tabID == nil,
                  request.recordingID == nil else {
                throw RecordingError.usage(
                    "listTabs does not accept a tabID, recordingID, selector, nodeID, or value."
                )
            }
        case .startRRWebRecording, .pauseRRWebRecording, .resumeRRWebRecording, .stopRRWebRecording:
            guard selectorCount == 0, request.value == nil,
                  request.tabID.map({ $0 > 0 }) == true, request.recordingID != nil else {
                throw RecordingError.usage(
                    "This rrweb command requires a positive tabID and recordingID and accepts no DOM target."
                )
            }
        case .rrwebRecordingStatus:
            guard selectorCount == 0, request.value == nil,
                  request.tabID.map({ $0 > 0 }) ?? true else {
                throw RecordingError.usage("rrwebRecordingStatus accepts only an optional positive tabID and recordingID.")
            }
        case .dumpDOM, .dumpAccessibilityTree:
            guard selectorCount == 0, request.value == nil, request.recordingID == nil else {
                throw RecordingError.usage("DOM dump commands do not accept selector, nodeID, or value.")
            }
        case .click, .focus, .scrollIntoView:
            guard selectorCount == 1, request.value == nil, request.recordingID == nil else {
                throw RecordingError.usage("This DOM action requires exactly one selector or nodeID and no value.")
            }
        case .setValue:
            guard selectorCount == 1, request.value != nil, request.recordingID == nil else {
                throw RecordingError.usage("setValue requires exactly one selector or nodeID and a value.")
            }
            guard request.value?.utf8.count ?? 0 <= 32 * 1_024 else {
                throw RecordingError.usage("Safari DOM values must be at most 32 KiB.")
            }
        }
    }

    public static func encode(_ request: PabloSafariDOMRequest, id: UUID) throws -> Data {
        try validate(request)
        var command = PabloV3SafariDOMCommand()
        command.id = id.uuidString
        command.kind = request.kind.protobuf
        if let selector = request.selector { command.selector = selector }
        if let nodeID = request.nodeID { command.nodeID = nodeID }
        if let value = request.value { command.value = value }
        command.includeHidden = request.includeHidden
        command.maxNodes = UInt32(request.maxNodes)
        command.maxDepth = UInt32(request.maxDepth)
        if let tabID = request.tabID { command.tabID = tabID }
        if let recordingID = request.recordingID { command.recordingID = recordingID.uuidString }
        if let generation = request.documentGeneration { command.documentGeneration = generation.uuidString }
        return try command.serializedData()
    }

    public static func validateResponse(
        _ response: PabloSafariDOMBridgeResponse, for request: PabloSafariDOMRequest, id: UUID
    ) throws -> Data? {
        guard response.id == id else {
            throw PabloSafariCommandError.outcomeUnknown("The extension returned a mismatched response.")
        }
        guard response.success else {
            let detail = response.error ?? "The Safari extension did not complete the command."
            let payload = response.jsonPayload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if payload?["errorCode"] as? String == "permissionRequired",
               payload?["dispatchStatus"] as? String == "notDispatched" {
                throw PabloSafariCommandError.permissionRequired(payload?["humanAction"] as? String ?? detail)
            }
            if payload?["errorCode"] as? String == "staleContext",
               payload?["dispatchStatus"] as? String == "notDispatched" {
                throw PabloSafariCommandError.staleContext(detail)
            }
            if !request.kind.isMutation || payload?["dispatchStatus"] as? String == "notDispatched" {
                throw PabloSafariCommandError.rejected(detail)
            }
            throw PabloSafariCommandError.outcomeUnknown(detail)
        }
        guard !request.kind.isMutation || response.jsonPayload != nil else {
            throw PabloSafariCommandError.outcomeUnknown("The extension returned no action acknowledgment.")
        }
        return response.jsonPayload
    }

    public static func decodeResponse(_ data: Data) throws -> PabloSafariDOMBridgeResponse {
        let response = try PabloV3SafariDOMResponse(serializedBytes: data)
        guard let id = UUID(uuidString: response.id) else {
            throw RecordingError.capture("The Safari extension returned an invalid response ID.")
        }
        return PabloSafariDOMBridgeResponse(
            id: id,
            success: response.success,
            jsonPayload: response.hasJsonPayload ? response.jsonPayload : nil,
            error: response.hasError ? response.error : nil
        )
    }
}

private extension PabloSafariDOMCommandKind {
    var protobuf: PabloV3SafariDOMCommandKind {
        switch self {
        case .listTabs: .listTabs
        case .startRRWebRecording: .startRrwebRecording
        case .pauseRRWebRecording: .pauseRrwebRecording
        case .resumeRRWebRecording: .resumeRrwebRecording
        case .stopRRWebRecording: .stopRrwebRecording
        case .rrwebRecordingStatus: .rrwebRecordingStatus
        case .dumpDOM: .dumpDom
        case .dumpAccessibilityTree: .dumpAccessibilityTree
        case .click: .click
        case .focus: .focus
        case .setValue: .setValue
        case .scrollIntoView: .scrollIntoView
        }
    }
}
