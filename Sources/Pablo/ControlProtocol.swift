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
    case safariDOM = "safari.dom"
    case safariTabs = "safari.tabs"
    case rrwebStart = "rrweb.start"
    case rrwebPause = "rrweb.pause"
    case rrwebResume = "rrweb.resume"
    case rrwebStop = "rrweb.stop"
    case rrwebStatus = "rrweb.status"
    case rrwebRecordings = "rrweb.recordings"
    case rrwebInspect = "rrweb.inspect"

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
        case .safariDOM: return "inspect or control an unlocked Safari tab"
        case .safariTabs: return "list unlocked active Safari tabs"
        case .rrwebStart: return "start an rrweb recording of an unlocked Safari tab"
        case .rrwebPause: return "pause the current rrweb recording"
        case .rrwebResume: return "resume the current rrweb recording"
        case .rrwebStop: return "stop the current rrweb recording"
        case .rrwebStatus: return "read the current rrweb recording status"
        case .rrwebRecordings: return "list saved rrweb recordings"
        case .rrwebInspect: return "inspect a saved rrweb recording"
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

    public init(
        kind: PabloLiveInspectionKind,
        target: PabloLiveApplicationTarget,
        reference: String? = nil,
        changedOnly: Bool = false,
        limit: Int = 100
    ) {
        self.kind = kind
        self.target = target
        self.reference = reference
        self.changedOnly = changedOnly
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, target, reference, changedOnly, limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(PabloLiveInspectionKind.self, forKey: .kind),
            target: try container.decode(PabloLiveApplicationTarget.self, forKey: .target),
            reference: try container.decodeIfPresent(String.self, forKey: .reference),
            changedOnly: try container.decodeIfPresent(Bool.self, forKey: .changedOnly) ?? false,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 100
        )
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
    public let unlockForegroundActions: Bool

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
        accessibilityAction: String? = nil,
        unlockForegroundActions: Bool = false
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
        self.unlockForegroundActions = unlockForegroundActions
    }

    private enum CodingKeys: String, CodingKey {
        case kind, target, nodeID, point, fromNodeID, fromPoint, toNodeID, toPoint
        case mouseButton, clickCount, duration, scrollDirection, scrollAmount
        case text, key, modifiers, accessibilityAction, unlockForegroundActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(PabloLiveActionKind.self, forKey: .kind),
            target: try container.decode(PabloLiveApplicationTarget.self, forKey: .target),
            nodeID: try container.decodeIfPresent(String.self, forKey: .nodeID),
            point: try container.decodeIfPresent(PabloLivePoint.self, forKey: .point),
            fromNodeID: try container.decodeIfPresent(String.self, forKey: .fromNodeID),
            fromPoint: try container.decodeIfPresent(PabloLivePoint.self, forKey: .fromPoint),
            toNodeID: try container.decodeIfPresent(String.self, forKey: .toNodeID),
            toPoint: try container.decodeIfPresent(PabloLivePoint.self, forKey: .toPoint),
            mouseButton: try container.decodeIfPresent(PabloLiveMouseButton.self, forKey: .mouseButton) ?? .left,
            clickCount: try container.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0.5,
            scrollDirection: try container.decodeIfPresent(PabloLiveScrollDirection.self, forKey: .scrollDirection),
            scrollAmount: try container.decodeIfPresent(Int.self, forKey: .scrollAmount) ?? 3,
            text: try container.decodeIfPresent(String.self, forKey: .text),
            key: try container.decodeIfPresent(String.self, forKey: .key),
            modifiers: try container.decodeIfPresent([PabloLiveKeyModifier].self, forKey: .modifiers) ?? [],
            accessibilityAction: try container.decodeIfPresent(String.self, forKey: .accessibilityAction),
            unlockForegroundActions: try container.decodeIfPresent(
                Bool.self,
                forKey: .unlockForegroundActions
            ) ?? false
        )
    }
}

public enum PabloSafariDOMCommandKind: String, Codable, Sendable {
    case listTabs
    case startRRWebRecording
    case pauseRRWebRecording
    case resumeRRWebRecording
    case stopRRWebRecording
    case rrwebRecordingStatus
    case dumpDOM
    case dumpAccessibilityTree
    case click
    case focus
    case setValue
    case scrollIntoView

