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
            uniqueKeysWithValues: (previous?.nodes ?? []).map { ($0.id, $0) }
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
    public let targetName: String
    public let startedAt: String
    public let durationNs: UInt64?
    public let firstFrameTimestampNs: UInt64?
    public let captureWidth: Int
    public let captureHeight: Int
    public let framesPerSecond: Int
    public let accessibilitySteps: [ReplayAccessibilityStep]
    public let annotations: [RecordingAnnotation]

    public var videoAspectRatio: Double {
        guard captureWidth > 0, captureHeight > 0 else { return 16 / 10 }
        return Double(captureWidth) / Double(captureHeight)
    }

    public static func load(from packageURL: URL) throws -> ReplayRecording {
        let manifest = try RecordingManifest.load(from: packageURL)
        let accessibilityURL = packageURL.appendingPathComponent(
            manifest.files["accessibility"] ?? "accessibility.pb"
        )
        let videoURL = packageURL.appendingPathComponent(manifest.files["video"] ?? "video.mov")
        let records = try RecordingStreamReader.accessibility(at: accessibilityURL)
        let annotations = try RecordingAnnotationStore.load(from: packageURL)
        var currentNodes: [String: AXNode] = [:]
        let steps = records.enumerated().map { index, record in
            for removedID in record.removed {
                currentNodes.removeValue(forKey: removedID)
            }
            for node in record.upserts {
                currentNodes[node.id] = node
            }
            let nodes = flatten(nodes: currentNodes, rootID: record.rootID)
            let changedIDs = Set(record.upserts.map(\.id))
            return ReplayAccessibilityStep(
                id: index,
                timestampNs: record.timestampNs,
                reason: record.reason,
                kind: record.kind,
                rootID: record.rootID,
                nodes: nodes,
                changedNodes: nodes.filter { changedIDs.contains($0.id) },
                changedNodeIDs: changedIDs,
                removedNodeIDs: record.removed,
                totalNodeCount: currentNodes.count,
                truncated: record.truncated
            )
        }
        return ReplayRecording(
            packageURL: packageURL,
            videoURL: videoURL,
            targetName: manifest.target.name,
            startedAt: manifest.startedAt,
            durationNs: manifest.durationNs,
            firstFrameTimestampNs: manifest.capture.firstFrameTimestampNs,
            captureWidth: manifest.capture.width,
            captureHeight: manifest.capture.height,
            framesPerSecond: manifest.capture.framesPerSecond,
            accessibilitySteps: steps,
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
        return accessibilitySteps.last(where: { $0.timestampNs <= upperBound })
            ?? accessibilitySteps.first
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
