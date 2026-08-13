import Testing
@testable import PabloCore

@Test("A recycled PID receives a new recording application identity")
func recycledPIDGetsNewApplicationIdentity() throws {
    let registry = RecordingApplicationRegistry()
    let firstProcess = RecordingProcessIdentity(startSeconds: 100, startMicroseconds: 1)
    let secondProcess = RecordingProcessIdentity(startSeconds: 200, startMicroseconds: 2)

    let first = try #require(registry.application(
        for: 42,
        timestampNs: 10,
        processIdentity: firstProcess
    ))
    let repeated = try #require(registry.application(
        for: 42,
        timestampNs: 20,
        processIdentity: firstProcess
    ))
    let recycled = try #require(registry.application(
        for: 42,
        timestampNs: 30,
        processIdentity: secondProcess
    ))

    #expect(first.id == "APP-001")
    #expect(repeated.id == first.id)
    #expect(recycled.id == "APP-002")
    #expect(registry.allApplications().first(where: { $0.id == first.id })?.lastSeenTimestampNs == 30)
}
