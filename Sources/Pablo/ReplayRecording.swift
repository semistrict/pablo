import Foundation

public struct ReplayAccessibilityFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ReplayAccessibilityNode: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let childIDs: [String]
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let help: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let frame: ReplayAccessibilityFrame?
    public let depth: Int

    init(_ node: AXNode, depth: Int) {
        id = node.id
        parentID = node.parentID
        childIDs = node.childIDs
        role = node.role
        subrole = node.subrole
        title = node.title
        label = node.label
        value = node.value
        identifier = node.identifier
        help = node.help
        enabled = node.enabled
        focused = node.focused
        if let position = node.position, let size = node.size {
            frame = ReplayAccessibilityFrame(
                x: position.x,
                y: position.y,
                width: size.width,
                height: size.height
            )
        } else {
            frame = nil
        }
        self.depth = depth
    }
}

public enum ReplayAccessibilityChangeKind: String, Codable, Sendable {
    case appeared
    case updated
    case removed
}

public struct ReplayAccessibilityChange: Identifiable, Codable, Equatable, Sendable {
    public let kind: ReplayAccessibilityChangeKind
    public let node: ReplayAccessibilityNode
    public let previousNode: ReplayAccessibilityNode?
    public let changedProperties: [String]

    public var id: String { "\(kind.rawValue):\(node.id)" }
}

public struct ReplayAccessibilityStep: Codable, Identifiable, Sendable {
    public let id: Int
    public let timestampNs: UInt64
    public let reason: String
    public let kind: String
    public let applicationID: String
    public let applicationName: String
    public let applicationBundleIdentifier: String?
    public let applicationPID: Int32
    public let rootID: String?
    public let nodes: [ReplayAccessibilityNode]
    public let changedNodes: [ReplayAccessibilityNode]
    public let changedNodeIDs: Set<String>
    public let removedNodeIDs: [String]
    public let totalNodeCount: Int
    public let truncated: Bool

    public var reference: String {
        String(format: "A11Y-%03d", id + 1)
    }

    public func changes(from previous: ReplayAccessibilityStep?) -> [ReplayAccessibilityChange] {
        let previousNodes = Dictionary(
            uniqueKeysWithValues: (previous?.applicationID == applicationID ? previous?.nodes ?? [] : []).map { ($0.id, $0) }
        )
        let currentNodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var changes: [ReplayAccessibilityChange] = []

        for node in nodes where changedNodeIDs.contains(node.id) {
            guard let previousNode = previousNodes[node.id] else {
                changes.append(ReplayAccessibilityChange(
                    kind: .appeared,
                    node: node,
                    previousNode: nil,
                    changedProperties: []
                ))
                continue
            }
            let properties = Self.changedProperties(from: previousNode, to: node)
            if !properties.isEmpty {
                changes.append(ReplayAccessibilityChange(
                    kind: .updated,
                    node: node,
                    previousNode: previousNode,
                    changedProperties: properties
                ))
            }
        }

        let removedIDs = Set(removedNodeIDs).union(previousNodes.keys.filter { currentNodes[$0] == nil })
        for node in previous?.nodes ?? [] where removedIDs.contains(node.id) {
            changes.append(ReplayAccessibilityChange(
                kind: .removed,
                node: node,
                previousNode: node,
                changedProperties: []
            ))
        }
        return changes
    }

    private static func changedProperties(
        from previous: ReplayAccessibilityNode,
        to current: ReplayAccessibilityNode
    ) -> [String] {
        var properties: [String] = []
        if previous.parentID != current.parentID { properties.append("parent") }
        if previous.childIDs != current.childIDs { properties.append("children") }
        if previous.role != current.role { properties.append("role") }
        if previous.subrole != current.subrole { properties.append("subrole") }
        if previous.title != current.title { properties.append("title") }
        if previous.label != current.label { properties.append("label") }
        if previous.value != current.value { properties.append("value") }
        if previous.identifier != current.identifier { properties.append("identifier") }
        if previous.help != current.help { properties.append("help") }
        if previous.enabled != current.enabled { properties.append("enabled") }
        if previous.focused != current.focused { properties.append("focused") }
        if previous.frame != current.frame { properties.append("frame") }
        return properties
    }
}