    public var isMutation: Bool {
        switch self {
        case .listTabs, .startRRWebRecording, .pauseRRWebRecording,
             .resumeRRWebRecording, .stopRRWebRecording, .rrwebRecordingStatus,
             .dumpDOM, .dumpAccessibilityTree: false
        case .click, .focus, .setValue, .scrollIntoView: true
        }
    }

    public var isRRWebCommand: Bool {
        switch self {
        case .startRRWebRecording, .pauseRRWebRecording, .resumeRRWebRecording,
             .stopRRWebRecording, .rrwebRecordingStatus: true
        case .listTabs, .dumpDOM, .dumpAccessibilityTree, .click, .focus, .setValue,
             .scrollIntoView: false
        }
    }
}

public struct PabloSafariDOMRequest: Codable, Sendable {
    public let kind: PabloSafariDOMCommandKind
    public let selector: String?
    public let nodeID: String?
    public let value: String?
    public let includeHidden: Bool
    public let maxNodes: Int
    public let maxDepth: Int
    public let tabID: Int64?
    public let recordingID: UUID?

    public init(
        kind: PabloSafariDOMCommandKind,
        selector: String? = nil,
        nodeID: String? = nil,
        value: String? = nil,
        includeHidden: Bool = false,
        maxNodes: Int = 2_000,
        maxDepth: Int = 20,
        tabID: Int64? = nil,
        recordingID: UUID? = nil
    ) {
        self.kind = kind
        self.selector = selector
        self.nodeID = nodeID
        self.value = value
        self.includeHidden = includeHidden
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.tabID = tabID
        self.recordingID = recordingID
    }

    private enum CodingKeys: String, CodingKey {
        case kind, selector, nodeID, value, includeHidden, maxNodes, maxDepth, tabID, recordingID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(PabloSafariDOMCommandKind.self, forKey: .kind),
            selector: try container.decodeIfPresent(String.self, forKey: .selector),
            nodeID: try container.decodeIfPresent(String.self, forKey: .nodeID),
            value: try container.decodeIfPresent(String.self, forKey: .value),
            includeHidden: try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false,
            maxNodes: try container.decodeIfPresent(Int.self, forKey: .maxNodes) ?? 2_000,
            maxDepth: try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 20,
            tabID: try container.decodeIfPresent(Int64.self, forKey: .tabID),
            recordingID: try container.decodeIfPresent(UUID.self, forKey: .recordingID)
        )
    }
}

public struct PabloControlRecordOptions: Codable, Sendable {
    public let scope: RecordingScopeKind
    public let pid: Int32?
    public let bundleIdentifier: String?
    public let appName: String?
    public let displayID: UInt32?
    public let outputPath: String?
    public let duration: TimeInterval?
    public let snapshotInterval: TimeInterval
    public let captureText: Bool
    public let framesPerSecond: Int

    public init(options: RecordOptions) {
        scope = options.scope
        pid = options.pid
        bundleIdentifier = options.bundleIdentifier
        appName = options.appName
        displayID = options.displayID
        outputPath = options.outputURL?.path
        duration = options.duration
        snapshotInterval = options.snapshotInterval
        captureText = options.captureText
        framesPerSecond = options.framesPerSecond
    }

    init(
        scope: RecordingScopeKind,
        pid: Int32?,
        bundleIdentifier: String?,
        appName: String?,
        displayID: UInt32?,
        outputPath: String?,
        duration: TimeInterval?,
        snapshotInterval: TimeInterval,
        captureText: Bool,
        framesPerSecond: Int
    ) {
        self.scope = scope
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.displayID = displayID
        self.outputPath = outputPath
        self.duration = duration
        self.snapshotInterval = snapshotInterval
        self.captureText = captureText
        self.framesPerSecond = framesPerSecond
    }

