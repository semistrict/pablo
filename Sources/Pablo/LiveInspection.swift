import AppKit
import ApplicationServices
import Foundation

struct LiveAccessibilityHistory {
    private(set) var currentNodes: [String: AXNode] = [:]
    private(set) var steps: [ReplayAccessibilityStep] = []
    private(set) var nextStepID = 0
    let maximumSteps: Int

    init(maximumSteps: Int = 128) {
        self.maximumSteps = maximumSteps
    }

    @discardableResult
    mutating func append(
        _ tree: AXTreeSnapshot,
        timestampNs: UInt64,
        reason: String,
        application: RecordingApplication
    ) -> ReplayAccessibilityStep {
        let diff = AXTreeDiffer.diff(previous: currentNodes, current: tree.nodes)
        let isInitial = currentNodes.isEmpty
        let changedIDs = Set((isInitial ? Array(tree.nodes.values) : diff.upserts).map(\.id))
        let nodes = Self.flatten(nodes: tree.nodes, rootID: tree.rootID)
        let step = ReplayAccessibilityStep(
            id: nextStepID,
            timestampNs: timestampNs,
            reason: reason,
            kind: isInitial ? "full" : "delta",
            applicationID: application.id,
            applicationName: application.name,
            applicationBundleIdentifier: application.bundleIdentifier,
            applicationPID: application.pid,
            rootID: tree.rootID,
            nodes: nodes,
            changedNodes: nodes.filter { changedIDs.contains($0.id) },
            changedNodeIDs: changedIDs,
            removedNodeIDs: isInitial ? [] : diff.removed,
            totalNodeCount: tree.nodes.count,
            truncated: tree.truncated
        )
        nextStepID += 1
        steps.append(step)
        if steps.count > maximumSteps {
            steps.removeFirst(steps.count - maximumSteps)
        }
        currentNodes = tree.nodes
        return step
    }

    func step(id: Int) -> ReplayAccessibilityStep? {
        steps.first { $0.id == id }
    }

    private static func flatten(
        nodes: [String: AXNode],
        rootID: String?
    ) -> [ReplayAccessibilityNode] {
        var visited = Set<String>()
        var result: [ReplayAccessibilityNode] = []

        func visit(_ id: String, depth: Int) {
            guard depth < 100, !visited.contains(id), let node = nodes[id] else { return }
            visited.insert(id)
            result.append(ReplayAccessibilityNode(node, depth: depth))
            for childID in node.childIDs { visit(childID, depth: depth + 1) }
        }

        if let rootID { visit(rootID, depth: 0) }
        for id in nodes.keys.sorted() where !visited.contains(id) { visit(id, depth: 0) }
        return result
    }
}

public final class PabloLiveInspectionManager {
    private var sessions: [pid_t: LiveInspectionSession] = [:]
    private let maximumSessions = 8

    public init() {}

    public func perform(_ request: PabloLiveInspectionRequest) throws -> String {
        pruneTerminatedSessions()
        let target = try TargetApplication.resolve(
            pid: request.target.pid,
            bundleIdentifier: request.target.bundleIdentifier,
            appName: request.target.appName
        )
        let session = session(for: target)

        switch request.kind {
        case .inspect:
            try session.capture(reason: "live:inspect")
            return try session.inspectOutput()
        case .frames:
            try session.capture(reason: "live:frames")
            return try session.framesOutput()
        case .frame:
            guard let reference = request.reference else {
                throw RecordingError.usage("The live frame request did not include a frame reference.")
            }
            let step = try session.step(reference: reference)
            return try session.frameOutput(step, changedOnly: request.changedOnly)
        case .events:
            try session.startEventObservation()
            return try session.eventsOutput(limit: request.limit)
        case .annotations:
            return try session.annotationsOutput()
        }
    }

    func actionContext(
        for targetRequest: PabloLiveApplicationTarget,
        requiresSnapshot: Bool
    ) throws -> LiveActionContext {
        pruneTerminatedSessions()
        let target = try TargetApplication.resolve(
            pid: targetRequest.pid,
            bundleIdentifier: targetRequest.bundleIdentifier,
            appName: targetRequest.appName
        )
        let session = session(for: target)
        if requiresSnapshot, session.latestSnapshot == nil {
            try session.capture(reason: "live:action")
        }
        return session.actionContext
    }

    private func session(for target: TargetApplication) -> LiveInspectionSession {
        if let existing = sessions[target.pid], existing.matches(target) {
            existing.lastAccess = Date()
            return existing
        }
        if sessions.count >= maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            sessions.removeValue(forKey: oldest)
        }
        let session = LiveInspectionSession(target: target)
        sessions[target.pid] = session
        return session
    }

    private func pruneTerminatedSessions() {
        sessions = sessions.filter { pid, _ in
            NSRunningApplication(processIdentifier: pid) != nil
        }
    }
}

struct LiveActionContext {
    let target: TargetApplication
    let reader: AccessibilityTreeReader
    let snapshot: AXTreeSnapshot?
}

private final class LiveInspectionSession {
    private struct Summary: Codable {
        struct Target: Codable {
            let pid: Int32
            let bundleIdentifier: String?
            let name: String
        }

        let live: Bool
        let startedAt: String
        let elapsedNanoseconds: UInt64
        let target: Target
        let inputEventCount: Int
        let accessibilityRecordCount: Int
        let annotationCount: Int
    }

    private struct IndexedEvent {
        let index: Int
        let record: InputEventRecord
    }

