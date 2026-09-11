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

private actor PendingControlHandler {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

// Socket clients and subprocess waits block threads. Keep them off the cooperative
// executor that must also run the server handlers and release the pending mutation.
private func blockingControlTask<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) -> Task<T, Error> {
    Task {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

@Test("Discovery and status remain responsive while another operation is pending")
func controlPendingHandlerDoesNotBlockReads() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-concurrent-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let pending = PendingControlHandler()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        if request.method == .pauseRecording { await pending.wait() }
        if request.method == .cancelReviewOperation { await pending.release() }
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil, elapsedNanoseconds: 0))
    }
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    try server.start()
    let mutation = blockingControlTask {
        try PabloControlClient.send(.init(method: .pauseRecording), socketPath: socketPath)
    }
    for _ in 0..<100 {
        if await pending.entered { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await pending.entered)
    let discovery = try await blockingControlTask { try runCurl(socketPath: socketPath, arguments: [
        "--max-time", "1", "http://localhost/openapi.json"
    ]) }.value
    #expect(discovery.status == 0)
    let status = try await blockingControlTask { try runCurl(socketPath: socketPath, arguments: [
        "--max-time", "1", "http://localhost/record.status"
    ]) }.value
    #expect(status.status == 0)
    let cancellation = try await blockingControlTask { try runCurl(socketPath: socketPath, arguments: [
        "--max-time", "1", "--data", "{\"serviceID\":\"\(UUID().uuidString)\",\"operationID\":\"\(UUID().uuidString)\"}",
        "http://localhost/review.cancel"
    ]) }.value
    #expect(cancellation.status == 0)
    await pending.release()
    _ = try await mutation.value
}

@Test("A slow response reader does not stall discovery, and mutations remain serialized")
func controlSlowReaderAndMutationSerialization() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-slow-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let pending = PendingControlHandler()
    let mutations = LockedCount()
    let reads = LockedCount()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        if request.method == .pauseRecording { mutations.increment(); await pending.wait() }
        if request.method == .resumeRecording { mutations.increment() }
        if request.method == .status { reads.increment() }
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil, elapsedNanoseconds: 0,
            output: request.method == .status ? .string(String(repeating: "x", count: 8_000_000)) : nil))
    }
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    try server.start()
    let first = blockingControlTask { try PabloControlClient.send(.init(method: .pauseRecording), socketPath: socketPath) }
    for _ in 0..<100 {
        if await pending.entered { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let second = blockingControlTask { try PabloControlClient.send(.init(method: .resumeRecording), socketPath: socketPath) }
    let slowReader = blockingControlTask {
        try runCurl(socketPath: socketPath, arguments: ["--max-time", "2", "--limit-rate", "1", "http://localhost/record.status"])
    }
    for _ in 0..<100 {
        if reads.current > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let discovery = try await blockingControlTask {
        try runCurl(socketPath: socketPath, arguments: ["--max-time", "1", "http://localhost/openapi.json"])
    }.value
    #expect(discovery.status == 0)
    #expect(mutations.current == 1)
    await pending.release()
    _ = try await first.value
    _ = try await second.value
    #expect(mutations.current == 2)
    _ = try await slowReader.value
}

@Test("Review context and commands retain their typed identity across the HTTP boundary")
func reviewControlRoundTrip() throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-review-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let reviewID = UUID()
    let serviceID = UUID()
    let sourceGeneration = UUID()
    let command = PabloReviewCommandRequest(reviewID: reviewID, serviceID: serviceID,
        issuedAt: Date(timeIntervalSince1970: 1_789_050_000), expectedSourceGeneration: sourceGeneration,
        expectedRevision: 42, command: .init(kind: .seek, seconds: 1.25))
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        if request.method == .reviewCommand { #expect(request.reviewCommandRequest == command) }
        if request.method == .reviewState { #expect(request.reviewStateRequest?.reviewID == reviewID) }
        var state = PabloReviewState(reviewID: reviewID)
        state.serviceID = serviceID
        state.revision = 42
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil, elapsedNanoseconds: 0,
            output: try! JSONDecoder().decode(PabloControlOutput.self, from: JSONEncoder().encode(state))))
    }
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    try server.start()
    for request in [PabloControlRequest(method: .reviewCommand, reviewCommandRequest: command),
                    PabloControlRequest(method: .reviewState, reviewStateRequest: .init(reviewID: reviewID))] {
        let response = try PabloControlClient.send(request, socketPath: socketPath)
        let output = try #require(response.result?.output)
        let state = try JSONDecoder().decode(PabloReviewState.self, from: JSONEncoder().encode(output))
        #expect(state.reviewID == reviewID)
        #expect(state.serviceID == serviceID)
        #expect(state.revision == 42)
    }
}

