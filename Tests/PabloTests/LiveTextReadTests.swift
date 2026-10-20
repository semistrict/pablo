import Foundation
import Testing
@testable import PabloCore

private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

private func page(_ value: String, offset: Int = 0, maxLength: Int, fingerprint: String? = nil) throws -> LiveTextPage {
    try LiveTextPage(sessionID: session, value: value,
                     options: .init(nodeID: "node", offset: offset, maxLength: maxLength, fingerprint: fingerprint))
}

@Test("Live text pages reconstruct a value longer than the snapshot cap")
func liveTextPagesReconstructLongValues() throws {
    let value = String(repeating: "diff line\n", count: 1_000) + "END"
    var collected = ""
    var offset: Int? = 0
    var fingerprint: String?
    var pages = 0
    while let next = offset {
        let current = try page(value, offset: next, maxLength: 4_000, fingerprint: fingerprint)
        collected += current.text
        fingerprint = current.fingerprint
        offset = current.nextOffset
        pages += 1
    }
    #expect(collected == value)
    #expect(pages == 3)
    let first = try page(value, maxLength: 4_000)
    #expect(first.length == 4_000)
    #expect(first.totalLength == 10_003)
    #expect(first.nextOffset == 4_000)
}

@Test("Live text pages use UTF-16 offsets without splitting surrogate pairs")
func liveTextPagesPreserveSurrogatePairs() throws {
    let value = "a🙂b"
    let first = try page(value, maxLength: 2)
    #expect(first.text == "a")
    #expect(first.length == 1)
    #expect(first.nextOffset == 1)

    let pair = try page(value, offset: 1, maxLength: 1)
    #expect(pair.text == "🙂")
    #expect(pair.length == 2)
    #expect(pair.nextOffset == 3)

    let last = try page(value, offset: 3, maxLength: 10)
    #expect(last.text == "b")
    #expect(last.totalLength == 4)
    #expect(last.nextOffset == nil)

    #expect(throws: RecordingError.usage("Text offset 2 splits a character. Continue from a returned nextOffset.")) {
        try page(value, offset: 2, maxLength: 10)
    }
}

@Test("Live text pages reject offsets past the value and empty values end immediately")
func liveTextPageBounds() throws {
    let empty = try page("", maxLength: 10)
    #expect(empty.text == "")
    #expect(empty.totalLength == 0)
    #expect(empty.nextOffset == nil)
    let end = try page("abc", offset: 3, maxLength: 10)
    #expect(end.text == "")
    #expect(end.nextOffset == nil)
    #expect(throws: RecordingError.usage("Text offset 4 exceeds the value length of 3 UTF-16 code units.")) {
        try page("abc", offset: 4, maxLength: 10)
    }
}

@Test("A changed value fails instead of mixing pages from different versions")
func liveTextPageDetectsChangedValue() throws {
    let original = try page("before", maxLength: 3)
    #expect(original.fingerprint == "6db7d803e74f1ffa7d8f5adc0bf95b3e15bf4c8373fffadf546227cc6c6742cb")
    #expect(throws: RecordingError.staleContext(
        "The text of live node node changed since the previous page. Read it again from offset 0."
    )) {
        try page("after!", offset: 3, maxLength: 3, fingerprint: original.fingerprint)
    }
    #expect(try page("before", offset: 3, maxLength: 3, fingerprint: original.fingerprint).text == "ore")
}

@Test("Text read options are validated at the app boundary")
func liveTextReadOptionsValidate() throws {
    let target = PabloLiveApplicationTarget(appName: "Chrome")
    try PabloLiveInspectionRequest(kind: .text, target: target, textRead: .init(nodeID: "node")).validate()
    #expect(throws: RecordingError.usage("A live text request requires textRead options, which apply only to kind text.")) {
        try PabloLiveInspectionRequest(kind: .text, target: target).validate()
    }
    #expect(throws: RecordingError.usage("A live text request requires textRead options, which apply only to kind text.")) {
        try PabloLiveInspectionRequest(kind: .frames, target: target, textRead: .init(nodeID: "node")).validate()
    }
    #expect(throws: RecordingError.usage("maxLength must be from 1 to 1000000 UTF-16 code units.")) {
        try PabloLiveTextReadOptions(nodeID: "node", maxLength: 1_000_001).validate()
    }
    #expect(throws: RecordingError.usage("The text offset must be zero or greater.")) {
        try PabloLiveTextReadOptions(nodeID: "node", offset: -1).validate()
    }
    #expect(throws: RecordingError.usage("A text fingerprint must be the 64-character lowercase hex value from a previous page.")) {
        try PabloLiveTextReadOptions(nodeID: "node", fingerprint: "ABC").validate()
    }
}

@Test("The local API decodes text reads with defaults")
func liveTextReadAPIPayload() throws {
    let request = try PabloControlRequest.decodePayload(method: .inspectLive, data: Data(
        #"{"kind":"text","target":{"appName":"Chrome"},"textRead":{"nodeID":"node"}}"#.utf8
    ))
    #expect(request.liveInspectionRequest?.textRead == .init(nodeID: "node", offset: 0, maxLength: 100_000))
    #expect(throws: Error.self) {
        try PabloControlRequest.decodePayload(method: .inspectLive, data: Data(#"{"kind":"text","target":{"appName":"Chrome"}}"#.utf8))
    }
}

@Test("pablo text builds a live text request")
func liveTextCLIRequest() throws {
    let session = UUID()
    let fingerprint = String(repeating: "a", count: 64)
    guard case .liveInspection(let request) = try CLI.parse([
        "text", "--app", "Chrome", "--session", session.uuidString, "--node", "node",
        "--offset", "100000", "--max-length", "5000", "--fingerprint", fingerprint,
    ]) else {
        Issue.record("Expected a live inspection request"); return
    }
    #expect(request.kind == .text)
    #expect(request.target.sessionID == session)
    #expect(request.textRead == .init(nodeID: "node", offset: 100_000, maxLength: 5_000, fingerprint: fingerprint))
    #expect(throws: RecordingError.self) { try CLI.parse(["text", "--app", "Chrome"]) }
    #expect(throws: RecordingError.self) { try CLI.parse(["text", "Recording.pablo", "--node", "node"]) }
    #expect(throws: RecordingError.self) { try CLI.parse(["frames", "--app", "Chrome", "--node", "node"]) }
}
