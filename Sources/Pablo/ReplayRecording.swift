import Foundation

public struct ReplayAccessibilityNode: Codable, Identifiable, Sendable {
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
        self.depth = depth
    }
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
}

public struct ReplayRecording: Codable, Sendable {
    public let packageURL: URL
    public let videoURL: URL
    public let targetName: String
    public let startedAt: String
    public let durationNs: UInt64?
    public let firstFrameTimestampNs: UInt64?
    public let accessibilitySteps: [ReplayAccessibilityStep]

    public static func load(from packageURL: URL) throws -> ReplayRecording {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            RecordingManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let accessibilityURL = packageURL.appendingPathComponent(
            manifest.files["accessibility"] ?? "accessibility.jsonl"
        )
        let videoURL = packageURL.appendingPathComponent(manifest.files["video"] ?? "video.mov")
        let records = try decodeAccessibilityRecords(at: accessibilityURL)
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
            accessibilitySteps: steps
        )
    }

    public func videoTime(for step: ReplayAccessibilityStep) -> TimeInterval {
        guard let firstFrameTimestampNs else { return TimeInterval(step.timestampNs) / 1_000_000_000 }
        guard step.timestampNs > firstFrameTimestampNs else { return 0 }
        return TimeInterval(step.timestampNs - firstFrameTimestampNs) / 1_000_000_000
    }

    private static func decodeAccessibilityRecords(at url: URL) throws -> [AXSnapshotRecord] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).enumerated().map { lineNumber, line in
            do {
                return try decoder.decode(AXSnapshotRecord.self, from: Data(line))
            } catch {
                throw ReplayRecordingError.invalidAccessibilityLine(lineNumber + 1, error)
            }
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

public enum ReplayRecordingError: LocalizedError {
    case invalidAccessibilityLine(Int, Error)

    public var errorDescription: String? {
        switch self {
        case .invalidAccessibilityLine(let line, let error):
            return "Accessibility snapshot line \(line) is invalid: \(error.localizedDescription)"
        }
    }
}
