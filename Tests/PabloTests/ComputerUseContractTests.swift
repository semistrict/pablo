import Foundation
import Testing
@testable import PabloCore

@Test("Computer-use CLI commands retain observation, selection, and clipboard options")
func computerUseCLIOptions() throws {
    let session = UUID()
    let reference = "LIVE-\(session)/A11Y-001"
    guard case .liveObservation(let state) = try CLI.parse(["observe", "state", "--app", "Fixture", "--session", session.uuidString,
        "--window", "window", "--since-frame", reference, "--screenshot", "--settle-ms", "200", "--timeout-ms", "500"]) else {
        Issue.record("Expected live observation"); return
    }
    #expect(state.kind == .observe)
    #expect(state.target.windowID == "window")
    #expect(state.observation == .init(baselineReference: reference, screenshot: true, quietMilliseconds: 200, timeoutMilliseconds: 500))
    guard case .liveAction(let selection) = try CLI.parse(["select-text", "--app", "Fixture", "--node", "field", "--text", "phrase",
        "--prefix", "second ", "--selection-type", "cursorAfter", "--observe"]) else {
        Issue.record("Expected selection action"); return
    }
    #expect(selection.kind == .selectText)
    #expect(selection.selection == .init(prefix: "second ", selectionType: .cursorAfter))
    #expect(selection.observation != nil)
    guard case .liveAction(let clear) = try CLI.parse(["set-value", "--app", "Fixture", "--node", "field", "--text", ""]) else {
        Issue.record("Expected value replacement"); return
    }
    #expect(clear.text == "")
    guard case .liveAction(let paste) = try CLI.parse(["paste", "--app", "Fixture", "--text", "<b>Heading</b>",
        "--format", "html", "--plain-text", "Heading", "--unlock-foreground-actions"]) else {
        Issue.record("Expected paste action"); return
    }
    #expect(paste.pasteFormat == .html)
    #expect(paste.plainText == "Heading")
    #expect(paste.unlockForegroundActions)
    #expect(throws: RecordingError.self) { try CLI.parse(["inspect", "--app", "Fixture", "--screenshot"]) }
}

@Test("The local API decodes observation and new text actions before execution")
func computerUseAPIPayloadValidation() throws {
    let observation = try PabloControlRequest.decodePayload(method: .inspectLive, data: Data(#"{"kind":"observe","target":{"appName":"Fixture"},"observation":{"full":true,"quietMilliseconds":0,"timeoutMilliseconds":0}}"#.utf8))
    #expect(observation.liveInspectionRequest?.observation?.full == true)
    let action = try PabloControlRequest.decodePayload(method: .actLive, data: Data(#"{"kind":"selectText","target":{"appName":"Fixture"},"nodeID":"field","text":"phrase","selection":{"selectionType":"cursorBefore"},"observation":{}}"#.utf8))
    #expect(action.liveActionRequest?.selection?.selectionType == .cursorBefore)
    #expect(action.liveActionRequest?.observation == .init())
    #expect(throws: Error.self) {
        try PabloControlRequest.decodePayload(method: .actLive, data: Data(#"{"kind":"selectText","target":{"appName":"Fixture"},"text":"phrase"}"#.utf8))
    }
    #expect(throws: Error.self) {
        try PabloControlRequest.decodePayload(method: .inspectLive, data: Data(#"{"kind":"events","target":{"appName":"Fixture"},"observation":{}}"#.utf8))
    }
}