    private enum CodingKeys: String, CodingKey {
        case scope, pid, bundleIdentifier, appName, displayID, outputPath, duration
        case snapshotInterval, captureText, framesPerSecond
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scope: try container.decode(RecordingScopeKind.self, forKey: .scope),
            pid: try container.decodeIfPresent(Int32.self, forKey: .pid),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            appName: try container.decodeIfPresent(String.self, forKey: .appName),
            displayID: try container.decodeIfPresent(UInt32.self, forKey: .displayID),
            outputPath: try container.decodeIfPresent(String.self, forKey: .outputPath),
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
            snapshotInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .snapshotInterval) ?? 1,
            captureText: try container.decodeIfPresent(Bool.self, forKey: .captureText) ?? true,
            framesPerSecond: try container.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 30
        )
    }

    public func recordOptions() -> RecordOptions {
        var options = RecordOptions()
        options.scope = scope
        options.pid = pid
        options.bundleIdentifier = bundleIdentifier
        options.appName = appName
        options.displayID = displayID
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

public struct PabloRRWebControlRequest: Codable, Sendable {
    public let tabID: Int64?
    public let recordingPath: String?
    public let recordingID: UUID?
    public let includeEvents: Bool
    public let eventLimit: Int

    public init(
        tabID: Int64? = nil,
        recordingPath: String? = nil,
        recordingID: UUID? = nil,
        includeEvents: Bool = false,
        eventLimit: Int = 1_000
    ) {
        self.tabID = tabID
        self.recordingPath = recordingPath
        self.recordingID = recordingID
        self.includeEvents = includeEvents
        self.eventLimit = eventLimit
    }

    private enum CodingKeys: String, CodingKey {
        case tabID, recordingPath, recordingID, includeEvents, eventLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tabID: try container.decodeIfPresent(Int64.self, forKey: .tabID),
            recordingPath: try container.decodeIfPresent(String.self, forKey: .recordingPath),
            recordingID: try container.decodeIfPresent(UUID.self, forKey: .recordingID),
            includeEvents: try container.decodeIfPresent(Bool.self, forKey: .includeEvents) ?? false,
            eventLimit: try container.decodeIfPresent(Int.self, forKey: .eventLimit) ?? 1_000
        )
    }

    public func validate(for method: PabloControlMethod) throws {
        switch method {
        case .rrwebStart:
            guard tabID.map({ $0 > 0 }) == true,
                  recordingPath == nil, recordingID == nil,
                  includeEvents == false, eventLimit == 1_000 else {
                throw RecordingError.usage("rrweb.start accepts only a positive tabID.")
            }
        case .rrwebInspect:
            guard tabID == nil else {
                throw RecordingError.usage("rrweb.inspect does not accept tabID.")
            }
            guard [recordingPath != nil, recordingID != nil].filter({ $0 }).count == 1 else {
                throw RecordingError.usage(
                    "rrweb.inspect requires exactly one recordingPath or recordingID."
                )
            }
            guard (1...10_000).contains(eventLimit) else {
                throw RecordingError.usage("eventLimit must be from 1 to 10000.")
            }
        default:
            throw RecordingError.usage("This endpoint does not accept an rrweb request body.")
        }
    }
}

public struct PabloControlRequest: Sendable {
    public let id: UUID
    public let method: PabloControlMethod
    public let recordOptions: PabloControlRecordOptions?
    public let annotationRequest: PabloControlAnnotationRequest?
    public let liveInspectionRequest: PabloLiveInspectionRequest?
    public let liveActionRequest: PabloLiveActionRequest?
    public let safariDOMRequest: PabloSafariDOMRequest?
    public let rrwebRequest: PabloRRWebControlRequest?

    public init(
        method: PabloControlMethod,
        recordOptions: PabloControlRecordOptions? = nil,
        annotationRequest: PabloControlAnnotationRequest? = nil,
        liveInspectionRequest: PabloLiveInspectionRequest? = nil,
        liveActionRequest: PabloLiveActionRequest? = nil,
        safariDOMRequest: PabloSafariDOMRequest? = nil,
        rrwebRequest: PabloRRWebControlRequest? = nil
    ) {
        id = UUID()
        self.method = method
        self.recordOptions = recordOptions
        self.annotationRequest = annotationRequest
        self.liveInspectionRequest = liveInspectionRequest
        self.liveActionRequest = liveActionRequest
        self.safariDOMRequest = safariDOMRequest
        self.rrwebRequest = rrwebRequest
    }

}

