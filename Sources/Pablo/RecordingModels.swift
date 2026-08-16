import Foundation

public enum RecordingScopeKind: String, Codable, Equatable, Sendable {
    case application
    case display
}

struct RecordingManifest: Codable {
    struct Scope: Codable, Equatable {
        let kind: RecordingScopeKind
        let selectedApplicationID: String?
        let selectedDisplayID: UInt32?
    }

    struct Capture: Codable {
        let frame: RecordingRect
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
    let scope: Scope
    var displays: [RecordingDisplay]
    var applications: [RecordingApplication]
    var capture: Capture
    let files: [String: String]
}

extension RecordingManifest {
    static let currentSchemaVersion = 3

    static func load(from packageURL: URL) throws -> RecordingManifest {
        let url = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw RecordingError.capture(
                "Unsupported recording format version \(manifest.schemaVersion); Pablo requires version \(currentSchemaVersion)."
            )
        }
        for key in ["video", "events", "workspace", "accessibility"] {
            _ = try manifest.fileURL(for: key, in: packageURL)
        }
        return manifest
    }

    func fileURL(for key: String, in packageURL: URL) throws -> URL {
        guard let relativePath = files[key], !relativePath.isEmpty else {
            throw RecordingError.capture("Recording manifest is missing its \(key) evidence path.")
        }
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.hasPrefix("/"), !components.contains("..") else {
            throw RecordingError.capture("Recording manifest has an unsafe \(key) evidence path.")
        }
        return packageURL.appendingPathComponent(relativePath)
    }
}

struct RecordingPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct RecordingSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

public struct RecordingRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

struct RecordingDisplay: Codable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: RecordingRect
    let scale: Double
    let isPrimary: Bool
}

public struct RecordingApplication: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let bundleIdentifier: String?
    public let name: String
    public let firstSeenTimestampNs: UInt64
    public var lastSeenTimestampNs: UInt64?
}

public struct RecordingWindow: Codable, Equatable, Sendable {
    public let id: String
    public let applicationID: String
    public let systemWindowID: UInt32
    public let title: String?
    public let frame: RecordingRect
    public let layer: Int
    public let isOnScreen: Bool
    public let zOrder: UInt32
}

public struct WorkspaceSnapshotRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestampNs: UInt64
    public let reason: String
    public let frontmostApplicationID: String?
    public let applications: [RecordingApplication]
    public let windows: [RecordingWindow]
    public let appearedApplicationIDs: [String]
    public let removedApplicationIDs: [String]
    public let appearedWindowIDs: [String]
    public let removedWindowIDs: [String]
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
    public let foregroundActionsUnlocked: Bool
    public let caller: PabloAutomationCaller
    public let transport: String
    public let recordingWasPaused: Bool
    public let resolvedApplicationID: String?

    public init(
        actionID: UUID,
        phase: PabloAutomationActionPhase,
        request: PabloLiveActionRequest,
        caller: PabloAutomationCaller,
        transport: String,
        recordingWasPaused: Bool,
        resolvedApplicationID: String? = nil
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
        foregroundActionsUnlocked = request.unlockForegroundActions
        self.caller = caller
        self.transport = transport
        self.recordingWasPaused = recordingWasPaused
        self.resolvedApplicationID = resolvedApplicationID
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
        foregroundActionsUnlocked: Bool,
        caller: PabloAutomationCaller,
        transport: String,
        recordingWasPaused: Bool,
        resolvedApplicationID: String?
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
        self.foregroundActionsUnlocked = foregroundActionsUnlocked
        self.caller = caller
        self.transport = transport
        self.recordingWasPaused = recordingWasPaused
        self.resolvedApplicationID = resolvedApplicationID
    }
}

extension PabloAutomationActionTrace {
    func resolvingApplicationID(_ applicationID: String?) -> Self {
        Self(
            actionID: actionID,
            phase: phase,
            kind: kind,
            target: target,
            nodeID: nodeID,
            point: point,
            fromNodeID: fromNodeID,
            fromPoint: fromPoint,
            toNodeID: toNodeID,
            toPoint: toPoint,
            mouseButton: mouseButton,
            clickCount: clickCount,
            duration: duration,
            scrollDirection: scrollDirection,
            scrollAmount: scrollAmount,
            textLength: textLength,
            key: key,
            modifiers: modifiers,
            accessibilityAction: accessibilityAction,
            foregroundActionsUnlocked: foregroundActionsUnlocked,
            caller: caller,
            transport: transport,
            recordingWasPaused: recordingWasPaused,
            resolvedApplicationID: applicationID
        )
    }
}

public struct InputEventRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let timestampNs: UInt64
    public let type: String
    public let targetPID: Int64?
    public let applicationID: String?
    public let windowID: String?
    public let x: Double?
    public let y: Double?
    public let deltaX: Double?
    public let deltaY: Double?
    public let keyCode: Int64?
    public let text: String?
    public let flags: UInt64
    public let button: Int64?
    public let clickCount: Int64?
    public let automationAction: PabloAutomationActionTrace?

    static func automationAction(
        timestampNs: UInt64,
        targetPID: pid_t?,
        applicationID: String?,
        trace: PabloAutomationActionTrace
    ) -> Self {
        InputEventRecord(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            timestampNs: timestampNs,
            type: "automationAction",
            targetPID: targetPID.map(Int64.init),
            applicationID: applicationID,
            windowID: nil,
            x: nil,
            y: nil,
            deltaX: nil,
            deltaY: nil,
            keyCode: nil,
            text: nil,
            flags: 0,
            button: nil,
            clickCount: nil,
            automationAction: trace.resolvingApplicationID(applicationID)
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
    let application: RecordingApplication
    let rootID: String?
    let upserts: [AXNode]
    let removed: [String]
    let truncated: Bool
}

struct SessionSummary: Codable {
    let manifest: RecordingManifest
    let inputEventCount: Int
    let workspaceRecordCount: Int
    let accessibilityRecordCount: Int
    let annotationCount: Int
}