public struct ReplayRecording: Codable, Sendable {
    public let packageURL: URL
    public let videoURL: URL
    public let scopeName: String
    public let scope: RecordingScopeKind
    public let selectedApplicationID: String?
    public let selectedDisplayID: UInt32?
    public let captureFrame: RecordingRect
    public let startedAt: String
    public let durationNs: UInt64?
    public let firstFrameTimestampNs: UInt64?
    public let captureWidth: Int
    public let captureHeight: Int
    public let framesPerSecond: Int
    public let inputEvents: [InputEventRecord]
    public let accessibilitySteps: [ReplayAccessibilityStep]
    public let workspaceSteps: [WorkspaceSnapshotRecord]
    public let annotations: [RecordingAnnotation]

    public var videoAspectRatio: Double {
        guard captureWidth > 0, captureHeight > 0 else { return 16 / 10 }
        return Double(captureWidth) / Double(captureHeight)
    }

    public static func load(from packageURL: URL) throws -> ReplayRecording {
        let manifest = try RecordingManifest.load(from: packageURL)
        let accessibilityURL = try manifest.fileURL(for: "accessibility", in: packageURL)
        let eventsURL = try manifest.fileURL(for: "events", in: packageURL)
        let videoURL = try manifest.fileURL(for: "video", in: packageURL)
        let workspaceURL = try manifest.fileURL(for: "workspace", in: packageURL)
        let records = try RecordingStreamReader.accessibility(at: accessibilityURL)
        let inputEvents = try RecordingStreamReader.events(at: eventsURL)
        let workspaceSteps = try RecordingStreamReader.workspace(at: workspaceURL)
        let annotations = try RecordingAnnotationStore.load(from: packageURL)
        var currentNodesByApplication: [String: [String: AXNode]] = [:]
        let steps = records.enumerated().map { index, record in
            var currentNodes = currentNodesByApplication[record.application.id] ?? [:]
            for removedID in record.removed {
                currentNodes.removeValue(forKey: removedID)
            }
            for node in record.upserts {
                currentNodes[node.id] = node
            }
            currentNodesByApplication[record.application.id] = currentNodes
            let nodes = flatten(nodes: currentNodes, rootID: record.rootID)
            let changedIDs = Set(record.upserts.map(\.id))
            return ReplayAccessibilityStep(
                id: index,
                timestampNs: record.timestampNs,
                reason: record.reason,
                kind: record.kind,
                applicationID: record.application.id,
                applicationName: record.application.name,
                applicationBundleIdentifier: record.application.bundleIdentifier,
                applicationPID: record.application.pid,
                rootID: record.rootID,
                nodes: nodes,
                changedNodes: nodes.filter { changedIDs.contains($0.id) },
                changedNodeIDs: changedIDs,
                removedNodeIDs: record.removed,
                totalNodeCount: currentNodes.count,
                truncated: record.truncated
            )
        }
        let selectedName = manifest.scope.selectedApplicationID.flatMap { selectedID in
            manifest.applications.first(where: { $0.id == selectedID })?.name
        }
        return ReplayRecording(
            packageURL: packageURL,
            videoURL: videoURL,
            scopeName: selectedName ?? manifest.scope.selectedDisplayID.map { "Display \($0)" } ?? "Entire Screen",
            scope: manifest.scope.kind,
            selectedApplicationID: manifest.scope.selectedApplicationID,
            selectedDisplayID: manifest.scope.selectedDisplayID,
            captureFrame: manifest.capture.frame,
            startedAt: manifest.startedAt,
            durationNs: manifest.durationNs,
            firstFrameTimestampNs: manifest.capture.firstFrameTimestampNs,
            captureWidth: manifest.capture.width,
            captureHeight: manifest.capture.height,
            framesPerSecond: manifest.capture.framesPerSecond,
            inputEvents: inputEvents,
            accessibilitySteps: steps,
            workspaceSteps: workspaceSteps,
            annotations: annotations
        )
    }

    public func videoTime(for step: ReplayAccessibilityStep) -> TimeInterval {
        videoTime(forTimestampNs: step.timestampNs)
    }

    public func videoTime(forTimestampNs timestampNs: UInt64) -> TimeInterval {
        guard let firstFrameTimestampNs else { return TimeInterval(timestampNs) / 1_000_000_000 }
        guard timestampNs > firstFrameTimestampNs else { return 0 }
        return TimeInterval(timestampNs - firstFrameTimestampNs) / 1_000_000_000
    }

    public func sessionTimestampNs(forVideoTime seconds: TimeInterval) -> UInt64 {
        let videoNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        return (firstFrameTimestampNs ?? 0) + videoNanoseconds
    }