private func runCurl(
    socketPath: String,
    arguments: [String],
    input: Data? = nil
) throws -> (status: Int32, output: Data) {
    let inputPipe = Pipe()
    // The OpenAPI body can exceed a pipe buffer. Let curl finish independently
    // of this synchronous fixture reader, including while tests run in parallel.
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("pablo-curl-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "--silent", "--show-error", "--fail-with-body", "--unix-socket", socketPath,
    ] + arguments
    process.standardInput = inputPipe
    process.standardOutput = output
    process.standardError = output
    try process.run()
    if let input {
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        try Data(contentsOf: outputURL)
    )
}

@Test("Malformed live and recording requests are rejected before dispatch and leave control usable")
func controlRejectsInvalidBoundsBeforeDispatch() throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-bounds-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let dispatched = LockedCount()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        dispatched.increment()
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil, elapsedNanoseconds: 0
        ))
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    try server.start()
    let invalid: [(String, String)] = [
        ("inspect.live", #"{"kind":"events","target":{"pid":123},"limit":-1}"#),
        ("inspect.live", #"{"kind":"events","target":{"pid":123},"limit":0}"#),
        ("inspect.live", #"{"kind":"events","target":{"pid":123},"limit":10001}"#),
        ("inspect.live", #"{"kind":"inspect","target":{}}"#),
        ("inspect.live", #"{"kind":"inspect","target":{"pid":123,"appName":"Notes"}}"#),
        ("inspect.live", #"{"kind":"inspect","target":{"appName":"  "}}"#),
        ("record.start", #"{"scope":"display","framesPerSecond":9223372036854775807}"#),
        ("record.start", #"{"scope":"display","framesPerSecond":0}"#),
        ("record.start", #"{"scope":"display","duration":-1}"#),
        ("record.start", #"{"scope":"display","duration":1e100}"#),
        ("record.start", #"{"scope":"display","snapshotInterval":-1}"#),
        ("record.start", #"{"scope":"display","pid":123}"#),
        ("record.start", #"{"scope":"application"}"#),
    ]
    for (endpoint, body) in invalid {
        let response = try runCurl(socketPath: socketPath, arguments: [
            "--data-binary", "@-", "http://localhost/\(endpoint)",
        ], input: Data(body.utf8))
        #expect(response.status == 22, "Expected HTTP rejection for \(body)")
    }
    #expect(dispatched.current == 0)
    let status = try PabloControlClient.send(PabloControlRequest(method: .status), socketPath: socketPath)
    #expect(status.result?.state == "idle")
    #expect(dispatched.current == 1)
}

@Test("A lost mutation response is never retried by automatic app startup")
func controlDoesNotRepeatDeliveredMutation() throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-retry-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let mutations = LockedCount()
    let launches = LockedCount()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        mutations.increment()
        // Fail response encoding only after the first mutation took place.
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil,
            elapsedNanoseconds: 0, output: mutations.current == 1 ? .number(.nan) : .null
        ))
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    try server.start()
    do {
        _ = try PabloControlClient.sendStartingAppIfNeeded(
            PabloControlRequest(method: .stopRecording), socketPath: socketPath,
            startApp: { launches.increment() }
        )
        Issue.record("An unacknowledged mutation must report an unknown outcome.")
    } catch PabloControlTransportError.outcomeUnknown {
        // The operation happened once, and callers are explicitly told not to retry it.
    }
    #expect(mutations.current == 1)
    #expect(launches.current == 0)
}

@Test("Automatic app startup retries only a connection that has not delivered a request")
func controlStartsUnavailableAppWithoutRepeatingRequests() throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-start-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    let requests = LockedCount()
    var launches = 0
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        requests.increment()
        return PabloControlResponse(id: request.id, result: PabloControlResult(
            state: "idle", scopeName: nil, applicationIDs: [], recordingPath: nil, elapsedNanoseconds: 0
        ))
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let response = try PabloControlClient.sendStartingAppIfNeeded(
        PabloControlRequest(method: .status), socketPath: socketPath,
        startApp: { launches += 1; try server.start() }
    )
    #expect(response.result?.state == "idle")
    #expect(requests.current == 1)
    #expect(launches == 1)
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
    approvals.approveForToday(applicationIdentity: otherDeveloper, now: morning)
    #expect(approvals.approvedIdentities(now: evening) == [firstDeveloper, otherDeveloper])
    approvals.revoke(applicationIdentity: firstDeveloper)
    #expect(!approvals.isApprovedToday(applicationIdentity: firstDeveloper, now: evening))
    #expect(approvals.isApprovedToday(applicationIdentity: otherDeveloper, now: evening))
    #expect(approvals.approvedIdentities(now: tomorrow).isEmpty)
    approvals.revokeAll()
    #expect(approvals.approvedIdentities(now: evening).isEmpty)
}

@Test("Caller identity comes from the nearest invoking application, not the helper process")
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

@Test("App-bundled helpers resolve to the outer owning application bundle")
func applicationBundleOwnerUsesOutermostBundle() {
    #expect(
        PabloProcessChain.owningApplicationBundleURL(
            forExecutablePath: "/Applications/Example.app/Contents/Resources/runner"
        )?.path == "/Applications/Example.app"
    )
    #expect(
        PabloProcessChain.owningApplicationBundleURL(
            forExecutablePath: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        )?.path == "/Applications/Example.app"
    )
    #expect(PabloProcessChain.owningApplicationBundleURL(forExecutablePath: "/usr/bin/curl") == nil)
}

@Test("The kernel process table supplies a parent when ordinary process inspection cannot")
func kernelProcessTableSuppliesParent() {
    #expect(PabloProcessChain.kernelParentProcessIdentifier(of: getpid()) == getppid())
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
                scopeName: nil,
                applicationIDs: [],
                recordingPath: nil,
                elapsedNanoseconds: 0,
                lastRecordingCompletion: .init(
                    source: .native, recordingPath: "/tmp/Fixture.pablo", state: .failed, error: "fixture finalization failed"
                )
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
    #expect(first.result?.lastRecordingCompletion?.state == .failed)
    #expect(first.result?.lastRecordingCompletion?.recordingPath == "/tmp/Fixture.pablo")
    #expect(first.result?.lastRecordingCompletion?.error == "fixture finalization failed")
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

@Test("The control endpoint routes bodyless curl calls independently of the HTTP verb")
func controlSocketAcceptsCurlJSON() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-curl-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        #expect(request.method == .status)
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: nil,
                applicationIDs: [],
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

    let curl = try runCurl(
        socketPath: socketPath,
        arguments: [
            "http://localhost\(PabloControlSocket.endpoint(for: .status))",
        ]
    )
    let patch = try runCurl(
        socketPath: socketPath,
        arguments: [
            "-X", "PATCH",
            "http://localhost\(PabloControlSocket.endpoint(for: .status))",
        ]
    )

    #expect(curl.status == 0, Comment(rawValue: String(decoding: curl.output, as: UTF8.self)))
    #expect(patch.status == 0, Comment(rawValue: String(decoding: patch.output, as: UTF8.self)))
    let response = try PabloControlJSONCodec.decode(PabloControlResponse.self, from: curl.output)
    #expect(response.result?.state == "idle")
}

@Test("Curl -d sends a direct JSON payload without a Content-Type requirement")
func controlSocketAcceptsInlineCurlData() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-curl-data-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        #expect(request.method == .inspectLive)
        #expect(request.liveInspectionRequest?.kind == .frames)
        #expect(request.liveInspectionRequest?.target.appName == "Notes")
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: "Notes",
                applicationIDs: ["APP-001"],
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

    let curl = try runCurl(
        socketPath: socketPath,
        arguments: [
            "-d", #"{"kind":"frames","target":{"appName":"Notes"}}"#,
            "http://localhost\(PabloControlSocket.endpoint(for: .inspectLive))",
        ]
    )

    #expect(curl.status == 0, Comment(rawValue: String(decoding: curl.output, as: UTF8.self)))
    let response = try PabloControlJSONCodec.decode(PabloControlResponse.self, from: curl.output)
    #expect(response.result?.scopeName == "Notes")
}

@Test("Compact method payloads receive documented defaults")
func compactControlPayloadReceivesDefaults() throws {
    let data = Data("""
    {
      "kind": "click",
      "target": {"appName": "Notes"},
      "nodeID": "ax-save"
    }
    """.utf8)

    let action = try PabloControlJSONCodec.decode(PabloLiveActionRequest.self, from: data)
    #expect(action.mouseButton == .left)
    #expect(action.clickCount == 1)
    #expect(action.duration == 0.5)
    #expect(action.scrollAmount == 3)
    #expect(action.modifiers.isEmpty)
    #expect(action.unlockForegroundActions == false)
}

@Test("Control responses contain pretty-printed structured JSON output")
func controlResponseContainsStructuredJSON() throws {
    let response = PabloControlResponse(
        id: UUID(),
        result: PabloControlResult(
            state: "idle",
            scopeName: "Notes",
            applicationIDs: ["APP-001"],
            recordingPath: nil,
            elapsedNanoseconds: 0,
            output: .array([
                .object(["reference": .string("A11Y-001")]),
            ])
        )
    )

    let data = try PabloControlJSONCodec.encode(response)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\n  \"id\""))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    let output = try #require(result["output"] as? [[String: Any]])
    #expect(output.first?["reference"] as? String == "A11Y-001")
}

@Test("The control socket serves its generated OpenAPI document")
func controlSocketServesOpenAPI() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-openapi-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        PabloControlResponse(id: request.id, error: "Unexpected control call.")
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    try server.start()

    let curl = try runCurl(
        socketPath: socketPath,
        arguments: ["http://localhost\(PabloControlSocket.openAPIEndpoint)"]
    )

    #expect(curl.status == 0, Comment(rawValue: String(decoding: curl.output, as: UTF8.self)))
    let document = try #require(
        JSONSerialization.jsonObject(with: curl.output) as? [String: Any]
    )
    #expect(document["openapi"] as? String == "3.1.0")
    let paths = try #require(document["paths"] as? [String: Any])
    #expect(paths[PabloControlSocket.endpoint(for: .status)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .actLive)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .safariDOM)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .safariTabs)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebStart)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebPause)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebResume)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebStop)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebStatus)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebRecordings)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .openRecording)] != nil)
    #expect(paths[PabloControlSocket.endpoint(for: .rrwebInspect)] != nil)
    #expect(paths[PabloControlSocket.openAPIEndpoint] != nil)
    let components = try #require(document["components"] as? [String: Any])
    let schemas = try #require(components["schemas"] as? [String: Any])
    let liveAction = try #require(schemas["LiveActionRequest"] as? [String: Any])
    let properties = try #require(liveAction["properties"] as? [String: Any])
    let unlock = try #require(properties["unlockForegroundActions"] as? [String: Any])
    #expect(unlock["default"] as? Bool == false)
    #expect((unlock["description"] as? String)?.contains("NOT RECOMMENDED") == true)
    let rrwebStart = try #require(schemas["RRWebStartRequest"] as? [String: Any])
    #expect(rrwebStart["required"] as? [String] == ["tabID"])
    let rrwebManifest = try #require(schemas["RRWebRecordingManifest"] as? [String: Any])
    let rrwebProperties = try #require(rrwebManifest["properties"] as? [String: Any])
    let version = try #require(rrwebProperties["schemaVersion"] as? [String: Any])
    let runtimeManifest = PabloRRWebRecordingManifest(
        recordingID: UUID(), tab: .init(id: 42, title: "Fixture", url: "https://example.test"), startedAt: Date()
    )
    #expect(version["const"] as? Int == runtimeManifest.schemaVersion)
    let masked = try #require(rrwebProperties["inputsMasked"] as? [String: Any])
    #expect(masked["const"] as? Bool == true)
    #expect(schemas["SafariTabsOutput"] != nil)
    #expect(schemas["RRWebStatusOutput"] != nil)
    #expect(schemas["RRWebRecordingsOutput"] != nil)
    #expect(schemas["RRWebInspectionOutput"] != nil)
}

@Test("rrweb requests cross the JSON control socket with server-generated IDs")
func rrwebControlRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-rrweb-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let requestCount = LockedCount()
    let recordingID = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        requestCount.increment()
        switch request.method {
        case .safariTabs:
            #expect(request.rrwebRequest == nil)
        case .rrwebStart:
            #expect(request.rrwebRequest?.tabID == 42)
            #expect(request.rrwebRequest?.recordingID == nil)
        case .rrwebInspect:
            #expect(request.rrwebRequest?.recordingID == recordingID)
            #expect(request.rrwebRequest?.includeEvents == true)
            #expect(request.rrwebRequest?.eventLimit == 25)
        default:
            Issue.record("Unexpected rrweb control method \(request.method)")
        }
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: "Safari",
                applicationIDs: [],
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

    _ = try PabloControlClient.send(
        PabloControlRequest(method: .safariTabs),
        socketPath: socketPath
    )
    _ = try PabloControlClient.send(
        PabloControlRequest(
            method: .rrwebStart,
            rrwebRequest: PabloRRWebControlRequest(tabID: 42)
        ),
        socketPath: socketPath
    )
    _ = try PabloControlClient.send(
        PabloControlRequest(
            method: .rrwebInspect,
            rrwebRequest: PabloRRWebControlRequest(
                recordingID: recordingID,
                includeEvents: true,
                eventLimit: 25
            )
        ),
        socketPath: socketPath
    )

    #expect(requestCount.current == 3)
}