public indirect enum PabloControlOutput: Codable, Equatable, Sendable {
    case object([String: PabloControlOutput])
    case array([PabloControlOutput])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(json: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The Pablo control output contained an unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public func formattedString() -> String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct PabloControlResult: Codable, Sendable {
    public let state: String
    public let scopeName: String?
    public let applicationIDs: [String]
    public let recordingPath: String?
    public let elapsedNanoseconds: UInt64
    public let annotation: RecordingAnnotation?
    public let output: PabloControlOutput?

    public init(
        state: String,
        scopeName: String?,
        applicationIDs: [String],
        recordingPath: String?,
        elapsedNanoseconds: UInt64,
        annotation: RecordingAnnotation? = nil,
        output: PabloControlOutput? = nil
    ) {
        self.state = state
        self.scopeName = scopeName
        self.applicationIDs = applicationIDs
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
    public static let openAPIEndpoint = "/openapi.json"

    public static func endpoint(for method: PabloControlMethod) -> String {
        "/\(method.rawValue)"
    }

    static func method(for endpoint: String) -> PabloControlMethod? {
        guard endpoint.first == "/" else { return nil }
        return PabloControlMethod(rawValue: String(endpoint.dropFirst()))
    }

    public static var path: String {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Pablo", isDirectory: true)
        return directory.appendingPathComponent("control.sock").path
    }
}

enum PabloControlJSONCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

enum PabloControlOpenAPI {
    static func document() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "control-api.openapi",
            withExtension: "json"
        ) else {
            throw RecordingError.capture("Pablo's OpenAPI document is missing.")
        }
        return try Data(contentsOf: url)
    }
}

public enum PabloProcessChain {
    public static func parentProcessIdentifier(of pid: pid_t) -> pid_t? {
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, expectedSize)
        if actualSize == expectedSize, information.pbi_ppid > 0 {
            return pid_t(information.pbi_ppid)
        }
        return kernelParentProcessIdentifier(of: pid)
    }

    static func kernelParentProcessIdentifier(of pid: pid_t) -> pid_t? {
        var managementInformationBase = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = sysctl(
            &managementInformationBase,
            u_int(managementInformationBase.count),
            &information,
            &size,
            nil,
            0
        )
        guard result == 0,
              size == MemoryLayout<kinfo_proc>.size,
              information.kp_eproc.e_ppid > 0 else { return nil }
        return pid_t(information.kp_eproc.e_ppid)
    }

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

    public static func owningApplicationBundleURL(forExecutablePath path: String) -> URL? {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        var outermostApplication: URL?
        while current.path != "/" {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                outermostApplication = current
            }
            current.deleteLastPathComponent()
        }
        return outermostApplication
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

        let body = try controlRequestBody(request)
        guard body.count <= controlRequestMaximumBytes else {
            throw RecordingError.capture("The Pablo control request was too large.")
        }
        try writeHTTPRequest(
            endpoint: PabloControlSocket.endpoint(for: request.method),
            body: body,
            to: descriptor
        )

        let response = try readHTTPMessage(
            from: descriptor,
            maximumBodyBytes: controlResponseMaximumBytes
        )
        guard response.startLine == "HTTP/1.1 200 OK" else {
            let detail = (try? PabloControlJSONCodec.decode(ControlHTTPError.self, from: response.body).error)
                ?? "The Pablo app returned an invalid HTTP response."
            throw RecordingError.capture(detail)
        }
        return try PabloControlJSONCodec.decode(PabloControlResponse.self, from: response.body)
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
            let message = try readHTTPMessage(
                from: descriptor,
                maximumBodyBytes: controlRequestMaximumBytes
            )
            let startLine = message.startLine.split(separator: " ")
            guard startLine.count == 3, startLine[2] == "HTTP/1.1" else {
                throw RecordingError.capture("The control request requires an HTTP/1.1 method and URL.")
            }
            let endpoint = String(startLine[1])
            if endpoint == PabloControlSocket.openAPIEndpoint {
                guard message.body.isEmpty else {
                    throw RecordingError.capture("The OpenAPI endpoint does not accept a request body.")
                }
                try writeHTTPResponse(
                    body: PabloControlOpenAPI.document(),
                    status: "200 OK",
                    contentType: "application/vnd.oai.openapi+json",
                    to: descriptor
                )
                return
            }
            guard let method = PabloControlSocket.method(for: endpoint) else {
                throw RecordingError.capture("The control endpoint requires a supported method URL.")
            }
            request = try decodeControlRequest(method: method, body: message.body)
        } catch {
            try? writeHTTPError(error.localizedDescription, status: "400 Bad Request", to: descriptor)
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
        let body = try PabloControlJSONCodec.encode(response)
        guard body.count <= controlResponseMaximumBytes else {
            try writeHTTPError("The Pablo control response was too large.", status: "500 Internal Server Error", to: descriptor)
            return
        }
        try writeHTTPResponse(body: body, status: "200 OK", to: descriptor)
    }
}