    public func accessibilityStep(atVideoTime seconds: TimeInterval) -> ReplayAccessibilityStep? {
        guard !accessibilitySteps.isEmpty else { return nil }
        let timestamp = sessionTimestampNs(forVideoTime: seconds)
        // Converting an integer timestamp to seconds and back can round down by a
        // handful of nanoseconds. Keep exact evidence-marker seeks on that marker.
        let boundaryTimestamp = timestamp.addingReportingOverflow(1_000)
        let upperBound = boundaryTimestamp.overflow ? UInt64.max : boundaryTimestamp.partialValue
        let frontmostID = workspaceStep(atVideoTime: seconds)?.frontmostApplicationID
        return accessibilitySteps.last(where: {
            $0.timestampNs <= upperBound && (frontmostID == nil || $0.applicationID == frontmostID)
        }) ?? accessibilitySteps.last(where: { $0.timestampNs <= upperBound })
            ?? accessibilitySteps.first
    }

    public func accessibilitySteps(atVideoTime seconds: TimeInterval) -> [ReplayAccessibilityStep] {
        let timestamp = sessionTimestampNs(forVideoTime: seconds)
        var latestByApplication: [String: ReplayAccessibilityStep] = [:]
        for step in accessibilitySteps where step.timestampNs <= timestamp {
            latestByApplication[step.applicationID] = step
        }
        return latestByApplication.values.sorted { $0.applicationName < $1.applicationName }
    }

    public func workspaceStep(atVideoTime seconds: TimeInterval) -> WorkspaceSnapshotRecord? {
        let timestamp = sessionTimestampNs(forVideoTime: seconds)
        return workspaceSteps.last(where: { $0.timestampNs <= timestamp }) ?? workspaceSteps.first
    }

    public func applicationID(
        atNormalizedX x: Double,
        y: Double,
        timestampNs: UInt64
    ) -> String? {
        let videoTime = videoTime(forTimestampNs: timestampNs)
        guard let workspace = workspaceStep(atVideoTime: videoTime) else { return nil }
        let globalPoint = RecordingPoint(
            x: captureFrame.x + x * captureFrame.width,
            y: captureFrame.y + y * captureFrame.height
        )
        return workspace.windows
            .filter { window in
                let frame = window.frame
                return globalPoint.x >= frame.x && globalPoint.x <= frame.x + frame.width &&
                    globalPoint.y >= frame.y && globalPoint.y <= frame.y + frame.height
            }
            .min(by: { $0.zOrder < $1.zOrder })?.applicationID
            ?? workspace.frontmostApplicationID
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
            for childID in node.childIDs {
                visit(childID, depth: depth + 1)
            }
        }

        if let rootID {
            visit(rootID, depth: 0)
        }
        for id in nodes.keys.sorted() where !visited.contains(id) {
            visit(id, depth: 0)
        }
        return result
    }
}

public enum ReplayTimelineLane: String, CaseIterable, Codable, Sendable {
    case workspace
    case input
    case automation
    case accessibility
    case annotation
}

public enum ReplayTimelineImportance: Int, Codable, Comparable, Sendable {
    case technical
    case meaningful
    case warning

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ReplayTimelineReference: Hashable, Codable, Sendable {
    case workspace(Int)
    case input(Int)
    case automation(UUID)
    case accessibility(Int)
    case annotation(UUID)
}

public struct ReplayTimelineItem: Identifiable, Codable, Sendable {
    public let id: String
    public let lane: ReplayTimelineLane
    public let timestampNs: UInt64
    public let endTimestampNs: UInt64
    public let title: String
    public let subtitle: String?
    public let applicationIDs: [String]
    public let importance: ReplayTimelineImportance
    public let references: [ReplayTimelineReference]

    public var memberCount: Int { references.count }
}

public struct ReplayTimelineCluster: Identifiable, Sendable {
    public let lane: ReplayTimelineLane
    public let items: [ReplayTimelineItem]