@Test("rrweb JSON requests apply compact defaults")
func rrwebJSONDefaults() throws {
    let start = try PabloControlJSONCodec.decode(
        PabloRRWebControlRequest.self,
        from: Data(#"{"tabID":42}"#.utf8)
    )
    #expect(start.tabID == 42)
    #expect(start.recordingID == nil)
    #expect(start.includeEvents == false)
    #expect(start.eventLimit == 1_000)

    try start.validate(for: .rrwebStart)
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(tabID: 42, recordingID: UUID()).validate(for: .rrwebStart)
    }
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(
            recordingPath: "/tmp/Recording.pablo",
            recordingID: UUID()
        ).validate(for: .rrwebInspect)
    }
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(recordingID: UUID(), eventLimit: 10_001)
            .validate(for: .rrwebInspect)
    }
}

@Test("recording.open carries only a unified pablo package path")
func recordingOpenControlRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-open-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let expectedPath = "/tmp/Session.pablo"
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        #expect(request.method == .openRecording)
        #expect(request.recordingOpenRequest?.recordingPath == expectedPath)
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: nil,
                applicationIDs: [],
                recordingPath: expectedPath,
                elapsedNanoseconds: 0
            )
        )
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    try server.start()

    _ = try PabloControlClient.send(
        PabloControlRequest(
            method: .openRecording,
            recordingOpenRequest: PabloRecordingOpenRequest(recordingPath: expectedPath)
        ),
        socketPath: socketPath
    )
}

