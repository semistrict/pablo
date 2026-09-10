import Foundation
import Testing
@testable import PabloCore

@Test("Safari DOM commands validate bounded targets and values")
func safariDOMCommandsFailClosed() throws {
    try PabloSafariDOMProtocol.validate(.init(kind: .dumpAccessibilityTree))
    try PabloSafariDOMProtocol.validate(.init(kind: .click, nodeID: "DOM-node", documentGeneration: UUID()))
    try PabloSafariDOMProtocol.validate(.init(kind: .setValue, selector: "input", value: "Hello", documentGeneration: UUID()))

    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .click))
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(
            kind: .click,
            selector: "button",
            nodeID: "#submit"
        ))
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .dumpDOM, maxNodes: 10_001))
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .dumpDOM, tabID: 0))
    }
}

@Test("Safari app and extension exchange binary protobuf commands")
func safariDOMBridgeUsesSerializedProtobuf() throws {
    let id = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
    let request = PabloSafariDOMRequest(
        kind: .setValue,
        nodeID: "#editor",
        value: "private text",
        maxNodes: 750,
        maxDepth: 12,
        documentGeneration: id
    )
    let commandData = try PabloSafariDOMProtocol.encode(request, id: id)
    let command = try PabloV3SafariDOMCommand(serializedBytes: commandData)

    #expect(command.id == id.uuidString)
    #expect(command.kind == .setValue)
    #expect(command.nodeID == "#editor")
    #expect(command.value == "private text")
    #expect(command.maxNodes == 750)
    #expect(command.maxDepth == 12)
    #expect(command.documentGeneration == id.uuidString)

    var protobufResponse = PabloV3SafariDOMResponse()
    protobufResponse.id = id.uuidString
    protobufResponse.success = true
    protobufResponse.jsonPayload = Data(#"{"action":"setValue","characterCount":12}"#.utf8)
    let decoded = try PabloSafariDOMProtocol.decodeResponse(protobufResponse.serializedData())

    #expect(decoded.id == id)
    #expect(decoded.success)
    #expect(decoded.jsonPayload == protobufResponse.jsonPayload)
    #expect(decoded.error == nil)
}

@Test("Safari tab discovery and rrweb control use bounded protobuf fields")
func safariRRWebCommandsUseSerializedProtobuf() throws {
    let requestID = UUID()
    let recordingID = UUID()

    let listData = try PabloSafariDOMProtocol.encode(.init(kind: .listTabs), id: requestID)
    let list = try PabloV3SafariDOMCommand(serializedBytes: listData)
    #expect(list.kind == .listTabs)
    #expect(!list.hasTabID)
    #expect(!list.hasRecordingID)

    let startData = try PabloSafariDOMProtocol.encode(
        .init(kind: .startRRWebRecording, tabID: 42, recordingID: recordingID),
        id: requestID
    )
    let start = try PabloV3SafariDOMCommand(serializedBytes: startData)
    #expect(start.kind == .startRrwebRecording)
    #expect(start.tabID == 42)
    #expect(start.recordingID == recordingID.uuidString)

    try PabloSafariDOMProtocol.validate(
        .init(kind: .rrwebRecordingStatus, tabID: 42, recordingID: recordingID)
    )
    try PabloSafariDOMProtocol.validate(.init(kind: .rrwebRecordingStatus))
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .startRRWebRecording, tabID: 42))
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(
            .init(kind: .pauseRRWebRecording, tabID: 0, recordingID: recordingID)
        )
    }
}

@Test("Safari DOM mutations require a document generation before dispatch")
func safariDOMMutationsRequireFreshDocument() throws {
    for kind in [PabloSafariDOMCommandKind.click, .focus, .scrollIntoView, .setValue] {
        #expect(throws: RecordingError.self) {
            try PabloSafariDOMProtocol.validate(.init(kind: kind, selector: "button", value: kind == .setValue ? "hello" : nil))
        }
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .click, selector: String(repeating: "x", count: 4097), documentGeneration: UUID()))
    }
    #expect(throws: RecordingError.self) {
        try PabloSafariDOMProtocol.validate(.init(kind: .listTabs, documentGeneration: UUID()))
    }
}

