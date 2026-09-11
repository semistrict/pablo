import Foundation

/// A caller-owned baseline makes concurrent readers independent of one another.
public struct PabloLiveObservationOptions: Codable, Equatable, Sendable {
    public var baselineReference: String?
    public var full: Bool
    public var screenshot: Bool
    public var quietMilliseconds: Int
    public var timeoutMilliseconds: Int

    public init(baselineReference: String? = nil, full: Bool = false, screenshot: Bool = false,
                quietMilliseconds: Int = 150, timeoutMilliseconds: Int = 2_000) {
        self.baselineReference = baselineReference
        self.full = full
        self.screenshot = screenshot
        self.quietMilliseconds = quietMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func validate() throws {
        guard baselineReference.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              (0...1_000).contains(quietMilliseconds),
              (0...5_000).contains(timeoutMilliseconds),
              quietMilliseconds <= timeoutMilliseconds else {
            throw RecordingError.usage("Observation requires a bounded frame reference and a quiet interval of 0–1000 ms within a timeout of 0–5000 ms.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case baselineReference, full, screenshot, quietMilliseconds, timeoutMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(baselineReference: try values.decodeIfPresent(String.self, forKey: .baselineReference),
                  full: try values.decodeIfPresent(Bool.self, forKey: .full) ?? false,
                  screenshot: try values.decodeIfPresent(Bool.self, forKey: .screenshot) ?? false,
                  quietMilliseconds: try values.decodeIfPresent(Int.self, forKey: .quietMilliseconds) ?? 150,
                  timeoutMilliseconds: try values.decodeIfPresent(Int.self, forKey: .timeoutMilliseconds) ?? 2_000)
    }
}

public struct PabloLiveTreeChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, updated, removed }
    public let kind: Kind
    public let nodeID: String
    /// Complete replacement of this node. Nil only for removal.
    public let node: ReplayAccessibilityNode?
    public let changedProperties: [String]
}

public struct PabloLiveTreeObservation: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case full, delta }
    public let sessionID: UUID
    public let reference: String
    public let baselineReference: String?
    public let mode: Mode
    public let resyncRequired: Bool
    public let rootID: String?
    public let timestampNs: UInt64
    public let totalNodeCount: Int
    public let truncated: Bool
    /// Present only in full mode. Delta consumers apply changes to their own baseline.
    public let nodes: [ReplayAccessibilityNode]
    public let changes: [PabloLiveTreeChange]
    public let text: String
    public let textTruncated: Bool

    init(sessionID: UUID, current: ReplayAccessibilityStep, reference: String,
         baseline: ReplayAccessibilityStep?, baselineReference: String?, resyncRequired: Bool) {
        self.sessionID = sessionID
        self.reference = reference
        self.baselineReference = baseline == nil ? nil : baselineReference
        self.mode = baseline == nil ? .full : .delta
        self.resyncRequired = resyncRequired
        self.rootID = current.rootID
        self.timestampNs = current.timestampNs
        self.totalNodeCount = current.totalNodeCount
        self.truncated = current.truncated
        self.nodes = baseline == nil ? current.nodes : []

        if let baseline {
            let previous = Dictionary(uniqueKeysWithValues: baseline.nodes.map { ($0.id, $0) })
            let currentIDs = Set(current.nodes.map(\.id))
            var changes: [PabloLiveTreeChange] = []
            for node in current.nodes where previous[node.id] != node {
                let old = previous[node.id]
                changes.append(.init(kind: old == nil ? .added : .updated, nodeID: node.id,
                                     node: node, changedProperties: old.map { Self.properties(from: $0, to: node) } ?? []))
            }
            changes += baseline.nodes.filter { !currentIDs.contains($0.id) }.map {
                .init(kind: .removed, nodeID: $0.id, node: nil, changedProperties: [])
            }
            self.changes = changes
        } else {
            self.changes = []
        }
        let rendered = LiveTreeText.render(nodes: self.nodes, changes: self.changes, full: baseline == nil)
        self.text = rendered.text
        self.textTruncated = rendered.truncated
    }

    private static func properties(from old: ReplayAccessibilityNode, to new: ReplayAccessibilityNode) -> [String] {
        var fields: [String] = []
        if old.parentID != new.parentID { fields.append("parentID") }
        if old.childIDs != new.childIDs { fields.append("childIDs") }
        if old.depth != new.depth { fields.append("depth") }
        if old.role != new.role { fields.append("role") }
        if old.subrole != new.subrole { fields.append("subrole") }
        if old.title != new.title { fields.append("title") }
        if old.label != new.label { fields.append("label") }
        if old.value != new.value { fields.append("value") }
        if old.identifier != new.identifier { fields.append("identifier") }
        if old.help != new.help { fields.append("help") }
        if old.enabled != new.enabled { fields.append("enabled") }
        if old.focused != new.focused { fields.append("focused") }
        if old.frame != new.frame { fields.append("frame") }
        if old.actions != new.actions { fields.append("actions") }
        if old.settableAttributes != new.settableAttributes { fields.append("settableAttributes") }
        if old.selectedTextRange != new.selectedTextRange { fields.append("selectedTextRange") }
        return fields
    }
}

