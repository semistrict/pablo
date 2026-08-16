import Foundation

enum PabloProtobufCodec {
    static func encode(_ value: InputEventRecord) throws -> Data {
        try ProtobufStream.frame(value.protobuf)
    }

    static func encode(_ value: AXSnapshotRecord) throws -> Data {
        try ProtobufStream.frame(value.protobuf)
    }

    static func encode(_ value: WorkspaceSnapshotRecord) throws -> Data {
        try ProtobufStream.frame(value.protobuf)
    }

    static func encode(_ value: RecordingAnnotation) throws -> Data {
        try ProtobufStream.frame(value.protobuf)
    }

    static func decodeEvents(from data: Data) throws -> [InputEventRecord] {
        try ProtobufStream.decode(PabloV3InputEventRecord.self, from: data).map(InputEventRecord.init)
    }

    static func decodeAccessibility(from data: Data) throws -> [AXSnapshotRecord] {
        try ProtobufStream.decode(PabloV3AccessibilitySnapshotRecord.self, from: data)
            .map(AXSnapshotRecord.init)
    }

    static func decodeWorkspace(from data: Data) throws -> [WorkspaceSnapshotRecord] {
        try ProtobufStream.decode(PabloV3WorkspaceSnapshotRecord.self, from: data)
            .map(WorkspaceSnapshotRecord.init)
    }

    static func decodeAnnotations(from data: Data) throws -> [RecordingAnnotation] {
        try ProtobufStream.decode(PabloV3RecordingAnnotation.self, from: data)
            .map(RecordingAnnotation.init)
    }

}

private func requiredUUID(_ value: String, field: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        throw RecordingError.capture("A protobuf \(field) is not a valid UUID.")
    }
    return uuid
}

private func requiredDate(_ value: String, field: String) throws -> Date {
    guard let date = ISO8601DateFormatter.recordingFormatter.date(from: value) else {
        throw RecordingError.capture("A protobuf \(field) is not a valid ISO 8601 timestamp.")
    }
    return date
}

private extension PabloLivePoint {
    var protobuf: PabloV3Point { .with { $0.x = x; $0.y = y } }
    init(_ value: PabloV3Point) { self.init(x: value.x, y: value.y) }
}

private extension PabloLiveApplicationTarget {
    var protobuf: PabloV3LiveApplicationTarget {
        .with {
            if let pid { $0.pid = pid }
            if let bundleIdentifier { $0.bundleIdentifier = bundleIdentifier }
            if let appName { $0.appName = appName }
        }
    }

    init(_ value: PabloV3LiveApplicationTarget) {
        self.init(
            pid: value.hasPid ? value.pid : nil,
            bundleIdentifier: value.hasBundleIdentifier ? value.bundleIdentifier : nil,
            appName: value.hasAppName ? value.appName : nil
        )
    }
}

private extension PabloLiveActionKind {
    var protobuf: PabloV3LiveActionKind {
        switch self {
        case .click: .click
        case .drag: .drag
        case .scroll: .scroll
        case .typeText: .type
        case .key: .key
        case .perform: .perform
        }
    }

    init(_ value: PabloV3LiveActionKind) throws {
        switch value {
        case .click: self = .click
        case .drag: self = .drag
        case .scroll: self = .scroll
        case .type: self = .typeText
        case .key: self = .key
        case .perform: self = .perform
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf live action has an unknown kind.")
        }
    }
}

private extension PabloLiveMouseButton {
    var protobuf: PabloV3MouseButton {
        switch self { case .left: .left; case .right: .right; case .middle: .middle }
    }

    init(_ value: PabloV3MouseButton) throws {
        switch value {
        case .left: self = .left
        case .right: self = .right
        case .middle: self = .middle
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf live action has an unknown mouse button.")
        }
    }
}

private extension PabloLiveScrollDirection {
    var protobuf: PabloV3ScrollDirection {
        switch self { case .up: .up; case .down: .down; case .left: .left; case .right: .right }
    }

    init(_ value: PabloV3ScrollDirection) throws {
        switch value {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf live action has an unknown scroll direction.")
        }
    }
}

private extension PabloLiveKeyModifier {
    var protobuf: PabloV3KeyModifier {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        case .function: .function
        }
    }

    init(_ value: PabloV3KeyModifier) throws {
        switch value {
        case .command: self = .command
        case .option: self = .option
        case .control: self = .control
        case .shift: self = .shift
        case .function: self = .function
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf live action has an unknown key modifier.")
        }
    }
}

