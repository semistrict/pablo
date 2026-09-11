import AppKit
import ApplicationServices
import Foundation

struct LiveAccessibilityHistory {
    let sessionID = UUID()
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

    func reference(for step: ReplayAccessibilityStep) -> String {
        "LIVE-\(sessionID.uuidString)/\(step.reference)"
    }

    func step(reference: String) throws -> ReplayAccessibilityStep {
        let prefix = "LIVE-\(sessionID.uuidString)/A11Y-"
        let value = reference.uppercased()
        guard value.hasPrefix(prefix), let ordinal = Int(value.dropFirst(prefix.count)), ordinal > 0,
              let step = step(id: ordinal - 1) else {
            throw RecordingError.staleContext("The live frame reference is stale or no longer retained. Read fresh frames for this target.")
        }
        return step
    }

    func requireCurrentFrame(_ reference: String) throws {
        guard let latest = steps.last, reference.uppercased() == self.reference(for: latest) else {
            throw RecordingError.staleContext("The live frame context changed. Inspect the application again before acting.")
        }
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

@MainActor
public final class PabloLiveInspectionManager {
    private var sessions: [pid_t: LiveInspectionSession] = [:]
    private let maximumSessions = 8

    public init() {}

    public func observationStates() -> [PabloLiveObservationState] {
        pruneTerminatedSessions()
        return sessions.values.compactMap(\.observationState).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func stopAllObservations() {
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
    }

    public func perform(_ request: PabloLiveInspectionRequest) async throws -> String {
        try request.validate()
        pruneTerminatedSessions()
        let target = try TargetApplication.resolve(
            pid: request.target.pid,
            bundleIdentifier: request.target.bundleIdentifier,
            appName: request.target.appName
        )
        let session = try session(for: target, expectedSessionID: request.target.sessionID)

        switch request.kind {
        case .observe:
            return try jsonString(await session.observe(target: request.target, options: request.observation ?? .init()))
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
            return try session.readEvents(limit: request.limit, after: request.after, includeText: request.includeText)
        case .observationStart:
            try session.startEventObservation(includeText: request.includeText)
            return try session.inspectOutput()
        case .observationStatus:
            return try session.inspectOutput()
        case .observationStop:
            session.stopEventObservation()
            let output = try session.inspectOutput()
            session.invalidate()
            sessions.removeValue(forKey: target.pid)
            return output
        case .annotations:
            return try session.annotationsOutput()
        }
    }

    public func observe(target request: PabloLiveApplicationTarget, options: PabloLiveObservationOptions) async throws -> PabloLiveObservation {
        try request.validate()
        try options.validate()
        pruneTerminatedSessions()
        let target = try TargetApplication.resolve(pid: request.pid, bundleIdentifier: request.bundleIdentifier, appName: request.appName)
        return try await session(for: target, expectedSessionID: request.sessionID).observe(target: request, options: options)
    }

    func actionContext(
        for targetRequest: PabloLiveApplicationTarget,
        requiresSnapshot: Bool
    ) throws -> LiveActionContext {
        try targetRequest.validate()
        pruneTerminatedSessions()
        let target = try TargetApplication.resolve(
            pid: targetRequest.pid,
            bundleIdentifier: targetRequest.bundleIdentifier,
            appName: targetRequest.appName
        )
        let session = try session(for: target, expectedSessionID: targetRequest.sessionID)
        if requiresSnapshot, session.latestSnapshot == nil {
            try session.capture(reason: "live:action")
        }
        try session.validateActionTarget(targetRequest)
        return session.actionContext(for: targetRequest)
    }

    private func session(for target: TargetApplication, expectedSessionID: UUID?) throws -> LiveInspectionSession {
        if let existing = sessions[target.pid], existing.matches(target) {
            guard expectedSessionID == nil || expectedSessionID == existing.sessionID else {
                throw RecordingError.staleContext("The live inspection session changed. Read the target again before acting.")
            }
            existing.lastAccess = Date()
            return existing
        }
        guard expectedSessionID == nil else {
            throw RecordingError.staleContext("The live inspection session expired or the target restarted. Read the target again before acting.")
        }
        if sessions.count >= maximumSessions,
           let oldest = sessions.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            sessions.removeValue(forKey: oldest)?.invalidate()
        }
        let session = LiveInspectionSession(target: target)
        sessions[target.pid] = session
        return session
    }

    private func pruneTerminatedSessions() {
        for (pid, session) in sessions where !session.matchesRunningProcess {
            session.invalidate()
            sessions.removeValue(forKey: pid)
        }

    }
}

struct LiveActionContext {
    let sessionID: UUID
    let frameReference: String?
    let target: TargetApplication
    let reader: AccessibilityTreeReader
    let snapshot: AXTreeSnapshot?
    let validate: @MainActor () throws -> Void
}

final class LiveInspectionSession {
    private struct Summary: Codable {
        struct Target: Codable {
            let pid: Int32
            let bundleIdentifier: String?
            let name: String
        }

        let live: Bool
        let sessionID: UUID
        let observing: Bool
        let capturesText: Bool
        let latestFrameReference: String?
        let windows: [LiveWindowSummary]
        let actionCapabilities: LiveActionCapabilities
        let startedAt: String
        let elapsedNanoseconds: UInt64
        let target: Target
        let inputEventCount: Int
        let accessibilityRecordCount: Int
        let annotationCount: Int
    }

    private let target: TargetApplication
    private let requireEventAccess: () throws -> Void
    private let clock = SessionClock()
    private let startedAt = Date()
    private let targetLaunchDate: Date?
    private let reader: AccessibilityTreeReader
    private let registry = RecordingApplicationRegistry()
    private let application: RecordingApplication
    private var accessibilityHistory = LiveAccessibilityHistory()
    private let eventLock = NSLock()
    private var eventHistory = LiveEventHistory()
    private var capturesText = false
    private var invalidated = false
    var sessionID: UUID { accessibilityHistory.sessionID }
    private var inputRecorder: InputRecorder?
    private(set) var latestSnapshot: AXTreeSnapshot?
    var lastAccess = Date()

    init(target: TargetApplication, requireEventAccess: (() throws -> Void)? = nil) {
        self.target = target
        self.requireEventAccess = requireEventAccess ?? {
            guard CGPreflightListenEventAccess() else {
                throw RecordingError.permission(
                    "Input Monitoring access is required to inspect live input events. " +
                    "Enable Pablo in System Settings > Privacy & Security > Input Monitoring."
                )
            }
        }
        targetLaunchDate = NSRunningApplication(processIdentifier: target.pid)?.launchDate
        application = registry.application(for: target.pid, timestampNs: 0)!
        reader = AccessibilityTreeReader(pid: target.pid, applicationID: "LIVE-\(accessibilityHistory.sessionID.uuidString):\(application.id)", captureActions: true)
    }

    deinit {
        inputRecorder?.stop()
    }

    var matchesRunningProcess: Bool {
        guard !invalidated, let current = NSRunningApplication(processIdentifier: target.pid), !current.isTerminated else { return false }
        return current.bundleIdentifier == target.bundleIdentifier && current.launchDate == targetLaunchDate
    }

    func matches(_ candidate: TargetApplication) -> Bool {
        target.pid == candidate.pid && target.bundleIdentifier == candidate.bundleIdentifier && matchesRunningProcess
    }

    var observationState: PabloLiveObservationState? {
        guard inputRecorder != nil else { return nil }
        return .init(id: sessionID, pid: target.pid, applicationName: target.name,
                     bundleIdentifier: target.bundleIdentifier, capturesText: capturesText)
    }

    func capture(reason: String) throws {
        let tree = try readTree()
        commit(tree, reason: reason)
    }

    private func readTree() throws -> AXTreeSnapshot {
        try Task.checkCancellation()
        guard matchesRunningProcess else {
            throw RecordingError.staleContext("The live target process changed. Observe the application again.")
        }
        guard AXIsProcessTrusted() else {
            throw RecordingError.permission(
                "Accessibility access is required to inspect a live application. " +
                "Enable Pablo in System Settings > Privacy & Security > Accessibility."
            )
        }
        return reader.read()
    }

    private func commit(_ tree: AXTreeSnapshot, reason: String) {
        latestSnapshot = tree
        accessibilityHistory.append(
            tree,
            timestampNs: clock.nowNanoseconds(),
            reason: reason,
            application: application
        )
        lastAccess = Date()
    }

    @MainActor
    func observe(target request: PabloLiveApplicationTarget, options: PabloLiveObservationOptions) async throws -> PabloLiveObservation {
        try options.validate()
        if request.frameReference != nil || request.windowID != nil { try validateActionTarget(request) }
        let sampled = try await LiveObservationSampler.sample(options: options, read: readTree)
        let observationID = UUID()
        var selectedWindowID = request.windowID
        var captured: LiveScreenshotCapture.Image?
        if options.screenshot {
            let candidates = sampled.tree.nodes.values.filter { $0.role == "AXWindow" }.compactMap { node -> (AXNode, CGRect)? in
                guard let frame = reader.windowFrame(id: node.id) else { return nil }
                return (node, frame)
            }.sorted { lhs, rhs in
                let leftArea = lhs.1.width * lhs.1.height
                let rightArea = rhs.1.width * rhs.1.height
                return leftArea == rightArea ? lhs.0.id < rhs.0.id : leftArea > rightArea
            }
            let selection = selectedWindowID.flatMap { id in candidates.first { $0.0.id == id } }
                ?? (selectedWindowID == nil ? candidates.first : nil)
            guard let (window, frame) = selection else {
                throw RecordingError.staleContext("A live screenshot requires an available accessible window.")
            }
            selectedWindowID = window.id
            captured = try await LiveScreenshotCapture.capture(pid: target.pid, frame: frame, title: window.title) {
                guard self.matchesRunningProcess, self.reader.windowFrame(id: window.id) == frame else {
                    throw RecordingError.staleContext("The live target or window geometry changed while capturing its image.")
                }
            }
            let after = try readTree()
            guard sampled.tree.rootID == after.rootID, sampled.tree.nodes == after.nodes,
                  sampled.tree.truncated == after.truncated else {
                throw RecordingError.staleContext("Accessibility state changed while capturing the image. Observe the window again.")
            }
        }
        try Task.checkCancellation()
        guard matchesRunningProcess else { throw RecordingError.staleContext("The live target changed while observing it.") }
        commit(sampled.tree, reason: "live:observe")
        let tree = try accessibilityHistory.observation(options: options)
        let screenshot = captured.flatMap { image -> PabloLiveScreenshot? in
            guard let windowID = selectedWindowID else { return nil }
            return .init(observationID: observationID, frameReference: tree.reference, windowID: windowID,
                         captureWindowID: image.captureWindowID,
                         frame: .init(x: image.frame.minX, y: image.frame.minY, width: image.frame.width, height: image.frame.height),
                         width: image.width, height: image.height, mimeType: "image/png", pngBase64: image.pngBase64,
                         startedAtUptimeNanoseconds: image.startedAt, finishedAtUptimeNanoseconds: image.finishedAt)
        }
        return .init(id: observationID, target: .init(pid: target.pid, bundleIdentifier: target.bundleIdentifier,
                                                    applicationName: target.name, windowID: selectedWindowID),
                     tree: tree, settleStatus: sampled.status, sampleCount: sampled.sampleCount,
                     elapsedMilliseconds: sampled.elapsedMilliseconds, screenshot: screenshot)
    }

    func validateActionTarget(_ request: PabloLiveApplicationTarget) throws {
        try Task.checkCancellation()
        guard matches(target) else { throw RecordingError.staleContext("The live target process changed. Inspect the application again.") }
        if let reference = request.frameReference {
            try accessibilityHistory.requireCurrentFrame(reference)
        }
        if let windowID = request.windowID, reader.windowFrame(id: windowID) == nil {
            throw RecordingError.staleContext("The selected live window is stale or unavailable. Inspect the application again.")
        }
    }

    func actionContext(for request: PabloLiveApplicationTarget) -> LiveActionContext {
        LiveActionContext(sessionID: sessionID, frameReference: accessibilityHistory.steps.last.map { accessibilityHistory.reference(for: $0) }, target: target, reader: reader, snapshot: latestSnapshot, validate: { try self.validateActionTarget(request) })
    }

    func step(reference: String) throws -> ReplayAccessibilityStep {
        try accessibilityHistory.step(reference: reference)
    }

    func invalidate() {
        invalidated = true
        stopEventObservation()
    }

    func stopEventObservation() {
        inputRecorder?.stop()
        inputRecorder = nil
        eventLock.withLock { eventHistory = LiveEventHistory() }
        capturesText = false
    }

    func startEventObservation(includeText: Bool?) throws {
        if inputRecorder != nil {
            guard includeText == nil || includeText == capturesText else {
                throw RecordingError.usage("Stop the current observation before changing text capture.")
            }
            return
        }
        try requireEventAccess()
        if accessibilityHistory.steps.isEmpty { try capture(reason: "live:events") }
        let recorder = InputRecorder(
            scope: .application,
            selectedPID: target.pid,
            registry: registry,
            clock: clock,
            includeText: includeText ?? true,
            targetFrame: { [weak self] in self?.largestWindowFrame() }
        ) { [weak self] record in
            self?.appendEvent(record)
        }
        try recorder.start()
        inputRecorder = recorder
        capturesText = includeText ?? true
        lastAccess = Date()
    }

    func inspectOutput() throws -> String {
        let eventCount = eventLock.withLock { eventHistory.events.count }
        return try jsonString(Summary(
            live: true,
            sessionID: sessionID,
            observing: inputRecorder != nil,
            capturesText: capturesText,
            latestFrameReference: accessibilityHistory.steps.last.map { accessibilityHistory.reference(for: $0) },
            windows: accessibilityHistory.steps.last?.nodes.filter { $0.role == "AXWindow" }.map(LiveWindowSummary.init) ?? [],
            actionCapabilities: LiveActionCapabilities(),
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

    private struct LiveWindowSummary: Codable {
        let id: String
        let title: String?
        let frame: ReplayAccessibilityFrame?
        init(_ node: ReplayAccessibilityNode) { id = node.id; title = node.title; frame = node.frame }
    }

    private struct LiveActionCapabilities: Codable {
        var backgroundClickAction = "AXPress"
        var foregroundActionsRequireUnlock = true
        var availableNodeActionsField = "actions"
        var framePreconditionSupported = true
        var explicitWindowSupported = true
        var textEditingAttributesField = "settableAttributes"
        var observationMethod = "inspect.live"
        var observationKind = "observe"
        var actionObservationSupported = true
    }

    private struct FrameOutput: Encodable {
        let actionCapabilities = LiveActionCapabilities()
        let sessionID: UUID
        let reference: String
        let frame: ReplayAccessibilityStep
    }

    func framesOutput() throws -> String {
        try jsonString(accessibilityHistory.steps.map {
            FrameOutput(sessionID: sessionID, reference: accessibilityHistory.reference(for: $0), frame: $0)
        })
    }

    func frameOutput(
        _ step: ReplayAccessibilityStep,
        changedOnly: Bool
    ) throws -> String {
        guard changedOnly else {
            return try jsonString(FrameOutput(sessionID: sessionID, reference: accessibilityHistory.reference(for: step), frame: step))
        }
        let changed = ReplayAccessibilityStep(
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
        )
        return try jsonString(FrameOutput(sessionID: sessionID, reference: accessibilityHistory.reference(for: step), frame: changed))
    }

    func readEvents(limit: Int, after: UInt64?, includeText: Bool?) throws -> String {
        // Reject invalid reads before privacy checks or starting an input observer.
        try eventLock.withLock { try eventHistory.validatePage(after: after, limit: limit) }
        try startEventObservation(includeText: includeText)
        return try eventsOutput(limit: limit, after: after)
    }

    private func eventsOutput(limit: Int, after: UInt64?) throws -> String {
        var page = try eventLock.withLock { try eventHistory.page(after: after, limit: limit) }
        page.sessionID = sessionID
        page.observing = inputRecorder != nil
        page.capturesText = capturesText
        return try jsonString(page)
    }

    func annotationsOutput() throws -> String {
        try jsonString([RecordingAnnotation]())
    }

    private func appendEvent(_ record: InputEventRecord) {
        eventLock.withLock { eventHistory.append(record) }
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


}

private func jsonString<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
