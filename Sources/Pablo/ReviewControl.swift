import Foundation

public struct PabloReviewSource: Codable, Equatable, Sendable {
    public let sourceID: String
    public let generation: UUID
    public let recordingPath: String
    public let dataSource: String

    public init(sourceID: String, generation: UUID, recordingPath: String, dataSource: String) {
        self.sourceID = sourceID
        self.generation = generation
        self.recordingPath = recordingPath
        self.dataSource = dataSource
    }
}

public enum PabloReviewRendererState: String, Codable, Sendable {
    case empty, loading, ready, seeking, failed
}

public struct PabloReviewSelection: Codable, Equatable, Sendable {
    public var kind: String
    public var reference: String
    public var applicationID: String?
    public var nodeID: String?
    public var timestampNs: UInt64?

    public init(kind: String, reference: String, applicationID: String? = nil,
                nodeID: String? = nil, timestampNs: UInt64? = nil) {
        self.kind = kind
        self.reference = reference
        self.applicationID = applicationID
        self.nodeID = nodeID
        self.timestampNs = timestampNs
    }
}

public struct PabloReviewDraftState: Codable, Equatable, Sendable {
    public var draftID: UUID?
    public var sourceGeneration: UUID?
    public var anchorTimestampNs: UInt64?
    public var accessibilityReference: String?
    public var applicationID: String?
    public var nodeID: String?
    public var coordinateFrame: RecordingRect?
    public var owner = "human"
    public var text = ""
    public var characterCount = 0
    public var textTruncated = false
    public var kind = "observation"
    public var sampleCount = 0
    public var startTimestampNs: UInt64?
    public var endTimestampNs: UInt64?
    public init() {}
}

/// One main-actor snapshot. Revision tracks context changes, not playback clock ticks.
public struct PabloReviewState: Codable, Equatable, Sendable {
    public let reviewID: UUID
    public var serviceID: UUID?
    public var revision: UInt64 = 0
    public var isActive = false
    public var source: PabloReviewSource?
    public var playheadSeconds: Double = 0
    public var renderedSeconds: Double?
    public var durationSeconds: Double = 0
    public var sessionTimestampNs: UInt64 = 0
    public var playing = false
    public var playbackRate: Double = 1
    public var renderer: PabloReviewRendererState = .empty
    public var rendererError: String?
    public var selection: PabloReviewSelection?
    public var focusedWindowID: String?
    public var focusedWindowAvailable = true
    public var viewport: RecordingRect?
    public var tool = "inspect"
    public var inspectorVisible = false
    public var inspectorSection = "elements"
    public var draft: PabloReviewDraftState?
    public var videoAvailability = PabloEvidenceAvailability.unavailable
    public var accessibilityAvailability = PabloEvidenceAvailability.unavailable
    public var observations: [PabloReviewObservation] = []
    public var pinnedEvidence: PabloReviewSelection?
    public var hoveredEvidence: PabloReviewSelection?
    public var streamIssues: [PabloRecordingStreamIssue] = []
    public var annotationCount = 0
    public var error: String?
    public init(reviewID: UUID) { self.reviewID = reviewID }
}

public enum PabloReviewCommandKind: String, Codable, Sendable {
    case seek, play, pause, rate, focusWindow, selectFrame, selectNode, selectEvent, selectAnnotation
    case clearSelection, tool, showInspector, activate, close, annotate, inspectPoint
}

