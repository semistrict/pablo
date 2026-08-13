import Foundation
import Testing
@testable import PabloCore

@Test("Protobuf streams preserve record boundaries and optional values")
func protobufStreamRoundTrip() throws {
    let first = InputEventRecord(
        schemaVersion: 2,
        timestampNs: 10,
        type: "mouseDown",
        targetPID: 42,
        x: 1.5,
        y: 2.5,
        deltaX: nil,
        deltaY: nil,
        keyCode: nil,
        text: nil,
        flags: 0,
        button: 0,
        clickCount: 1,
        automationAction: nil
    )
    let second = InputEventRecord(
        schemaVersion: 2,
        timestampNs: 20,
        type: "keyDown",
        targetPID: nil,
        x: nil,
        y: nil,
        deltaX: nil,
        deltaY: nil,
        keyCode: 12,
        text: "q",
        flags: 1,
        button: nil,
        clickCount: nil,
        automationAction: nil
    )
    var stream = try PabloProtobufCodec.encode(first)
    stream.append(try PabloProtobufCodec.encode(second))

    let decoded = try PabloProtobufCodec.decodeEvents(from: stream)
    #expect(decoded.count == 2)
    #expect(decoded[0].timestampNs == 10)
    #expect(decoded[0].targetPID == 42)
    #expect(decoded[0].x == 1.5)
    #expect(decoded[0].text == nil)
    #expect(decoded[1].timestampNs == 20)
    #expect(decoded[1].targetPID == nil)
    #expect(decoded[1].text == "q")
    #expect(try ProtobufStream.count(in: stream) == 2)
}

@Test("Truncated and invalid protobuf stream framing fails closed")
func invalidProtobufFramingFailsClosed() throws {
    let record = InputEventRecord(
        schemaVersion: 2,
        timestampNs: 1,
        type: "mouseUp",
        targetPID: nil,
        x: nil,
        y: nil,
        deltaX: nil,
        deltaY: nil,
        keyCode: nil,
        text: nil,
        flags: 0,
        button: nil,
        clickCount: nil,
        automationAction: nil
    )
    var truncated = try PabloProtobufCodec.encode(record)
    truncated.removeLast()
    #expect(throws: RecordingError.self) {
        try PabloProtobufCodec.decodeEvents(from: truncated)
    }
    #expect(throws: RecordingError.self) {
        try ProtobufStream.count(in: Data(repeating: 0x80, count: 10))
    }
}

@Test("The control bridge uses protobuf protocol version two")
func controlBridgeUsesProtobufV2() throws {
    let request = PabloControlRequest(method: .status)
    let encoded = try PabloProtobufCodec.encode(request)
    #expect(encoded.first != Character("{").asciiValue)
    let decoded = try PabloProtobufCodec.decodeControlRequest(from: encoded)
    #expect(decoded.id == request.id)
    #expect(decoded.protocolVersion == 2)
    #expect(decoded.method == .status)
}
