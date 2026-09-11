import Foundation
import Testing
@testable import PabloCore

@Test("Local API actions append requested and outcome records without typed text")
func automationActionsAreExplicitAndRedactedInTheEventTrace() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pablo-action-trace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let eventsURL = directory.appendingPathComponent("events.pb")
    let writer = try ProtobufStreamWriter<InputEventRecord>(
        url: eventsURL,
        encode: PabloProtobufCodec.encode
    )
    let actionID = UUID()
    let sessionID = UUID()
    let secretText = "do-not-store-this-text"
    let request = PabloLiveActionRequest(
        kind: .typeText,
        target: .init(appName: "Notes", sessionID: sessionID, windowID: "window-1", frameReference: "LIVE-\(sessionID.uuidString)/A11Y-001"),
        nodeID: "ax-editor",
        text: secretText,
        unlockForegroundActions: true
    )
    let caller = PabloAutomationCaller(
        displayName: "Agent Host",
        applicationIdentifier: "com.example.agent-host",
        developerName: "Example Developer",
        developerTeamIdentifier: "TEAM123",
        verified: true
    )
    let requested = PabloAutomationActionTrace(
        actionID: actionID,
        phase: .requested,
        request: request,
        caller: caller,
        transport: "http+unix",
        recordingWasPaused: false
    )
    let succeeded = PabloAutomationActionTrace(
        actionID: actionID,
        phase: .succeeded,
        request: request,
        caller: caller,
        transport: "http+unix",
        recordingWasPaused: false
    )

    try writer.append(.automationAction(
        timestampNs: 100,
        targetPID: 42,
        applicationID: "APP-001",
        trace: requested
    ))
    try writer.append(.automationAction(
        timestampNs: 200,
        targetPID: 42,
        applicationID: "APP-001",
        trace: succeeded
    ))
    try writer.close()

    let data = try Data(contentsOf: eventsURL)
    #expect(data.range(of: Data(secretText.utf8)) == nil)
    let records = try PabloProtobufCodec.decodeEvents(from: data)
    #expect(records.count == 2)
    #expect(records.map(\.type) == ["automationAction", "automationAction"])
    #expect(records.compactMap { $0.automationAction?.phase } == [.requested, .succeeded])
    #expect(Set(records.compactMap { $0.automationAction?.actionID }) == Set([actionID]))
    #expect(records.allSatisfy { $0.automationAction?.target == request.target })
    #expect(records.allSatisfy { $0.targetPID == 42 })
    #expect(records.allSatisfy { $0.applicationID == "APP-001" })
    #expect(records.allSatisfy { $0.automationAction?.resolvedApplicationID == "APP-001" })
    #expect(records.allSatisfy { $0.text == nil })
    #expect(records.allSatisfy { $0.automationAction?.textLength == secretText.count })
    #expect(records.allSatisfy { $0.automationAction?.foregroundActionsUnlocked == true })
    #expect(records.allSatisfy { $0.automationAction?.caller.verified == true })
    #expect(records.allSatisfy { $0.automationAction?.caller.developerName == "Example Developer" })
}

@Test("Safari action traces preserve the exact tab and document without retaining a typed value")
func safariTracePreservesDocumentTarget() throws {
    let generation = UUID()
    let safari = PabloSafariDOMRequest(kind: .setValue, nodeID: "DOM-element",
        value: "private input", tabID: 73, documentGeneration: generation)
    let request = PabloLiveActionRequest(kind: .perform, target: .init(bundleIdentifier: "com.apple.Safari"),
        nodeID: safari.nodeID, text: safari.value, accessibilityAction: "safari.dom.setValue")
    let caller = PabloAutomationCaller(displayName: "Fixture", applicationIdentifier: "example.fixture",
        developerName: "Fixture Developer", developerTeamIdentifier: "TEAM", verified: true)
    let trace = PabloAutomationActionTrace(actionID: UUID(), phase: .requested, request: request,
        caller: caller, transport: "http+unix", recordingWasPaused: true, safariTarget: .init(safari))
    let event = InputEventRecord.automationAction(timestampNs: 4, targetPID: 100,
        applicationID: "APP-001", trace: trace)
    let bytes = try PabloProtobufCodec.encode(event)
    let restored = try #require(PabloProtobufCodec.decodeEvents(from: bytes).first)
    #expect(restored.automationAction?.safariTarget?.tabID == 73)
    #expect(restored.automationAction?.safariTarget?.documentGeneration == generation)
    #expect(restored.automationAction?.safariTarget?.nodeID == "DOM-element")
    #expect(restored.automationAction?.textLength == 13)
    #expect(bytes.range(of: Data("private input".utf8)) == nil)
}

@Test("Text editing traces preserve operation metadata without phrase, context, or paste contents")
func textEditingTraceRedactsAllTextInputs() throws {
    let target = PabloLiveApplicationTarget(appName: "Fixture")
    let requests = [
        PabloLiveActionRequest(kind: .selectText, target: target, nodeID: "field", text: "secret phrase",
            selection: .init(prefix: "private prefix", suffix: "private suffix", selectionType: .cursorAfter)),
        .init(kind: .setValue, target: target, nodeID: "field", text: "secret replacement"),
        .init(kind: .paste, target: target, nodeID: "field", text: "<b>private HTML</b>",
            pasteFormat: .html, plainText: "private fallback")
    ]
    let caller = PabloAutomationCaller(displayName: "Fixture", applicationIdentifier: "example.fixture",
        developerName: nil, developerTeamIdentifier: nil, verified: false)
    for request in requests {
        let trace = PabloAutomationActionTrace(actionID: UUID(), phase: .requested, request: request,
            caller: caller, transport: "http+unix", recordingWasPaused: true)
        let bytes = try PabloProtobufCodec.encode(InputEventRecord.automationAction(timestampNs: 1, targetPID: 42,
            applicationID: "APP-001", trace: trace))
        let restored = try #require(PabloProtobufCodec.decodeEvents(from: bytes).first?.automationAction)
        #expect(restored.kind == request.kind)
        #expect(restored.textLength == request.text?.count)
        #expect(restored.textOptions == trace.textOptions)
        for secret in [request.text, request.selection?.prefix, request.selection?.suffix, request.plainText].compactMap({ $0 }) {
            #expect(bytes.range(of: Data(secret.utf8)) == nil)
        }
    }
}