private enum LiveTreeText {
    static func render(nodes: [ReplayAccessibilityNode], changes: [PabloLiveTreeChange], full: Bool) -> (text: String, truncated: Bool) {
        var lines: [String] = []
        var bytes = 0
        var truncated = false
        func quoted(_ value: String) -> String {
            let shortened = String(value.prefix(256))
            if shortened != value { truncated = true }
            // All application-controlled strings remain quoted, including embedded newlines.
            return String(decoding: (try? JSONEncoder().encode(shortened)) ?? Data(), as: UTF8.self)
        }
        func append(_ prefix: String, id: String, node: ReplayAccessibilityNode?, properties: [String] = []) {
            var line = prefix + String(repeating: "  ", count: min(max(node?.depth ?? 0, 0), 30)) + " " + quoted(id)
            if let node {
                line += " " + quoted(node.role ?? "unknown")
                for (name, value) in [("title", node.title), ("label", node.label), ("value", node.value)] {
                    if let value, !value.isEmpty { line += " \(name)=" + quoted(value) }
                }
                if node.enabled == false { line += " disabled" }
                if node.focused == true { line += " focused" }
                if let actions = node.actions, !actions.isEmpty { line += " actions=[" + actions.map(quoted).joined(separator: ",") + "]" }
                if let attributes = node.settableAttributes, !attributes.isEmpty { line += " editable=[" + attributes.map(quoted).joined(separator: ",") + "]" }
                if let range = node.selectedTextRange { line += " selection=\(range.location):\(range.length)" }
                if !properties.isEmpty { line += " changed=" + properties.joined(separator: ",") }
            }
            if bytes + line.utf8.count + 1 <= 64 * 1_024 {
                lines.append(line)
                bytes += line.utf8.count + 1
            } else { truncated = true }
        }
        if full {
            for node in nodes { append("=", id: node.id, node: node) }
        } else {
            for change in changes {
                append(change.kind == .added ? "+" : change.kind == .updated ? "~" : "-",
                       id: change.nodeID, node: change.node, properties: change.changedProperties)
            }
        }
        return (lines.isEmpty && !full ? "No accessibility changes." : lines.joined(separator: "\n"), truncated)
    }
}

extension LiveAccessibilityHistory {
    func observation(options: PabloLiveObservationOptions) throws -> PabloLiveTreeObservation {
        try options.validate()
        guard let current = steps.last else {
            throw RecordingError.staleContext("No live accessibility observation is available. Observe the application first.")
        }
        let baseline = options.full ? nil : options.baselineReference.flatMap { try? step(reference: $0) }
        return .init(sessionID: sessionID, current: current, reference: reference(for: current),
                     baseline: baseline, baselineReference: options.baselineReference,
                     resyncRequired: !options.full && options.baselineReference != nil && baseline == nil)
    }
}