    public var id: String { "\(lane.rawValue):\(items.map(\.id).joined(separator: ","))" }
    public var timestampNs: UInt64 { items.map(\.timestampNs).min() ?? 0 }
    public var endTimestampNs: UInt64 { items.map(\.endTimestampNs).max() ?? timestampNs }
    public var importance: ReplayTimelineImportance { items.map(\.importance).max() ?? .technical }
    public var memberCount: Int { items.count }
}

public extension ReplayRecording {
    func timelineItems(annotations currentAnnotations: [RecordingAnnotation]? = nil) -> [ReplayTimelineItem] {
        var items = workspaceTimelineItems()
        items.append(contentsOf: inputTimelineItems())
        items.append(contentsOf: automationTimelineItems())

        var previousStepByApplication: [String: ReplayAccessibilityStep] = [:]
        for step in accessibilitySteps {
            let previous = previousStepByApplication[step.applicationID]
            let changes = step.changes(from: previous)
            let semanticCount = previous == nil ? 0 : changes.filter(replayAccessibilityChangeIsSemantic).count
            previousStepByApplication[step.applicationID] = step
            let importance: ReplayTimelineImportance = step.truncated
                ? .warning
                : (previous == nil || semanticCount == 0 ? .technical : .meaningful)
            items.append(ReplayTimelineItem(
                id: "accessibility:\(step.id)",
                lane: .accessibility,
                timestampNs: step.timestampNs,
                endTimestampNs: step.timestampNs,
                title: previous == nil
                    ? "Accessibility baseline"
                    : (semanticCount > 0 ? "\(semanticCount) meaningful changes" : step.reference),
                subtitle: "\(step.applicationName) · \(step.reason.replacingOccurrences(of: "input:", with: ""))",
                applicationIDs: [step.applicationID],
                importance: importance,
                references: [.accessibility(step.id)]
            ))
        }

        for annotation in currentAnnotations ?? annotations {
            guard let start = annotation.startTimestampNs ?? annotation.trace?.startTimestampNs else { continue }
            let end = annotation.endTimestampNs ?? annotation.trace?.endTimestampNs ?? start
            items.append(ReplayTimelineItem(
                id: "annotation:\(annotation.id.uuidString)",
                lane: .annotation,
                timestampNs: start,
                endTimestampNs: end,
                title: annotation.text,
                subtitle: annotation.reference,
                applicationIDs: annotation.applicationIDs,
                importance: .meaningful,
                references: [.annotation(annotation.id)]
            ))
        }

        return items.sorted {
            $0.timestampNs == $1.timestampNs ? $0.lane.rawValue < $1.lane.rawValue : $0.timestampNs < $1.timestampNs
        }
    }

    func meaningfulTimelineItems(annotations: [RecordingAnnotation]? = nil) -> [ReplayTimelineItem] {
        timelineItems(annotations: annotations).filter { $0.importance >= .meaningful }
    }

    func timelineClusters(
        from items: [ReplayTimelineItem],
        lane: ReplayTimelineLane,
        visibleTimestampRange: ClosedRange<UInt64>,
        trackWidth: Double,
        minimumSpacing: Double = 10
    ) -> [ReplayTimelineCluster] {
        let candidates = items.filter {
            $0.lane == lane &&
                $0.endTimestampNs >= visibleTimestampRange.lowerBound &&
                $0.timestampNs <= visibleTimestampRange.upperBound
        }
        guard !candidates.isEmpty else { return [] }
        let duration = max(1, visibleTimestampRange.upperBound - visibleTimestampRange.lowerBound)
        let binCount = max(1, Int(trackWidth / max(minimumSpacing, 1)))
        let grouped: [Int: [ReplayTimelineItem]] = Dictionary(grouping: candidates) { item -> Int in
            let visibleTimestamp = max(item.timestampNs, visibleTimestampRange.lowerBound)
            let offset = Double(visibleTimestamp - visibleTimestampRange.lowerBound)
            let progress = offset / Double(duration)
            let proposedBin = Int(progress * Double(binCount))
            return Swift.min(binCount - 1, proposedBin)
        }
        return grouped.sorted(by: { $0.key < $1.key }).map { _, bucket in
            let ordered = bucket.sorted {
                $0.timestampNs == $1.timestampNs ? $0.id < $1.id : $0.timestampNs < $1.timestampNs
            }
            return ReplayTimelineCluster(lane: lane, items: ordered)
        }
    }

    func timelineClusters(
        lane: ReplayTimelineLane,
        visibleTimestampRange: ClosedRange<UInt64>,
        trackWidth: Double,
        minimumSpacing: Double = 10,
        annotations: [RecordingAnnotation]? = nil
    ) -> [ReplayTimelineCluster] {
        timelineClusters(
            from: timelineItems(annotations: annotations),
            lane: lane,
            visibleTimestampRange: visibleTimestampRange,
            trackWidth: trackWidth,
            minimumSpacing: minimumSpacing
        )
    }