@Test("Safari DOM requests cross the JSON control socket with documented defaults")
func safariDOMControlRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-safari-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        #expect(request.method == .safariDOM)
        #expect(request.safariDOMRequest?.kind == .dumpAccessibilityTree)
        #expect(request.safariDOMRequest?.includeHidden == false)
        #expect(request.safariDOMRequest?.maxNodes == 2_000)
        #expect(request.safariDOMRequest?.maxDepth == 20)
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: "Safari",
                applicationIDs: [],
                recordingPath: nil,
                elapsedNanoseconds: 0,
                output: .object(["kind": .string("accessibility")])
            )
        )
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    try server.start()

    let response = try PabloControlClient.send(
        PabloControlRequest(
            method: .safariDOM,
            safariDOMRequest: .init(kind: .dumpAccessibilityTree)
        ),
        socketPath: socketPath
    )
    #expect(response.result?.output == .object(["kind": .string("accessibility")]))
}

@Test("Live inspection requests and output cross the control socket")
func liveInspectionControlRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-live-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let output = String(repeating: "accessibility-node\n", count: 5_000)
    let structuredOutput = PabloControlOutput.object([
        "nodes": .array([.string(output)]),
    ])
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        #expect(request.method == .inspectLive)
        #expect(request.liveInspectionRequest?.kind == .frame)
        #expect(request.liveInspectionRequest?.target.appName == "Notes")
        #expect(request.liveInspectionRequest?.reference == "A11Y-001")
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: "Notes",
                applicationIDs: ["APP-001"],
                recordingPath: nil,
                elapsedNanoseconds: 0,
                output: structuredOutput
            )
        )
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    try server.start()
    let response = try PabloControlClient.send(
        PabloControlRequest(
            method: .inspectLive,
            liveInspectionRequest: PabloLiveInspectionRequest(
                kind: .frame,
                target: PabloLiveApplicationTarget(appName: "Notes"),
                reference: "A11Y-001"
            )
        ),
        socketPath: socketPath
    )

    #expect(response.result?.output == structuredOutput)
    #expect(response.result?.output?.formattedString().contains("\n  \"nodes\"") == true)
}