private extension PabloAutomationActionPhase {
    var protobuf: PabloV3AutomationActionPhase {
        switch self { case .requested: .requested; case .succeeded: .succeeded; case .failed: .failed }
    }

    init(_ value: PabloV3AutomationActionPhase) throws {
        switch value {
        case .requested: self = .requested
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf automation trace has an unknown phase.")
        }
    }
}

private extension PabloAutomationCaller {
    var protobuf: PabloV3AutomationCaller {
        .with {
            $0.displayName = displayName
            if let applicationIdentifier { $0.applicationIdentifier = applicationIdentifier }
            if let developerName { $0.developerName = developerName }
            if let developerTeamIdentifier { $0.developerTeamIdentifier = developerTeamIdentifier }
            $0.verified = verified
        }
    }

    init(_ value: PabloV3AutomationCaller) {
        self.init(
            displayName: value.displayName,
            applicationIdentifier: value.hasApplicationIdentifier ? value.applicationIdentifier : nil,
            developerName: value.hasDeveloperName ? value.developerName : nil,
            developerTeamIdentifier: value.hasDeveloperTeamIdentifier ? value.developerTeamIdentifier : nil,
            verified: value.verified
        )
    }
}

private extension PabloAutomationActionTrace {
    var protobuf: PabloV3AutomationActionTrace {
        .with {
            $0.actionID = actionID.uuidString
            $0.phase = phase.protobuf
            $0.kind = kind.protobuf
            $0.target = target.protobuf
            if let nodeID { $0.nodeID = nodeID }
            if let point { $0.point = point.protobuf }
            if let fromNodeID { $0.fromNodeID = fromNodeID }
            if let fromPoint { $0.fromPoint = fromPoint.protobuf }
            if let toNodeID { $0.toNodeID = toNodeID }
            if let toPoint { $0.toPoint = toPoint.protobuf }
            $0.mouseButton = mouseButton.protobuf
            $0.clickCount = Int64(clickCount)
            $0.duration = duration
            if let scrollDirection { $0.scrollDirection = scrollDirection.protobuf }
            $0.scrollAmount = Int64(scrollAmount)
            if let textLength { $0.textLength = Int64(textLength) }
            if let key { $0.key = key }
            $0.modifiers = modifiers.map(\.protobuf)
            if let accessibilityAction { $0.accessibilityAction = accessibilityAction }
            $0.foregroundActionsUnlocked = foregroundActionsUnlocked
            $0.caller = caller.protobuf
            $0.transport = transport
            $0.recordingWasPaused = recordingWasPaused
            if let resolvedApplicationID { $0.resolvedApplicationID = resolvedApplicationID }
        }
    }

    init(_ value: PabloV3AutomationActionTrace) throws {
        self.init(
            actionID: try requiredUUID(value.actionID, field: "automation action ID"),
            phase: try PabloAutomationActionPhase(value.phase),
            kind: try PabloLiveActionKind(value.kind),
            target: PabloLiveApplicationTarget(value.target),
            nodeID: value.hasNodeID ? value.nodeID : nil,
            point: value.hasPoint ? PabloLivePoint(value.point) : nil,
            fromNodeID: value.hasFromNodeID ? value.fromNodeID : nil,
            fromPoint: value.hasFromPoint ? PabloLivePoint(value.fromPoint) : nil,
            toNodeID: value.hasToNodeID ? value.toNodeID : nil,
            toPoint: value.hasToPoint ? PabloLivePoint(value.toPoint) : nil,
            mouseButton: try PabloLiveMouseButton(value.mouseButton),
            clickCount: Int(value.clickCount),
            duration: value.duration,
            scrollDirection: value.hasScrollDirection ? try PabloLiveScrollDirection(value.scrollDirection) : nil,
            scrollAmount: Int(value.scrollAmount),
            textLength: value.hasTextLength ? Int(value.textLength) : nil,
            key: value.hasKey ? value.key : nil,
            modifiers: try value.modifiers.map(PabloLiveKeyModifier.init),
            accessibilityAction: value.hasAccessibilityAction ? value.accessibilityAction : nil,
            foregroundActionsUnlocked: value.foregroundActionsUnlocked,
            caller: PabloAutomationCaller(value.caller),
            transport: value.transport,
            recordingWasPaused: value.recordingWasPaused,
            resolvedApplicationID: value.hasResolvedApplicationID ? value.resolvedApplicationID : nil
        )
    }
}

