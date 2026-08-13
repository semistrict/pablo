import Foundation
import Testing
@testable import PabloCore

@Test("CLI actions append requested and outcome records without typed text")
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
    let secretText = "do-not-store-this-text"
    let request = PabloLiveActionRequest(
        kind: .typeText,
        target: .init(appName: "Notes"),
        nodeID: "ax-editor",
        text: secretText
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
        transport: "pabloCLI",
        recordingWasPaused: false
    )
    let succeeded = PabloAutomationActionTrace(
        actionID: actionID,
        phase: .succeeded,
        request: request,
        caller: caller,
        transport: "pabloCLI",
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
    #expect(records.allSatisfy { $0.targetPID == 42 })
    #expect(records.allSatisfy { $0.applicationID == "APP-001" })
    #expect(records.allSatisfy { $0.automationAction?.resolvedApplicationID == "APP-001" })
    #expect(records.allSatisfy { $0.text == nil })
    #expect(records.allSatisfy { $0.automationAction?.textLength == secretText.count })
    #expect(records.allSatisfy { $0.automationAction?.caller.verified == true })
    #expect(records.allSatisfy { $0.automationAction?.caller.developerName == "Example Developer" })
}
