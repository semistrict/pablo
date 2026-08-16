import Foundation
import Testing
@testable import PabloCore

@Test("Safari DOM commands validate bounded targets and values")
func safariDOMCommandsFailClosed() throws {
    try PabloSafariDOMProtocol.validate(.init(kind: .dumpAccessibilityTree))
    try PabloSafariDOMProtocol.validate(.init(kind: .click, nodeID: "#submit"))
    try PabloSafariDOMProtocol.validate(.init(kind: .setValue, selector: "input", value: "Hello"))

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
        maxDepth: 12
    )
    let commandData = try PabloSafariDOMProtocol.encode(request, id: id)
    let command = try PabloV3SafariDOMCommand(serializedBytes: commandData)

    #expect(command.id == id.uuidString)
    #expect(command.kind == .setValue)
    #expect(command.nodeID == "#editor")
    #expect(command.value == "private text")
    #expect(command.maxNodes == 750)
    #expect(command.maxDepth == 12)

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