private let controlHeaderMaximumBytes = 16 * 1_024
private let controlRequestMaximumBytes = 64 * 1_024
private let controlResponseMaximumBytes = 16 * 1_024 * 1_024

private struct ControlHTTPMessage {
    let startLine: String
    let headers: [String: String]
    let body: Data
}

private struct ControlHTTPError: Codable {
    let error: String
}

private func writeHTTPRequest(endpoint: String, body: Data, to descriptor: Int32) throws {
    let header = """
    POST \(endpoint) HTTP/1.1\r
    Host: localhost\r
    Content-Type: application/json\r
    Accept: application/json\r
    Content-Length: \(body.count)\r
    Connection: close\r
    \r

    """
    try writeAll(Data(header.utf8), to: descriptor)
    try writeAll(body, to: descriptor)
}

private func controlRequestBody(_ request: PabloControlRequest) throws -> Data {
    switch request.method {
    case .startRecording:
        guard let value = request.recordOptions else {
            throw RecordingError.usage("The start command did not include recording options.")
        }
        return try PabloControlJSONCodec.encode(value)
    case .addAnnotation, .resolveAnnotation:
        guard let value = request.annotationRequest else {
            throw RecordingError.usage("The annotation command did not include a request.")
        }
        return try PabloControlJSONCodec.encode(value)
    case .inspectLive:
        guard let value = request.liveInspectionRequest else {
            throw RecordingError.usage("The live inspection command did not include a request.")
        }
        return try PabloControlJSONCodec.encode(value)
    case .actLive:
        guard let value = request.liveActionRequest else {
            throw RecordingError.usage("The live action command did not include a request.")
        }
        return try PabloControlJSONCodec.encode(value)
    case .safariDOM:
        guard let value = request.safariDOMRequest else {
            throw RecordingError.usage("The Safari DOM command did not include a request.")
        }
        return try PabloControlJSONCodec.encode(value)
    case .rrwebStart, .rrwebInspect:
        guard let value = request.rrwebRequest else {
            throw RecordingError.usage("The rrweb command did not include a request.")
        }
        try value.validate(for: request.method)
        return try PabloControlJSONCodec.encode(value)
    case .pauseRecording, .resumeRecording, .stopRecording, .status,
         .safariTabs, .rrwebPause, .rrwebResume, .rrwebStop, .rrwebStatus, .rrwebRecordings:
        return Data()
    }
}

private func decodeControlRequest(method: PabloControlMethod, body: Data) throws -> PabloControlRequest {
    switch method {
    case .startRecording:
        return PabloControlRequest(
            method: method,
            recordOptions: try PabloControlJSONCodec.decode(PabloControlRecordOptions.self, from: body)
        )
    case .addAnnotation, .resolveAnnotation:
        return PabloControlRequest(
            method: method,
            annotationRequest: try PabloControlJSONCodec.decode(PabloControlAnnotationRequest.self, from: body)
        )
    case .inspectLive:
        return PabloControlRequest(
            method: method,
            liveInspectionRequest: try PabloControlJSONCodec.decode(PabloLiveInspectionRequest.self, from: body)
        )
    case .actLive:
        return PabloControlRequest(
            method: method,
            liveActionRequest: try PabloControlJSONCodec.decode(PabloLiveActionRequest.self, from: body)
        )
    case .safariDOM:
        return PabloControlRequest(
            method: method,
            safariDOMRequest: try PabloControlJSONCodec.decode(PabloSafariDOMRequest.self, from: body)
        )
    case .rrwebStart, .rrwebInspect:
        let value = try PabloControlJSONCodec.decode(PabloRRWebControlRequest.self, from: body)
        try value.validate(for: method)
        return PabloControlRequest(
            method: method,
            rrwebRequest: value
        )
    case .pauseRecording, .resumeRecording, .stopRecording, .status,
         .safariTabs, .rrwebPause, .rrwebResume, .rrwebStop, .rrwebStatus, .rrwebRecordings:
        guard body.isEmpty || body == Data("{}".utf8) else {
            throw RecordingError.usage("This control method does not accept a request body.")
        }
        return PabloControlRequest(method: method)
    }
}