    private func workspaceTimelineItems() -> [ReplayTimelineItem] {
        workspaceSteps.enumerated().compactMap { index, step in
            guard index > 0 else {
                return ReplayTimelineItem(
                    id: "workspace:0",
                    lane: .workspace,
                    timestampNs: step.timestampNs,
                    endTimestampNs: step.timestampNs,
                    title: "Workspace baseline",
                    subtitle: "\(step.applications.count) apps · \(step.windows.count) windows",
                    applicationIDs: step.frontmostApplicationID.map { [$0] } ?? [],
                    importance: .technical,
                    references: [.workspace(index)]
                )
            }

            let previous = workspaceSteps[index - 1]
            let frontmostChanged = previous.frontmostApplicationID != step.frontmostApplicationID
            let previousWindows = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0) })
            let currentWindows = Dictionary(uniqueKeysWithValues: step.windows.map { ($0.id, $0) })
            let changedWindows = currentWindows.values.filter { current in
                guard let prior = previousWindows[current.id] else { return false }
                return replayWindowChangedMeaningfully(from: prior, to: current)
            }
            let lifecycleCount = step.appearedApplicationIDs.count + step.removedApplicationIDs.count +
                step.appearedWindowIDs.count + step.removedWindowIDs.count
            guard frontmostChanged || lifecycleCount > 0 || !changedWindows.isEmpty else { return nil }

            var applicationIDs = Set(step.appearedApplicationIDs + step.removedApplicationIDs)
            if let frontmost = step.frontmostApplicationID { applicationIDs.insert(frontmost) }
            for windowID in step.appearedWindowIDs + step.removedWindowIDs {
                if let applicationID = (currentWindows[windowID] ?? previousWindows[windowID])?.applicationID {
                    applicationIDs.insert(applicationID)
                }
            }
            for window in changedWindows { applicationIDs.insert(window.applicationID) }

            var details: [String] = []
            let applicationChanges = step.appearedApplicationIDs.count + step.removedApplicationIDs.count
            let windowChanges = step.appearedWindowIDs.count + step.removedWindowIDs.count + changedWindows.count
            if applicationChanges > 0 { details.append("\(applicationChanges) app changes") }
            if windowChanges > 0 { details.append("\(windowChanges) window changes") }

            let frontmostName = step.frontmostApplicationID.flatMap {
                applicationName(for: $0, in: step) ?? applicationName(for: $0, in: previous)
            }
            let title: String
            if frontmostChanged {
                title = frontmostName.map { "Switched to \($0)" } ?? "Frontmost app changed"
            } else if changedWindows.count == 1, let window = changedWindows.first,
                      let windowTitle = window.title, !windowTitle.isEmpty {
                title = "\u{201c}\(windowTitle)\u{201d} changed"
            } else {
                title = "Workspace changed"
            }
            return ReplayTimelineItem(
                id: "workspace:\(index)",
                lane: .workspace,
                timestampNs: step.timestampNs,
                endTimestampNs: step.timestampNs,
                title: title,
                subtitle: details.isEmpty ? step.reason : details.joined(separator: " · "),
                applicationIDs: applicationIDs.sorted(),
                importance: .meaningful,
                references: [.workspace(index)]
            )
        }
    }

    private func inputTimelineItems() -> [ReplayTimelineItem] {
        var builder = ReplayInputTimelineBuilder(events: inputEvents)
        return builder.build()
    }

    private func automationTimelineItems() -> [ReplayTimelineItem] {
        let indexed = inputEvents.enumerated().compactMap { index, event -> (Int, InputEventRecord, PabloAutomationActionTrace)? in
            guard let action = event.automationAction else { return nil }
            return (index, event, action)
        }
        return Dictionary(grouping: indexed, by: { $0.2.actionID }).map { actionID, records in
            let ordered = records.sorted {
                $0.1.timestampNs == $1.1.timestampNs ? $0.0 < $1.0 : $0.1.timestampNs < $1.1.timestampNs
            }
            let requested = ordered.first { $0.2.phase == .requested }
            let outcome = ordered.last { $0.2.phase == .succeeded || $0.2.phase == .failed }
            let representative = requested ?? ordered[0]
            let finalPhase = outcome?.2.phase
            let complete = requested != nil && outcome != nil
            let importance: ReplayTimelineImportance = !complete || finalPhase == .failed ? .warning : .meaningful
            let phaseName = finalPhase?.rawValue ?? "requested"
            var subtitle = [representative.2.caller.displayName]
            if let developer = representative.2.caller.developerName, !developer.isEmpty {
                subtitle.append(developer)
            }
            if !representative.2.transport.isEmpty { subtitle.append(representative.2.transport) }
            if representative.2.recordingWasPaused { subtitle.append("while paused") }
            var applicationIDs = Set(ordered.compactMap { $0.1.applicationID })
            applicationIDs.formUnion(ordered.compactMap { $0.2.resolvedApplicationID })
            return ReplayTimelineItem(
                id: "automation:\(actionID.uuidString)",
                lane: .automation,
                timestampNs: ordered[0].1.timestampNs,
                endTimestampNs: ordered.last?.1.timestampNs ?? ordered[0].1.timestampNs,
                title: "\(automationActionName(representative.2.kind)) \(phaseName)",
                subtitle: subtitle.joined(separator: " · "),
                applicationIDs: applicationIDs.sorted(),
                importance: importance,
                references: [.automation(actionID)]
            )
        }
        .sorted {
            $0.timestampNs == $1.timestampNs ? $0.id < $1.id : $0.timestampNs < $1.timestampNs
        }
    }

    private func applicationName(for id: String, in workspace: WorkspaceSnapshotRecord) -> String? {
        workspace.applications.first(where: { $0.id == id })?.name
    }
}