public struct PabloReviewCommand: Codable, Equatable, Sendable {
    public let kind: PabloReviewCommandKind
    public var x: Double?
    public var y: Double?
    public var seconds: Double?
    public var rate: Double?
    public var reference: String?
    public var nodeID: String?
    public var windowID: String?
    public var tool: String?
    public var visible: Bool?
    public var text: String?
    public var timestampNs: UInt64?
    public var annotationKind: RecordingAnnotationKind?
    public init(kind: PabloReviewCommandKind, x: Double? = nil, y: Double? = nil, seconds: Double? = nil, rate: Double? = nil,
                reference: String? = nil, nodeID: String? = nil, windowID: String? = nil,
                tool: String? = nil, visible: Bool? = nil, text: String? = nil, timestampNs: UInt64? = nil,
                annotationKind: RecordingAnnotationKind? = nil) {
        self.x = x; self.y = y
        self.kind = kind; self.seconds = seconds; self.rate = rate
        self.reference = reference; self.nodeID = nodeID; self.windowID = windowID
        self.tool = tool; self.visible = visible
        self.text = text; self.timestampNs = timestampNs; self.annotationKind = annotationKind
    }

    public func validate() throws {
        guard seconds.map({ $0.isFinite && $0 >= 0 && $0 <= 9_223_372_036 }) ?? true,
              rate.map({ $0.isFinite && (0.5...8).contains($0) }) ?? true else {
            throw RecordingError.usage("Review time or playback rate is out of range.")
        }
        switch kind {
        case .inspectPoint:
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw RecordingError.usage("inspectPoint requires normalized x and y in the review viewport.")
            }
        case .annotate:
            guard text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, timestampNs != nil else {
                throw RecordingError.usage("annotate requires text and an explicit session timestampNs from the reviewed evidence.")
            }
        case .seek: guard seconds != nil else { throw RecordingError.usage("seek requires seconds.") }
        case .rate: guard rate != nil else { throw RecordingError.usage("rate requires rate.") }
        case .selectFrame, .selectEvent, .selectAnnotation, .selectNode:
            guard reference?.isEmpty == false else { throw RecordingError.usage("Selection requires reference.") }
            if kind == .selectNode, nodeID?.isEmpty != false { throw RecordingError.usage("selectNode requires nodeID.") }
        case .tool:
            guard ["inspect", "notes", "pen", "comment"].contains(tool) else { throw RecordingError.usage("Unknown review tool.") }
        case .showInspector:
            guard visible != nil else { throw RecordingError.usage("showInspector requires visible.") }
        default: break
        }
    }
}

public struct PabloReviewCommandRequest: Codable, Equatable, Sendable {
    public let reviewID: UUID
    public let serviceID: UUID
    public let operationID: UUID
    public let issuedAt: Date
    public let expectedSourceGeneration: UUID
    public let expectedRevision: UInt64
    public let command: PabloReviewCommand
    public init(reviewID: UUID, serviceID: UUID, operationID: UUID = UUID(), issuedAt: Date = Date(),
                expectedSourceGeneration: UUID, expectedRevision: UInt64, command: PabloReviewCommand) {
        self.reviewID = reviewID; self.serviceID = serviceID; self.operationID = operationID
        self.issuedAt = issuedAt; self.expectedSourceGeneration = expectedSourceGeneration
        self.expectedRevision = expectedRevision; self.command = command
    }
}

public enum PabloReviewOperationStatus: String, Codable, Sendable {
    case running, cancellationRequested, completed, failed, staleContext, draftConflict, interrupted
}

public struct PabloReviewOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let reviewID: UUID
    public var status: PabloReviewOperationStatus
    public var error: String?
    public var state: PabloReviewState?
    public var annotation: RecordingAnnotation?
    public var annotationReference: String?
    public let expiresAt: Date
    public init(operationID: UUID, reviewID: UUID, status: PabloReviewOperationStatus, expiresAt: Date) {
        self.operationID = operationID; self.reviewID = reviewID
        self.status = status; self.expiresAt = expiresAt
    }
}

public struct PabloReviewOperationRequest: Codable, Sendable {
    public let serviceID: UUID
    public let operationID: UUID
    public init(serviceID: UUID, operationID: UUID) {
        self.serviceID = serviceID; self.operationID = operationID
    }
}

public struct PabloReviewStateRequest: Codable, Sendable {
    public let reviewID: UUID
    public init(reviewID: UUID) { self.reviewID = reviewID }
}