@Test("Live actions cross the control socket without trusting caller-supplied identity")
func liveActionControlRoundTrip() throws {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/pablo-action-control-\(suffix)", isDirectory: true)
    let socketPath = root.appendingPathComponent("control.sock").path
    let server = PabloControlServer(socketPath: socketPath) { request, peer in
        #expect(request.method == .actLive)
        #expect(request.liveActionRequest?.kind == .typeText)
        #expect(request.liveActionRequest?.target.bundleIdentifier == "com.example.Editor")
        #expect(request.liveActionRequest?.nodeID == "ax-editor")
        #expect(request.liveActionRequest?.text == "Hello")
        #expect(peer.userIdentifier == getuid())
        return PabloControlResponse(
            id: request.id,
            result: PabloControlResult(
                state: "idle",
                scopeName: "Editor",
                applicationIDs: ["APP-001"],
                recordingPath: nil,
                elapsedNanoseconds: 0,
                output: .string("typed  Editor  characters=5")
            )
        )
    }
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    try server.start()
    let response = try PabloControlClient.send(
        PabloControlRequest(
            method: .actLive,
            liveActionRequest: PabloLiveActionRequest(
                kind: .typeText,
                target: PabloLiveApplicationTarget(bundleIdentifier: "com.example.Editor"),
                nodeID: "ax-editor",
                text: "Hello"
            )
        ),
        socketPath: socketPath
    )

    #expect(response.result?.output == .string("typed  Editor  characters=5"))
}

