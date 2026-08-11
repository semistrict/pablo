import Darwin
import Foundation
import Testing
@testable import PabloCore

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var current: Int {
        lock.withLock { value }
    }
}

@Test("Approval lasts for one calling application and one calendar day")
func approvalIsScopedToApplicationAndDay() throws {
    let suiteName = "pablo-control-approval-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let approvals = PabloDailyApprovalStore(
        defaults: defaults,
        storageKey: "test-approvals",
        calendar: calendar
    )
    let morning = Date(timeIntervalSince1970: 1_787_639_400)
    let evening = morning.addingTimeInterval(60 * 60 * 8)
    let tomorrow = morning.addingTimeInterval(60 * 60 * 24)

    let firstDeveloper = "signed:TEAM-A:com.example.Caller"
    let otherDeveloper = "signed:TEAM-B:com.example.Caller"
    #expect(!approvals.isApprovedToday(applicationIdentity: firstDeveloper, now: morning))
    approvals.approveForToday(applicationIdentity: firstDeveloper, now: morning)
    #expect(approvals.isApprovedToday(applicationIdentity: firstDeveloper, now: evening))
    #expect(!approvals.isApprovedToday(applicationIdentity: otherDeveloper, now: evening))
    #expect(!approvals.isApprovedToday(applicationIdentity: firstDeveloper, now: tomorrow))
}

@Test("Caller identity comes from the nearest invoking application, not the CLI")
func callerIdentityUsesInvokingApplication() {
    let parents: [pid_t: pid_t] = [900: 800, 800: 700, 700: 600, 600: 1]
    let applications: [pid_t: String] = [700: "Terminal", 600: "Finder"]

    let caller = PabloProcessChain.nearestApplication(
        invokedBy: 900,
        parentProcessIdentifier: { parents[$0] },
        applicationIdentity: { applications[$0] }
    )

    #expect(caller == "Terminal")
}

@Test("The local control socket handles one request per connection and is private")
func controlSocketRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let requestCount = LockedCount()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        requestCount.increment()
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                target: nil,
                recordingPath: nil,
                elapsedNanoseconds: 0
            )
        )
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    try server.start()
    let first = try PabloControlClient.send(
        PabloControlRequest(method: .status),
        socketPath: socketPath
    )
    let second = try PabloControlClient.send(
        PabloControlRequest(method: .status),
        socketPath: socketPath
    )

    #expect(first.result?.state == "idle")
    #expect(second.result?.state == "idle")
    #expect(requestCount.current == 2)
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    ).intValue
    let socketMode = try #require(
        FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber
    ).intValue
    #expect(directoryMode & 0o777 == 0o700)
    #expect(socketMode & 0o777 == 0o600)
}