private func writeHTTPResponse(
    body: Data,
    status: String,
    contentType: String = "application/json",
    to descriptor: Int32
) throws {
    let header = """
    HTTP/1.1 \(status)\r
    Content-Type: \(contentType)\r
    Content-Length: \(body.count)\r
    Connection: close\r
    \r

    """
    try writeAll(Data(header.utf8), to: descriptor)
    try writeAll(body, to: descriptor)
}

private func writeHTTPError(_ message: String, status: String, to descriptor: Int32) throws {
    try writeHTTPResponse(
        body: try PabloControlJSONCodec.encode(ControlHTTPError(error: message)),
        status: status,
        to: descriptor
    )
}

private func readHTTPMessage(from descriptor: Int32, maximumBodyBytes: Int) throws -> ControlHTTPMessage {
    let separator = Data("\r\n\r\n".utf8)
    var received = Data()
    var headerRange: Range<Data.Index>?

    while headerRange == nil {
        guard received.count < controlHeaderMaximumBytes else {
            throw RecordingError.capture("The Pablo control HTTP headers were too large.")
        }
        received.append(try readChunk(
            from: descriptor,
            maximumBytes: min(4_096, controlHeaderMaximumBytes - received.count)
        ))
        headerRange = received.range(of: separator)
    }

    guard let headerRange,
          let headerText = String(data: received[..<headerRange.lowerBound], encoding: .utf8) else {
        throw RecordingError.capture("The Pablo control HTTP headers were invalid.")
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let startLine = lines.first, !startLine.isEmpty else {
        throw RecordingError.capture("The Pablo control HTTP start line was missing.")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let separatorIndex = line.firstIndex(of: ":") else {
            throw RecordingError.capture("A Pablo control HTTP header was malformed.")
        }
        let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, headers[name] == nil else {
            throw RecordingError.capture("A Pablo control HTTP header was duplicated or empty.")
        }
        headers[name] = value
    }

    guard headers["transfer-encoding"] == nil else {
        throw RecordingError.capture("The Pablo control endpoint does not accept transfer encoding.")
    }
    let contentLength: Int
    if let contentLengthText = headers["content-length"] {
        guard let parsed = Int(contentLengthText), parsed >= 0 else {
            throw RecordingError.capture("The Pablo control HTTP Content-Length was invalid.")
        }
        contentLength = parsed
    } else {
        contentLength = 0
    }
    guard contentLength <= maximumBodyBytes else {
        throw RecordingError.capture("The Pablo control HTTP body was too large.")
    }

    var body = Data(received[headerRange.upperBound...])
    guard body.count <= contentLength else {
        throw RecordingError.capture("A Pablo control connection contained more than one request.")
    }
    while body.count < contentLength {
        body.append(try readChunk(
            from: descriptor,
            maximumBytes: min(4_096, contentLength - body.count)
        ))
    }
    return ControlHTTPMessage(startLine: startLine, headers: headers, body: body)
}

private func readChunk(from descriptor: Int32, maximumBytes: Int) throws -> Data {
    guard maximumBytes > 0 else { return Data() }
    var buffer = [UInt8](repeating: 0, count: maximumBytes)
    let count = Darwin.read(descriptor, &buffer, maximumBytes)
    guard count > 0 else {
        if count == 0 {
            throw RecordingError.capture("The Pablo control connection closed before the HTTP message was complete.")
        }
        throw socketError("Could not read Pablo's control socket")
    }
    return Data(buffer.prefix(count))
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
