import Foundation

struct RecordingManifest: Codable {
    struct Target: Codable {
        let pid: Int32
        let bundleIdentifier: String?
        let name: String
    }

    struct Capture: Codable {
        let displayScale: Double
        let width: Int
        let height: Int
        let framesPerSecond: Int
        var firstFrameTimestampNs: UInt64?
    }

    let schemaVersion: Int
    let startedAt: String
    var endedAt: String?
    var durationNs: UInt64?
    let target: Target
    var capture: Capture
    let files: [String: String]
}

extension RecordingManifest {
    static let currentSchemaVersion = 2

    static func load(from packageURL: URL) throws -> RecordingManifest {
        let url = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw RecordingError.capture(
                "Unsupported recording format version \(manifest.schemaVersion); Pablo requires version \(currentSchemaVersion)."
            )
        }
        return manifest
    }
}

public enum PabloAutomationActionPhase: String, Codable, Sendable {
    case requested
    case succeeded
    case failed
}

public struct PabloAutomationCaller: Codable, Sendable {
    public let displayName: String
    public let applicationIdentifier: String?
    public let developerName: String?
    public let developerTeamIdentifier: String?
    public let verified: Bool

    public init(
        displayName: String,
        applicationIdentifier: String?,
        developerName: String?,
        developerTeamIdentifier: String?,
        verified: Bool
    ) {
        self.displayName = displayName
        self.applicationIdentifier = applicationIdentifier
        self.developerName = developerName
        self.developerTeamIdentifier = developerTeamIdentifier
        self.verified = verified
    }
}

public struct PabloAutomationActionTrace: Codable, Sendable {
    public let actionID: UUID
    public let phase: PabloAutomationActionPhase
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
    public let textLength: Int?
    public let key: String?
    public let modifiers: [PabloLiveKeyModifier]
    public let accessibilityAction: String?
    public let caller: PabloAutomationCaller
    public let transport: String
    public let recordingWasPaused: Bool

    public init(
        actionID: UUID,
        phase: PabloAutomationActionPhase,
        request: PabloLiveActionRequest,
        caller: PabloAutomationCaller,
        transport: String,
        recordingWasPaused: Bool
    ) {
        self.actionID = actionID
        self.phase = phase
        kind = request.kind
        target = request.target
        nodeID = request.nodeID
        point = request.point
        fromNodeID = request.fromNodeID
        fromPoint = request.fromPoint
        toNodeID = request.toNodeID
        toPoint = request.toPoint
        mouseButton = request.mouseButton
        clickCount = request.clickCount
        duration = request.duration
        scrollDirection = request.scrollDirection
        scrollAmount = request.scrollAmount
        textLength = request.text?.count
        key = request.key
        modifiers = request.modifiers
        accessibilityAction = request.accessibilityAction
        self.caller = caller
        self.transport = transport
        self.recordingWasPaused = recordingWasPaused
    }

    init(
        actionID: UUID,
        phase: PabloAutomationActionPhase,
        kind: PabloLiveActionKind,
        target: PabloLiveApplicationTarget,
        nodeID: String?,
        point: PabloLivePoint?,
        fromNodeID: String?,
        fromPoint: PabloLivePoint?,
        toNodeID: String?,
        toPoint: PabloLivePoint?,
        mouseButton: PabloLiveMouseButton,
        clickCount: Int,
        duration: TimeInterval,
        scrollDirection: PabloLiveScrollDirection?,
        scrollAmount: Int,
        textLength: Int?,
        key: String?,
        modifiers: [PabloLiveKeyModifier],
        accessibilityAction: String?,
        caller: PabloAutomationCaller,
        transport: String,
        recordingWasPaused: Bool
    ) {
        self.actionID = actionID
        self.phase = phase
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
        self.textLength = textLength
        self.key = key
        self.modifiers = modifiers
        self.accessibilityAction = accessibilityAction
        self.caller = caller
        self.transport = transport
        self.recordingWasPaused = recordingWasPaused
    }
}

struct InputEventRecord: Codable {
    let schemaVersion: Int
    let timestampNs: UInt64
    let type: String
    let targetPID: Int64?
    let x: Double?
    let y: Double?
    let deltaX: Double?
    let deltaY: Double?
    let keyCode: Int64?
    let text: String?
    let flags: UInt64
    let button: Int64?
    let clickCount: Int64?
    let automationAction: PabloAutomationActionTrace?

    static func automationAction(
        timestampNs: UInt64,
        targetPID: pid_t?,
        trace: PabloAutomationActionTrace
    ) -> Self {
        InputEventRecord(
            schemaVersion: 2,
            timestampNs: timestampNs,
            type: "automationAction",
            targetPID: targetPID.map(Int64.init),
            x: nil,
            y: nil,
            deltaX: nil,
            deltaY: nil,
            keyCode: nil,
            text: nil,
            flags: 0,
            button: nil,
            clickCount: nil,
            automationAction: trace
        )
    }
}

struct AXNode: Codable, Equatable {
    let id: String
    let parentID: String?
    let childIDs: [String]
    let role: String?
    let subrole: String?
    let title: String?
    let label: String?
    let value: String?
    let identifier: String?
    let help: String?
    let enabled: Bool?
    let focused: Bool?
    let position: Point?
    let size: Size?

    struct Point: Codable, Equatable {
        let x: Double
        let y: Double
    }

    struct Size: Codable, Equatable {
        let width: Double
        let height: Double
    }
}

struct AXSnapshotRecord: Codable {
    let schemaVersion: Int
    let timestampNs: UInt64
    let reason: String
    let kind: String
    let rootID: String?
    let upserts: [AXNode]
    let removed: [String]
    let truncated: Bool
}

struct SessionSummary: Codable {
    let manifest: RecordingManifest
    let inputEventCount: Int
    let accessibilityRecordCount: Int
    let annotationCount: Int
}