public func replayAccessibilityChangeIsSemantic(_ change: ReplayAccessibilityChange) -> Bool {
    if change.changedProperties.contains(where: {
        ["focused", "enabled", "value", "title", "label", "help", "identifier", "role", "subrole"]
            .contains($0)
    }) {
        return true
    }
    guard change.kind != .updated else { return false }
    let name = replayAccessibilityNodeName(change.node)
    let role = replayAccessibilityRoleName(change.node.role)
    return name != role || change.node.focused == true || change.node.enabled == false
}

private func replayAccessibilityNodeName(_ node: ReplayAccessibilityNode) -> String {
    for value in [node.title, node.label, node.value, node.identifier] {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
    }
    return replayAccessibilityRoleName(node.role)
}

private func replayAccessibilityRoleName(_ role: String?) -> String {
    guard var value = role, !value.isEmpty else { return "Unknown element" }
    if value.hasPrefix("AX") { value.removeFirst(2) }
    return value
}

private func inputEventName(_ type: String) -> String {
    switch type {
    case "mouseDown", "rightMouseDown", "otherMouseDown": return "Pointer down"
    case "mouseUp", "rightMouseUp", "otherMouseUp": return "Pointer up"
    case "mouseDrag": return "Drag"
    case "mouseMove": return "Pointer movement"
    case "scroll": return "Scroll"
    case "keyDown": return "Key down"
    case "keyUp": return "Key up"
    default: return type
    }
}

private func automationActionName(_ kind: PabloLiveActionKind) -> String {
    kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
}

private func replayWindowChangedMeaningfully(
    from previous: RecordingWindow,
    to current: RecordingWindow
) -> Bool {
    previous.title != current.title ||
        previous.frame != current.frame ||
        previous.isOnScreen != current.isOnScreen
}

private struct ReplayInputTimelineBuilder {
    private struct IndexedEvent {
        let index: Int
        let event: InputEventRecord
    }

    private struct TargetIdentity: Equatable {
        let applicationID: String?
        let windowID: String?
        let targetPID: Int64?
    }

    private enum PointerPhase {
        case down
        case up
        case drag
        case move
        case none
    }

    private enum ScrollDirection: String {
        case up
        case down
        case left
        case right
        case stationary
    }

    private let events: [IndexedEvent]
    private var consumed = Set<Int>()

    init(events: [InputEventRecord]) {
        self.events = events.enumerated()
            .filter { $0.element.automationAction == nil }
            .map { IndexedEvent(index: $0.offset, event: $0.element) }
            .sorted {
                $0.event.timestampNs == $1.event.timestampNs
                    ? $0.index < $1.index
                    : $0.event.timestampNs < $1.event.timestampNs
            }
    }