@Test("Transport invalid requests have a structured pre-dispatch rejection")
func transportInvalidRequestFailure() throws {
    let root = URL(fileURLWithPath: "/private/tmp/pablo-failure-\(UUID().uuidString.prefix(8))")
    let socketPath = root.appendingPathComponent("control.sock").path
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = LockedCount()
    let server = PabloControlServer(socketPath: socketPath) { request, _ in
        calls.increment()
        return PabloControlResponse(id: request.id, error: "Unexpected dispatch")
    }
    defer { server.stop() }
    try server.start()
    let response = try runCurl(socketPath: socketPath, arguments: [
        "--stderr", "/dev/null", "--data-binary", "{}", "http://localhost/action.live"
    ])
    let object = try #require(JSONSerialization.jsonObject(with: response.output) as? [String: Any])
    let failure = try #require(object["failure"] as? [String: Any])
    #expect(failure["code"] as? String == "invalidRequest")
    #expect(failure["dispatchStatus"] as? String == "notDispatched")
    #expect(calls.current == 0)
}

@Test("Explicit interrupted web recovery is scoped to its recording and method")
func rrwebInterruptedRecoveryContract() throws {
    let recordingID = UUID()
    let payload = PabloRRWebControlRequest(recordingID: recordingID, recoveryAction: .finishInterrupted)
    let decoded = try PabloControlJSONCodec.decode(PabloRRWebControlRequest.self,
        from: PabloControlJSONCodec.encode(payload))
    #expect(decoded.recordingID == recordingID)
    #expect(decoded.recoveryAction == .finishInterrupted)
    try decoded.validate(for: .rrwebRecover)
    #expect(throws: RecordingError.self) { try decoded.validate(for: .rrwebInspect) }
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(recoveryAction: .finishInterrupted).validate(for: .rrwebRecover)
    }
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(tabID: 42, recoveryAction: .select).validate(for: .rrwebStart)
    }
}
