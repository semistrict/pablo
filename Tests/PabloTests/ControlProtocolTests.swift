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

private func runCurl(
    socketPath: String,
    arguments: [String],
    input: Data? = nil
) throws -> (status: Int32, output: Data) {
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "--silent", "--show-error", "--fail-with-body", "--unix-socket", socketPath,
    ] + arguments
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    if let input {
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        try outputPipe.fileHandleForReading.readToEnd() ?? Data()
    )
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
            recordingPath: "/tmp/Recording.pabloweb",
            recordingID: UUID()
        ).validate(for: .rrwebInspect)
    }
    #expect(throws: RecordingError.self) {
        try PabloRRWebControlRequest(recordingID: UUID(), eventLimit: 10_001)
            .validate(for: .rrwebInspect)
    }
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
