import Darwin
import Foundation

public enum PabloControlMethod: String, Codable, Sendable {
    case startRecording = "record.start"
    case pauseRecording = "record.pause"
    case resumeRecording = "record.resume"
    case stopRecording = "record.stop"
    case status = "record.status"
    case addAnnotation = "annotation.add"
    case resolveAnnotation = "annotation.resolve"
    case inspectLive = "inspect.live"
    case actLive = "action.live"

    public var approvalDescription: String {
        switch self {
        case .startRecording: return "start a recording"
        case .pauseRecording: return "pause the current recording"
        case .resumeRecording: return "resume the current recording"
        case .stopRecording: return "stop the current recording"
        case .status: return "read the current recording status"
        case .addAnnotation: return "add markup to a recording"
        case .resolveAnnotation: return "resolve markup in a recording"
        case .inspectLive: return "inspect a live application"
        case .actLive: return "control a live application"
        }
    }
}

public struct PabloLiveApplicationTarget: Codable, Equatable, Sendable {
    public let pid: Int32?
    public let bundleIdentifier: String?
    public let appName: String?

    public init(pid: Int32? = nil, bundleIdentifier: String? = nil, appName: String? = nil) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }
}

public enum PabloLiveInspectionKind: String, Codable, Sendable {
    case inspect
    case frames
    case frame
    case events
    case annotations
}

public struct PabloLiveInspectionRequest: Codable, Sendable {
    public let kind: PabloLiveInspectionKind
    public let target: PabloLiveApplicationTarget
    public let reference: String?
    public let changedOnly: Bool
    public let limit: Int
    public let json: Bool

    public init(
        kind: PabloLiveInspectionKind,
        target: PabloLiveApplicationTarget,
        reference: String? = nil,
        changedOnly: Bool = false,
        limit: Int = 100,
        json: Bool = false
    ) {
        self.kind = kind
        self.target = target
        self.reference = reference
        self.changedOnly = changedOnly
        self.limit = limit
        self.json = json
    }
}

public struct PabloLivePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum PabloLiveActionKind: String, Codable, Sendable {
    case click
    case drag
    case scroll
    case typeText = "type"
    case key
    case perform
}

public enum PabloLiveMouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public enum PabloLiveScrollDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right
}

public enum PabloLiveKeyModifier: String, Codable, CaseIterable, Sendable {
    case command
    case option
    case control
    case shift
    case function
}

public struct PabloLiveActionRequest: Codable, Sendable {
    public let kind: PabloLiveActionKind
    public let target: PabloLiveApplicationTarget
    public let nodeID: String?
    public let point: PabloLivePoint?
    public let fromNodeID: String?
    public let fromPoint: PabloLivePoint?
    public let toNodeID: String?
    public let toPoint: PabloLivePoint?
    public let mouseButton: PabloLiveMouseButton
    public let clickCount: Int
    public let duration: TimeInterval
    public let scrollDirection: PabloLiveScrollDirection?
    public let scrollAmount: Int
    public let text: String?
    public let key: String?
    public let modifiers: [PabloLiveKeyModifier]
    public let accessibilityAction: String?

    public init(
        kind: PabloLiveActionKind,
        target: PabloLiveApplicationTarget,
        nodeID: String? = nil,
        point: PabloLivePoint? = nil,
        fromNodeID: String? = nil,
        fromPoint: PabloLivePoint? = nil,
        toNodeID: String? = nil,
        toPoint: PabloLivePoint? = nil,
        mouseButton: PabloLiveMouseButton = .left,
        clickCount: Int = 1,
        duration: TimeInterval = 0.5,
        scrollDirection: PabloLiveScrollDirection? = nil,
        scrollAmount: Int = 3,
        text: String? = nil,
        key: String? = nil,
        modifiers: [PabloLiveKeyModifier] = [],
        accessibilityAction: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.nodeID = nodeID
        self.point = point
        self.fromNodeID = fromNodeID
        self.fromPoint = fromPoint
        self.toNodeID = toNodeID
        self.toPoint = toPoint
        self.mouseButton = mouseButton
        self.clickCount = clickCount
        self.duration = duration
        self.scrollDirection = scrollDirection
        self.scrollAmount = scrollAmount
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.accessibilityAction = accessibilityAction
    }
}

public struct PabloControlRecordOptions: Codable, Sendable {
    public let pid: Int32?
    public let bundleIdentifier: String?
    public let appName: String?
    public let outputPath: String?
    public let duration: TimeInterval?
    public let snapshotInterval: TimeInterval
    public let captureText: Bool
    public let framesPerSecond: Int

    public init(options: RecordOptions) {
        pid = options.pid
        bundleIdentifier = options.bundleIdentifier
        appName = options.appName
        outputPath = options.outputURL?.path
        duration = options.duration
        snapshotInterval = options.snapshotInterval
        captureText = options.captureText
        framesPerSecond = options.framesPerSecond
    }