extension InputEventRecord {
    var protobuf: PabloV3InputEventRecord {
        .with {
            $0.schemaVersion = UInt32(schemaVersion)
            $0.timestampNs = timestampNs
            $0.type = type
            if let targetPID { $0.targetPid = targetPID }
            if let applicationID { $0.applicationID = applicationID }
            if let windowID { $0.windowID = windowID }
            if let x { $0.x = x }
            if let y { $0.y = y }
            if let deltaX { $0.deltaX = deltaX }
            if let deltaY { $0.deltaY = deltaY }
            if let keyCode { $0.keyCode = keyCode }
            if let text { $0.text = text }
            $0.flags = flags
            if let button { $0.button = button }
            if let clickCount { $0.clickCount = clickCount }
            if let automationAction { $0.automationAction = automationAction.protobuf }
        }
    }

    init(_ value: PabloV3InputEventRecord) throws {
        self.init(
            schemaVersion: Int(value.schemaVersion),
            timestampNs: value.timestampNs,
            type: value.type,
            targetPID: value.hasTargetPid ? value.targetPid : nil,
            applicationID: value.hasApplicationID ? value.applicationID : nil,
            windowID: value.hasWindowID ? value.windowID : nil,
            x: value.hasX ? value.x : nil,
            y: value.hasY ? value.y : nil,
            deltaX: value.hasDeltaX ? value.deltaX : nil,
            deltaY: value.hasDeltaY ? value.deltaY : nil,
            keyCode: value.hasKeyCode ? value.keyCode : nil,
            text: value.hasText ? value.text : nil,
            flags: value.flags,
            button: value.hasButton ? value.button : nil,
            clickCount: value.hasClickCount ? value.clickCount : nil,
            automationAction: value.hasAutomationAction ? try PabloAutomationActionTrace(value.automationAction) : nil
        )
    }
}

private extension AXNode.Point {
    var protobuf: PabloV3Point { .with { $0.x = x; $0.y = y } }
    init(_ value: PabloV3Point) { self.init(x: value.x, y: value.y) }
}

private extension AXNode.Size {
    var protobuf: PabloV3Size { .with { $0.width = width; $0.height = height } }
    init(_ value: PabloV3Size) { self.init(width: value.width, height: value.height) }
}

private extension RecordingRect {
    var protobuf: PabloV3Rect {
        .with { $0.x = x; $0.y = y; $0.width = width; $0.height = height }
    }