    mutating func build() -> [ReplayTimelineItem] {
        var items: [ReplayTimelineItem] = []
        for position in events.indices where !consumed.contains(events[position].index) {
            let indexed = events[position]
            let item: ReplayTimelineItem
            switch pointerPhase(indexed.event) {
            case .down:
                item = pointerSequence(startingAt: position)
            case .up:
                consumed.insert(indexed.index)
                item = makeItem(
                    members: [indexed],
                    title: clickTitle(for: indexed.event),
                    importance: .meaningful
                )
            case .drag:
                item = pointerBurst(startingAt: position, phase: .drag)
            case .move:
                item = pointerBurst(startingAt: position, phase: .move)
            case .none:
                if indexed.event.type == "scroll" {
                    item = scrollBurst(startingAt: position)
                } else if indexed.event.type == "keyDown", isPrintable(indexed.event.text) {
                    item = typingBurst(startingAt: position)
                } else {
                    consumed.insert(indexed.index)
                    item = makeItem(
                        members: [indexed],
                        title: inputEventName(indexed.event.type),
                        subtitle: keySubtitle(for: indexed.event),
                        importance: inputImportance(indexed.event)
                    )
                }
            }
            items.append(item)
        }
        return items.sorted {
            $0.timestampNs == $1.timestampNs ? $0.id < $1.id : $0.timestampNs < $1.timestampNs
        }
    }

    private mutating func pointerSequence(startingAt position: Int) -> ReplayTimelineItem {
        let start = events[position]
        let identity = targetIdentity(start.event)
        let button = pointerButton(start.event)
        var members = [start]
        var foundUp = false
        var sawDrag = false

        for candidatePosition in events.indices.dropFirst(position + 1) {
            let candidate = events[candidatePosition]
            guard candidate.event.timestampNs - start.event.timestampNs <= 500_000_000 else { break }
            let phase = pointerPhase(candidate.event)
            if phase == .down, targetIdentity(candidate.event) == identity,
               pointerButton(candidate.event) == button {
                break
            }
            guard targetIdentity(candidate.event) == identity else {
                if phase != .none { break }
                continue
            }
            switch phase {
            case .move:
                members.append(candidate)
            case .drag where pointerButton(candidate.event) == button:
                members.append(candidate)
                sawDrag = true
            case .up where pointerButton(candidate.event) == button:
                members.append(candidate)
                foundUp = true
            default:
                continue
            }
            if foundUp { break }
        }

        for member in members { consumed.insert(member.index) }
        guard foundUp else {
            return makeItem(members: members, title: "Pointer down", importance: .meaningful)
        }
        let moved = pointerMoved(from: members.first?.event, to: members.last?.event)
        return makeItem(
            members: members,
            title: sawDrag || moved ? "Drag" : clickTitle(for: members.last?.event ?? start.event),
            importance: .meaningful
        )
    }

    private mutating func pointerBurst(
        startingAt position: Int,
        phase: PointerPhase
    ) -> ReplayTimelineItem {
        let start = events[position]
        let identity = targetIdentity(start.event)
        let button = pointerButton(start.event)
        var members = [start]
        var previousTimestamp = start.event.timestampNs
        for candidate in events.dropFirst(position + 1) {
            guard pointerPhase(candidate.event) == phase,
                  targetIdentity(candidate.event) == identity,
                  (phase == .move || pointerButton(candidate.event) == button),
                  candidate.event.timestampNs - previousTimestamp <= 100_000_000 else { break }
            members.append(candidate)
            previousTimestamp = candidate.event.timestampNs
        }
        for member in members { consumed.insert(member.index) }
        return makeItem(
            members: members,
            title: phase == .drag ? "Drag" : "Pointer movement",
            subtitle: members.count > 1 ? "\(members.count) samples" : nil,
            importance: phase == .drag ? .meaningful : .technical
        )
    }

    private mutating func scrollBurst(startingAt position: Int) -> ReplayTimelineItem {
        let start = events[position]
        let identity = targetIdentity(start.event)
        let direction = scrollDirection(start.event)
        var members = [start]
        var previousTimestamp = start.event.timestampNs
        for candidate in events.dropFirst(position + 1) {
            guard candidate.event.type == "scroll",
                  targetIdentity(candidate.event) == identity,
                  scrollDirection(candidate.event) == direction,
                  candidate.event.timestampNs - previousTimestamp <= 250_000_000 else { break }
            members.append(candidate)
            previousTimestamp = candidate.event.timestampNs
        }
        for member in members { consumed.insert(member.index) }
        let deltaX = members.reduce(0) { $0 + ($1.event.deltaX ?? 0) }
        let deltaY = members.reduce(0) { $0 + ($1.event.deltaY ?? 0) }
        let subtitle = String(format: "%d events · Δx %.0f · Δy %.0f", members.count, deltaX, deltaY)
        return makeItem(
            members: members,
            title: direction == .stationary ? "Scroll" : "Scroll \(direction.rawValue)",
            subtitle: subtitle,
            importance: .meaningful
        )
    }