    init(
        pid: Int32?,
        bundleIdentifier: String?,
        appName: String?,
        outputPath: String?,
        duration: TimeInterval?,
        snapshotInterval: TimeInterval,
        captureText: Bool,
        framesPerSecond: Int
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.outputPath = outputPath
        self.duration = duration
        self.snapshotInterval = snapshotInterval
        self.captureText = captureText
        self.framesPerSecond = framesPerSecond
    }

    public func recordOptions() -> RecordOptions {
        var options = RecordOptions()
        options.pid = pid
        options.bundleIdentifier = bundleIdentifier
        options.appName = appName
        options.outputURL = outputPath.map { URL(fileURLWithPath: $0) }
        options.duration = duration
        options.snapshotInterval = snapshotInterval
        options.captureText = captureText
        options.framesPerSecond = framesPerSecond
        return options
    }
}

public struct PabloControlAnnotationRequest: Codable, Sendable {
    public let recordingPath: String
    public let draft: RecordingAnnotationDraft?
    public let reference: String?

    public init(recordingPath: String, draft: RecordingAnnotationDraft) {
        self.recordingPath = recordingPath
        self.draft = draft
        reference = nil
    }

    public init(recordingPath: String, reference: String) {
        self.recordingPath = recordingPath
        draft = nil
        self.reference = reference
    }
}

public struct PabloControlRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let method: PabloControlMethod
    public let recordOptions: PabloControlRecordOptions?
    public let annotationRequest: PabloControlAnnotationRequest?
    public let liveInspectionRequest: PabloLiveInspectionRequest?
    public let liveActionRequest: PabloLiveActionRequest?

    public init(
        method: PabloControlMethod,
        recordOptions: PabloControlRecordOptions? = nil,
        annotationRequest: PabloControlAnnotationRequest? = nil,
        liveInspectionRequest: PabloLiveInspectionRequest? = nil,
        liveActionRequest: PabloLiveActionRequest? = nil
    ) {
        protocolVersion = 2
        id = UUID()
        self.method = method
        self.recordOptions = recordOptions
        self.annotationRequest = annotationRequest
        self.liveInspectionRequest = liveInspectionRequest
        self.liveActionRequest = liveActionRequest
    }

    init(
        protocolVersion: Int,
        id: UUID,
        method: PabloControlMethod,
        recordOptions: PabloControlRecordOptions?,
        annotationRequest: PabloControlAnnotationRequest?,
        liveInspectionRequest: PabloLiveInspectionRequest?,
        liveActionRequest: PabloLiveActionRequest?
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.method = method
        self.recordOptions = recordOptions
        self.annotationRequest = annotationRequest
        self.liveInspectionRequest = liveInspectionRequest
        self.liveActionRequest = liveActionRequest
    }
}

public struct PabloControlResult: Codable, Sendable {
    public let state: String
    public let target: String?
    public let recordingPath: String?
    public let elapsedNanoseconds: UInt64
    public let annotation: RecordingAnnotation?
    public let output: String?

    public init(
        state: String,
        target: String?,
        recordingPath: String?,
        elapsedNanoseconds: UInt64,
        annotation: RecordingAnnotation? = nil,
        output: String? = nil
    ) {
        self.state = state
        self.target = target
        self.recordingPath = recordingPath
        self.elapsedNanoseconds = elapsedNanoseconds
        self.annotation = annotation
        self.output = output
    }
}

public struct PabloControlResponse: Codable, Sendable {
    public let id: UUID
    public let result: PabloControlResult?
    public let error: String?

    public init(id: UUID, result: PabloControlResult) {
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: UUID, error: String) {
        self.id = id
        result = nil
        self.error = error
    }
}

public struct PabloControlPeer: Sendable {
    public let processIdentifier: pid_t?
    public let userIdentifier: uid_t

    public init(processIdentifier: pid_t?, userIdentifier: uid_t) {
        self.processIdentifier = processIdentifier
        self.userIdentifier = userIdentifier
    }
}

public final class PabloDailyApprovalStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let calendar: Calendar
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "ControlApprovalsByApplication",
        calendar: Calendar = .current
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.calendar = calendar
    }

    public func isApprovedToday(applicationIdentity: String, now: Date = Date()) -> Bool {
        lock.withLock {
            let approvals = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            return approvals[applicationIdentity] == dayIdentifier(for: now)
        }
    }

    public func approveForToday(applicationIdentity: String, now: Date = Date()) {
        lock.withLock {
            var approvals = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            approvals[applicationIdentity] = dayIdentifier(for: now)
            defaults.set(approvals, forKey: storageKey)
        }
    }

    private func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [components.era, components.year, components.month, components.day]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }
}

public enum PabloControlSocket {
    public static var path: String {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Pablo", isDirectory: true)
        return directory.appendingPathComponent("control.sock").path
    }
}

public enum PabloProcessChain {
    public static func nearestApplication<Identity>(
        invokedBy childProcessIdentifier: pid_t,
        maximumDepth: Int = 64,
        parentProcessIdentifier: (pid_t) -> pid_t?,
        applicationIdentity: (pid_t) -> Identity?
    ) -> Identity? {
        var current = parentProcessIdentifier(childProcessIdentifier)
        var visited = Set<pid_t>()
        for _ in 0..<maximumDepth {
            guard let pid = current, pid > 1, visited.insert(pid).inserted else { return nil }
            if let identity = applicationIdentity(pid) { return identity }
            current = parentProcessIdentifier(pid)
        }
        return nil
    }
}