@Test("A Safari mutation response distinguishes rejection from an uncertain dispatched outcome")
func safariDOMResponsePreservesUnknownOutcome() throws {
    let id = UUID()
    let request = PabloSafariDOMRequest(kind: .click, selector: "button", documentGeneration: UUID())
    let rejected = PabloSafariDOMBridgeResponse(
        id: id, success: false, jsonPayload: Data(#"{"dispatchStatus":"notDispatched"}"#.utf8), error: "stale document"
    )
    #expect(throws: PabloSafariCommandError.rejected("stale document")) {
        _ = try PabloSafariDOMProtocol.validateResponse(rejected, for: request, id: id)
    }
    let uncertain = PabloSafariDOMBridgeResponse(id: id, success: false, jsonPayload: nil, error: "reply lost")
    #expect(throws: PabloSafariCommandError.outcomeUnknown("reply lost")) {
        _ = try PabloSafariDOMProtocol.validateResponse(uncertain, for: request, id: id)
    }
}


@Test("A Safari access rejection preserves its human action without treating later failures as safe to replay")
func safariAccessFailureCarriesHumanAction() throws {
    let id = UUID()
    let request = PabloSafariDOMRequest(kind: .click, selector: "#save", documentGeneration: UUID())
    let payload = Data(#"{"errorCode":"permissionRequired","dispatchStatus":"notDispatched","humanAction":"Unlock the intended tab."}"#.utf8)
    let response = PabloSafariDOMBridgeResponse(id: id, success: false, jsonPayload: payload, error: "Safari has no access.")
    #expect(throws: PabloSafariCommandError.permissionRequired("Unlock the intended tab.")) {
        _ = try PabloSafariDOMProtocol.validateResponse(response, for: request, id: id)
    }
    do {
        _ = try PabloSafariDOMProtocol.validateResponse(response, for: request, id: id)
        Issue.record("A locked tab must reject the command.")
    } catch {
        let failure = PabloControlFailure(afterDispatch: error)
        #expect(failure.code == .permissionRequired)
        #expect(failure.dispatchStatus == .notDispatched)
        #expect(failure.humanAction == "Unlock the intended tab.")
    }
    let afterDispatch = PabloSafariDOMBridgeResponse(id: id, success: false,
        jsonPayload: Data(#"{"errorCode":"permissionRequired","dispatchStatus":"attempted"}"#.utf8), error: "Reply lost.")
    #expect(throws: PabloSafariCommandError.outcomeUnknown("Reply lost.")) {
        _ = try PabloSafariDOMProtocol.validateResponse(afterDispatch, for: request, id: id)
    }
}

@Test("A Safari stale target reaches the control API as stale context only before dispatch")
func safariStaleFailureReachesControlAPI() throws {
    let id = UUID()
    let request = PabloSafariDOMRequest(kind: .click, selector: "#save", documentGeneration: UUID())
    for status in ["notDispatched", "attempted"] {
        let response = PabloSafariDOMBridgeResponse(id: id, success: false,
            jsonPayload: Data("{\"errorCode\":\"staleContext\",\"dispatchStatus\":\"\(status)\"}".utf8),
            error: "The document was replaced.")
        do {
            _ = try PabloSafariDOMProtocol.validateResponse(response, for: request, id: id)
            Issue.record("A rejected Safari action must fail.")
        } catch {
            let failure = PabloControlFailure(afterDispatch: error)
            #expect(failure.code == (status == "notDispatched" ? .staleContext : .outcomeUnknown))
            #expect(failure.dispatchStatus == (status == "notDispatched" ? .notDispatched : .outcomeUnknown))
        }
    }
}