    private mutating func typingBurst(startingAt position: Int) -> ReplayTimelineItem {
        let start = events[position]
        let identity = targetIdentity(start.event)
        var members = [start]
        var previousTimestamp = start.event.timestampNs
        for candidate in events.dropFirst(position + 1) {
            let event = candidate.event
            guard event.timestampNs - previousTimestamp <= 750_000_000 else { break }
            if event.type == "keyUp" || event.type == "flagsChanged" { continue }
            guard event.type == "keyDown",
                  isPrintable(event.text),
                  targetIdentity(event) == identity else { break }
            members.append(candidate)
            previousTimestamp = event.timestampNs
        }
        for member in members { consumed.insert(member.index) }
        let characterCount = members.reduce(0) { $0 + ($1.event.text?.count ?? 0) }
        return makeItem(
            members: members,
            title: "Typed \(characterCount) \(characterCount == 1 ? "character" : "characters")",
            subtitle: members.count > 1 ? "\(members.count) key presses" : nil,
            importance: .meaningful
        )
    }

    private func makeItem(
        members: [IndexedEvent],
        title: String,
        subtitle: String? = nil,
        importance: ReplayTimelineImportance
    ) -> ReplayTimelineItem {
        let ordered = members.sorted {
            $0.event.timestampNs == $1.event.timestampNs
                ? $0.index < $1.index
                : $0.event.timestampNs < $1.event.timestampNs
        }
        let indices = ordered.map(\.index)
        let firstIndex = indices.first ?? 0
        let lastIndex = indices.last ?? firstIndex
        let applicationIDs = Set(ordered.compactMap { $0.event.applicationID }).sorted()
        return ReplayTimelineItem(
            id: firstIndex == lastIndex ? "input:\(firstIndex)" : "input:\(firstIndex)-\(lastIndex)",
            lane: .input,
            timestampNs: ordered.first?.event.timestampNs ?? 0,
            endTimestampNs: ordered.last?.event.timestampNs ?? 0,
            title: title,
            subtitle: subtitle,
            applicationIDs: applicationIDs,
            importance: importance,
            references: indices.map(ReplayTimelineReference.input)
        )
    }

    private func pointerPhase(_ event: InputEventRecord) -> PointerPhase {
        switch event.type {
        case "mouseDown", "rightMouseDown", "otherMouseDown": .down
        case "mouseUp", "rightMouseUp", "otherMouseUp": .up
        case "mouseDrag": .drag
        case "mouseMove": .move
        default: .none
        }
    }

    private func pointerButton(_ event: InputEventRecord) -> Int64 {
        if let button = event.button { return button }
        switch event.type {
        case "rightMouseDown", "rightMouseUp": return 1
        case "otherMouseDown", "otherMouseUp": return 2
        default: return 0
        }
    }

    private func pointerMoved(from start: InputEventRecord?, to end: InputEventRecord?) -> Bool {
        guard let startX = start?.x, let startY = start?.y,
              let endX = end?.x, let endY = end?.y else { return false }
        let deltaX = endX - startX
        let deltaY = endY - startY
        return deltaX * deltaX + deltaY * deltaY > 36
    }

    private func clickTitle(for event: InputEventRecord) -> String {
        (event.clickCount ?? 1) > 1 ? "Double click" : "Click"
    }

    private func targetIdentity(_ event: InputEventRecord) -> TargetIdentity {
        TargetIdentity(
            applicationID: event.applicationID,
            windowID: event.windowID,
            targetPID: event.targetPID
        )
    }

    private func scrollDirection(_ event: InputEventRecord) -> ScrollDirection {
        let deltaX = event.deltaX ?? 0
        let deltaY = event.deltaY ?? 0
        if abs(deltaY) >= abs(deltaX), deltaY != 0 { return deltaY > 0 ? .up : .down }
        if deltaX != 0 { return deltaX > 0 ? .right : .left }
        return .stationary
    }

    private func isPrintable(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
    }

    private func keySubtitle(for event: InputEventRecord) -> String? {
        guard let keyCode = event.keyCode else { return nil }
        return "Key code \(keyCode)"
    }

    private func inputImportance(_ event: InputEventRecord) -> ReplayTimelineImportance {
        switch event.type {
        case "keyUp", "flagsChanged", "mouseMove": .technical
        default: .meaningful
        }
    }
}