public enum PabloControlClient {
    public static func send(
        _ request: PabloControlRequest,
        socketPath: String = PabloControlSocket.path
    ) throws -> PabloControlResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not create the control socket") }
        defer { Darwin.close(descriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )

        let connectionResult = try withUnixSocketAddress(path: socketPath) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        guard connectionResult == 0 else {
            throw socketError("Could not connect to the Pablo app")
        }

        let requestData = try PabloProtobufCodec.encode(request)
        try writeAll(requestData, to: descriptor)
        Darwin.shutdown(descriptor, SHUT_WR)

        let responseData = try readToEnd(from: descriptor, maximumBytes: 16 * 1_024 * 1_024)
        guard !responseData.isEmpty else {
            throw RecordingError.capture("The Pablo app closed the control connection without responding.")
        }
        return try PabloProtobufCodec.decodeControlResponse(from: responseData)
    }
}

public final class PabloControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (PabloControlRequest, PabloControlPeer) async -> PabloControlResponse

    private let handler: Handler
    private let socketPath: String
    private let queue = DispatchQueue(label: "pablo.control-server", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(
        socketPath: String = PabloControlSocket.path,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard lock.withLock({ listener < 0 }) else { return }
        let directoryURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        if FileManager.default.fileExists(atPath: socketPath) {
            if unixSocketIsActive(at: socketPath) {
                throw RecordingError.capture("Another Pablo control service is already running.")
            }
            Darwin.unlink(socketPath)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not create Pablo's control listener") }

        let bindResult: Int32
        do {
            bindResult = try withUnixSocketAddress(path: socketPath) { address, length in
                Darwin.bind(descriptor, address, length)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard bindResult == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            let error = socketError("Could not listen on Pablo's control socket")
            Darwin.close(descriptor)
            Darwin.unlink(socketPath)
            throw error
        }
        guard Darwin.chmod(socketPath, 0o600) == 0 else {
            let error = socketError("Could not protect Pablo's control socket")
            Darwin.close(descriptor)
            Darwin.unlink(socketPath)
            throw error
        }
        lock.withLock { listener = descriptor }
        queue.async { [weak self] in self?.acceptConnections() }
    }

    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            let descriptor = listener
            listener = -1
            return descriptor
        }
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        Darwin.unlink(socketPath)
    }

    private func acceptConnections() {
        while true {
            let descriptor = lock.withLock { listener }
            guard descriptor >= 0 else { return }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handleConnection(client)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        configureClientSocket(descriptor)

        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(descriptor, &peerUser, &peerGroup) == 0, peerUser == getuid() else {
            return
        }
        let peer = PabloControlPeer(
            processIdentifier: peerProcessIdentifier(descriptor),
            userIdentifier: peerUser
        )

        let request: PabloControlRequest
        do {
            let data = try readToEnd(from: descriptor, maximumBytes: 64 * 1_024)
            request = try PabloProtobufCodec.decodeControlRequest(from: data)
            guard request.protocolVersion == 2 else {
                try writeResponse(
                    PabloControlResponse(id: request.id, error: "Unsupported control protocol version."),
                    to: descriptor
                )
                return
            }
        } catch {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let response = await handler(request, peer)
            try? writeResponse(response, to: descriptor)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func configureClientSocket(_ descriptor: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func peerProcessIdentifier(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }

    private func writeResponse(_ response: PabloControlResponse, to descriptor: Int32) throws {
        try writeAll(try PabloProtobufCodec.encode(response), to: descriptor)
    }
}

private func withUnixSocketAddress<Result>(
    path: String,
    body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
        throw RecordingError.capture("Pablo's control socket path is too long.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    let length = MemoryLayout<sa_family_t>.size + path.utf8.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            _ = path.withCString { source in strlcpy(destination, source, capacity) }
        }
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(length))
        }
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard var base = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let written = Darwin.write(descriptor, base, remaining)
            guard written > 0 else { throw socketError("Could not write to Pablo's control socket") }
            remaining -= written
            base = base.advanced(by: written)
        }
    }
}

private func readToEnd(from descriptor: Int32, maximumBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count < maximumBytes {
        let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - data.count))
        if count == 0 { return data }
        guard count > 0 else { throw socketError("Could not read Pablo's control response") }
        data.append(buffer, count: count)
    }
    throw RecordingError.capture("The Pablo control response was too large.")
}

private func socketError(_ context: String) -> RecordingError {
    RecordingError.capture("\(context): \(String(cString: strerror(errno)))")
}

private func unixSocketIsActive(at path: String) -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return true }
    defer { Darwin.close(descriptor) }
    return (try? withUnixSocketAddress(path: path) { address, length in
        Darwin.connect(descriptor, address, length) == 0
    }) ?? true
}