    private let target: TargetApplication
    private let clock = SessionClock()
    private let startedAt = Date()
    private let reader: AccessibilityTreeReader
    private let registry = RecordingApplicationRegistry()
    private let application: RecordingApplication
    private var accessibilityHistory = LiveAccessibilityHistory()
    private let eventLock = NSLock()
    private var indexedEvents: [IndexedEvent] = []
    private var nextEventIndex = 1
    private let maximumEvents = 10_000
    private var inputRecorder: InputRecorder?
    private(set) var latestSnapshot: AXTreeSnapshot?
    var lastAccess = Date()

    init(target: TargetApplication) {
        self.target = target
        application = registry.application(for: target.pid, timestampNs: 0)!
        reader = AccessibilityTreeReader(pid: target.pid, applicationID: application.id)
    }

    deinit {
        inputRecorder?.stop()
    }

    func matches(_ candidate: TargetApplication) -> Bool {
        target.pid == candidate.pid && target.bundleIdentifier == candidate.bundleIdentifier
    }

    func capture(reason: String) throws {
        guard AXIsProcessTrusted() else {
            throw RecordingError.permission(
                "Accessibility access is required to inspect a live application. " +
                "Enable Pablo in System Settings > Privacy & Security > Accessibility."
            )
        }
        let tree = reader.read()
        latestSnapshot = tree
        accessibilityHistory.append(
            tree,
            timestampNs: clock.nowNanoseconds(),
            reason: reason,
            application: application
        )
        lastAccess = Date()
    }

    var actionContext: LiveActionContext {
        LiveActionContext(target: target, reader: reader, snapshot: latestSnapshot)
    }

    func step(reference: String) throws -> ReplayAccessibilityStep {
        let id = try Self.frameID(reference)
        if accessibilityHistory.steps.isEmpty || id == accessibilityHistory.nextStepID {
            try capture(reason: "live:frame")
        }
        guard let step = accessibilityHistory.step(id: id) else {
            let first = accessibilityHistory.steps.first?.reference ?? "none"
            let last = accessibilityHistory.steps.last?.reference ?? "none"
            throw RecordingError.usage(
                "Frame \(reference) is not retained for this live app; available frames are \(first) through \(last)."
            )
        }
        return step
    }

    func startEventObservation() throws {
        if inputRecorder != nil { return }
        guard CGPreflightListenEventAccess() else {
            throw RecordingError.permission(
                "Input Monitoring access is required to inspect live input events. " +
                "Enable Pablo in System Settings > Privacy & Security > Input Monitoring."
            )
        }
        if accessibilityHistory.steps.isEmpty { try capture(reason: "live:events") }
        let recorder = InputRecorder(
            scope: .application,
            selectedPID: target.pid,
            registry: registry,
            clock: clock,
            includeText: true,
            targetFrame: { [weak self] in self?.largestWindowFrame() }
        ) { [weak self] record in
            self?.appendEvent(record)
        }
        try recorder.start()
        inputRecorder = recorder
        lastAccess = Date()
    }

    func inspectOutput() throws -> String {
        let eventCount = eventLock.withLock { indexedEvents.count }
        return try jsonString(Summary(
            live: true,
            startedAt: ISO8601DateFormatter.recordingFormatter.string(from: startedAt),
            elapsedNanoseconds: clock.nowNanoseconds(),
            target: .init(
                pid: target.pid,
                bundleIdentifier: target.bundleIdentifier,
                name: target.name
            ),
            inputEventCount: eventCount,
            accessibilityRecordCount: accessibilityHistory.nextStepID,
            annotationCount: 0
        ))
    }

    func framesOutput() throws -> String {
        try jsonString(accessibilityHistory.steps)
    }

    func frameOutput(
        _ step: ReplayAccessibilityStep,
        changedOnly: Bool
    ) throws -> String {
        guard changedOnly else { return try jsonString(step) }
        return try jsonString(ReplayAccessibilityStep(
            id: step.id,
            timestampNs: step.timestampNs,
            reason: step.reason,
            kind: step.kind,
            applicationID: step.applicationID,
            applicationName: step.applicationName,
            applicationBundleIdentifier: step.applicationBundleIdentifier,
            applicationPID: step.applicationPID,
            rootID: step.rootID,
            nodes: step.changedNodes,
            changedNodes: step.changedNodes,
            changedNodeIDs: step.changedNodeIDs,
            removedNodeIDs: step.removedNodeIDs,
            totalNodeCount: step.totalNodeCount,
            truncated: step.truncated
        ))
    }

    func eventsOutput(limit: Int) throws -> String {
        let allEvents = eventLock.withLock { indexedEvents }
        let limited = Array(allEvents.prefix(limit))
        return try jsonString(limited.map(\.record))
    }

    func annotationsOutput() throws -> String {
        try jsonString([RecordingAnnotation]())
    }

    private func appendEvent(_ record: InputEventRecord) {
        eventLock.withLock {
            indexedEvents.append(IndexedEvent(index: nextEventIndex, record: record))
            nextEventIndex += 1
            if indexedEvents.count > maximumEvents {
                indexedEvents.removeFirst(indexedEvents.count - maximumEvents)
            }
        }
    }

    private func largestWindowFrame() -> CGRect? {
        accessibilityHistory.currentNodes.values
            .filter { $0.role == "AXWindow" && $0.position != nil && $0.size != nil }
            .compactMap { node -> CGRect? in
                guard let position = node.position, let size = node.size else { return nil }
                return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func frameID(_ reference: String) throws -> Int {
        var value = reference.uppercased()
        if value.hasPrefix("A11Y-") { value.removeFirst(5) }
        if value.hasPrefix("#") { value.removeFirst() }
        guard let number = Int(value), number > 0 else {
            throw RecordingError.usage("Frame must look like A11Y-012 or 12.")
        }
        return number - 1
    }
}

private func jsonString<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