    init(_ value: PabloV3Rect) {
        self.init(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}

private extension RecordingApplication {
    var protobuf: PabloV3ApplicationDescriptor {
        .with {
            $0.id = id
            $0.pid = pid
            if let bundleIdentifier { $0.bundleIdentifier = bundleIdentifier }
            $0.name = name
            $0.firstSeenTimestampNs = firstSeenTimestampNs
            if let lastSeenTimestampNs { $0.lastSeenTimestampNs = lastSeenTimestampNs }
        }
    }

    init(_ value: PabloV3ApplicationDescriptor) {
        self.init(
            id: value.id,
            pid: value.pid,
            bundleIdentifier: value.hasBundleIdentifier ? value.bundleIdentifier : nil,
            name: value.name,
            firstSeenTimestampNs: value.firstSeenTimestampNs,
            lastSeenTimestampNs: value.hasLastSeenTimestampNs ? value.lastSeenTimestampNs : nil
        )
    }
}

private extension RecordingWindow {
    var protobuf: PabloV3WindowDescriptor {
        .with {
            $0.id = id
            $0.applicationID = applicationID
            $0.systemWindowID = systemWindowID
            if let title { $0.title = title }
            $0.frame = frame.protobuf
            $0.layer = Int64(layer)
            $0.isOnScreen = isOnScreen
            $0.zOrder = zOrder
        }
    }

    init(_ value: PabloV3WindowDescriptor) {
        self.init(
            id: value.id,
            applicationID: value.applicationID,
            systemWindowID: value.systemWindowID,
            title: value.hasTitle ? value.title : nil,
            frame: RecordingRect(value.frame),
            layer: Int(value.layer),
            isOnScreen: value.isOnScreen,
            zOrder: value.zOrder
        )
    }
}

extension WorkspaceSnapshotRecord {
    var protobuf: PabloV3WorkspaceSnapshotRecord {
        .with {
            $0.schemaVersion = UInt32(schemaVersion)
            $0.timestampNs = timestampNs
            $0.reason = reason
            if let frontmostApplicationID { $0.frontmostApplicationID = frontmostApplicationID }
            $0.applications = applications.map(\.protobuf)
            $0.windows = windows.map(\.protobuf)
            $0.appearedApplicationIds = appearedApplicationIDs
            $0.removedApplicationIds = removedApplicationIDs
            $0.appearedWindowIds = appearedWindowIDs
            $0.removedWindowIds = removedWindowIDs
        }
    }

    init(_ value: PabloV3WorkspaceSnapshotRecord) {
        self.init(
            schemaVersion: Int(value.schemaVersion),
            timestampNs: value.timestampNs,
            reason: value.reason,
            frontmostApplicationID: value.hasFrontmostApplicationID ? value.frontmostApplicationID : nil,
            applications: value.applications.map(RecordingApplication.init),
            windows: value.windows.map(RecordingWindow.init),
            appearedApplicationIDs: value.appearedApplicationIds,
            removedApplicationIDs: value.removedApplicationIds,
            appearedWindowIDs: value.appearedWindowIds,
            removedWindowIDs: value.removedWindowIds
        )
    }
}

private extension AXNode {
    var protobuf: PabloV3AccessibilityNode {
        .with {
            $0.id = id
            if let parentID { $0.parentID = parentID }
            $0.childIds = childIDs
            if let role { $0.role = role }
            if let subrole { $0.subrole = subrole }
            if let title { $0.title = title }
            if let label { $0.label = label }
            if let value { $0.value = value }
            if let identifier { $0.identifier = identifier }
            if let help { $0.help = help }
            if let enabled { $0.enabled = enabled }
            if let focused { $0.focused = focused }
            if let position { $0.position = position.protobuf }
            if let size { $0.size = size.protobuf }
        }
    }

    init(_ value: PabloV3AccessibilityNode) {
        self.init(
            id: value.id,
            parentID: value.hasParentID ? value.parentID : nil,
            childIDs: value.childIds,
            role: value.hasRole ? value.role : nil,
            subrole: value.hasSubrole ? value.subrole : nil,
            title: value.hasTitle ? value.title : nil,
            label: value.hasLabel ? value.label : nil,
            value: value.hasValue ? value.value : nil,
            identifier: value.hasIdentifier ? value.identifier : nil,
            help: value.hasHelp ? value.help : nil,
            enabled: value.hasEnabled ? value.enabled : nil,
            focused: value.hasFocused ? value.focused : nil,
            position: value.hasPosition ? AXNode.Point(value.position) : nil,
            size: value.hasSize ? AXNode.Size(value.size) : nil
        )
    }
}

extension AXSnapshotRecord {
    var protobuf: PabloV3AccessibilitySnapshotRecord {
        .with {
            $0.schemaVersion = UInt32(schemaVersion)
            $0.timestampNs = timestampNs
            $0.reason = reason
            $0.kind = kind
            $0.application = application.protobuf
            if let rootID { $0.rootID = rootID }
            $0.upserts = upserts.map(\.protobuf)
            $0.removed = removed
            $0.truncated = truncated
        }
    }

    init(_ value: PabloV3AccessibilitySnapshotRecord) {
        self.init(
            schemaVersion: Int(value.schemaVersion),
            timestampNs: value.timestampNs,
            reason: value.reason,
            kind: value.kind,
            application: RecordingApplication(value.application),
            rootID: value.hasRootID ? value.rootID : nil,
            upserts: value.upserts.map(AXNode.init),
            removed: value.removed,
            truncated: value.truncated
        )
    }
}

private extension RecordingAnnotationKind {
    var protobuf: PabloV3AnnotationKind {
        switch self {
        case .issue: .issue
        case .observation: .observation
        case .question: .question
        case .highlight: .highlight
        }
    }

    init(_ value: PabloV3AnnotationKind) throws {
        switch value {
        case .issue: self = .issue
        case .observation: self = .observation
        case .question: self = .question
        case .highlight: self = .highlight
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf annotation has an unknown kind.")
        }
    }
}

private extension RecordingAnnotationStatus {
    var protobuf: PabloV3AnnotationStatus {
        switch self { case .open: .open; case .resolved: .resolved }
    }

    init(_ value: PabloV3AnnotationStatus) throws {
        switch value {
        case .open: self = .open
        case .resolved: self = .resolved
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf annotation has an unknown status.")
        }
    }
}

private extension RecordingAnnotationAuthorType {
    var protobuf: PabloV3AnnotationAuthorType {
        switch self { case .human: .human; case .application: .application }
    }

    init(_ value: PabloV3AnnotationAuthorType) throws {
        switch value {
        case .human: self = .human
        case .application: self = .application
        case .unspecified, .UNRECOGNIZED:
            throw RecordingError.capture("A protobuf annotation has an unknown author type.")
        }
    }
}

private extension RecordingAnnotationAuthor {
    var protobuf: PabloV3AnnotationAuthor {
        .with {
            $0.type = type.protobuf
            $0.displayName = displayName
            if let applicationIdentifier { $0.applicationIdentifier = applicationIdentifier }
            if let developerName { $0.developerName = developerName }
            if let developerTeamIdentifier { $0.developerTeamIdentifier = developerTeamIdentifier }
        }
    }

    init(_ value: PabloV3AnnotationAuthor) throws {
        self.init(
            type: try RecordingAnnotationAuthorType(value.type),
            displayName: value.displayName,
            applicationIdentifier: value.hasApplicationIdentifier ? value.applicationIdentifier : nil,
            developerName: value.hasDeveloperName ? value.developerName : nil,
            developerTeamIdentifier: value.hasDeveloperTeamIdentifier ? value.developerTeamIdentifier : nil
        )
    }
}

private extension RecordingAnnotationTraceSample {
    var protobuf: PabloV3AnnotationTraceSample {
        .with { $0.timestampNs = timestampNs; $0.x = x; $0.y = y }
    }

    init(_ value: PabloV3AnnotationTraceSample) {
        self.init(timestampNs: value.timestampNs, x: value.x, y: value.y)
    }
}

private extension RecordingAnnotationTrace {
    var protobuf: PabloV3AnnotationTrace {
        .with { $0.samples = samples.map(\.protobuf); $0.lineWidth = lineWidth }
    }

    init(_ value: PabloV3AnnotationTrace) {
        self.init(samples: value.samples.map(RecordingAnnotationTraceSample.init), lineWidth: value.lineWidth)
    }
}

extension RecordingAnnotation {
    var protobuf: PabloV3RecordingAnnotation {
        .with {
            $0.id = id.uuidString
            $0.sequence = Int64(sequence)
            $0.createdAt = ISO8601DateFormatter.recordingFormatter.string(from: createdAt)
            $0.updatedAt = ISO8601DateFormatter.recordingFormatter.string(from: updatedAt)
            $0.createdBy = createdBy.protobuf
            $0.updatedBy = updatedBy.protobuf
            $0.kind = kind.protobuf
            $0.status = status.protobuf
            $0.text = text
            if let startTimestampNs { $0.startTimestampNs = startTimestampNs }
            if let endTimestampNs { $0.endTimestampNs = endTimestampNs }
            $0.applicationIds = applicationIDs
            $0.accessibilityReferences = accessibilityReferences
            $0.accessibilityNodeIds = accessibilityNodeIDs
            if let trace { $0.trace = trace.protobuf }
        }
    }

    init(_ value: PabloV3RecordingAnnotation) throws {
        self.init(
            id: try requiredUUID(value.id, field: "annotation ID"),
            sequence: Int(value.sequence),
            createdAt: try requiredDate(value.createdAt, field: "annotation creation time"),
            updatedAt: try requiredDate(value.updatedAt, field: "annotation update time"),
            createdBy: try RecordingAnnotationAuthor(value.createdBy),
            updatedBy: try RecordingAnnotationAuthor(value.updatedBy),
            kind: try RecordingAnnotationKind(value.kind),
            status: try RecordingAnnotationStatus(value.status),
            text: value.text,
            startTimestampNs: value.hasStartTimestampNs ? value.startTimestampNs : nil,
            endTimestampNs: value.hasEndTimestampNs ? value.endTimestampNs : nil,
            applicationIDs: value.applicationIds,
            accessibilityReferences: value.accessibilityReferences,
            accessibilityNodeIDs: value.accessibilityNodeIds,
            trace: value.hasTrace ? RecordingAnnotationTrace(value.trace) : nil
        )
    }
}
