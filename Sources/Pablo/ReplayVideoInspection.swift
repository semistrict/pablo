import Foundation
import CoreGraphics

/// A recorded observation, never a live lookup or an interpolated position.
public struct ReplayVideoElement: Identifiable, Sendable {
    public let node: ReplayAccessibilityNode
    public let step: ReplayAccessibilityStep
    public let region: CGRect
    public var id: String { node.id }
}

/// Prepared once per evidence/viewport change, then reused for pointer movement.
public struct ReplayVideoInspection: Sendable {
    private let viewport: RecordingRect
    private let windows: [RecordingWindow]
    private struct Candidate: Sendable {
        let element: ReplayVideoElement
        let windowFrame: ReplayAccessibilityFrame?
        let windowID: String?
        let windowTitle: String?
    }
    private let elements: [Candidate]
    private let recordedRegions: [CGRect]

    public init(
        viewport: RecordingRect,
        steps: [ReplayAccessibilityStep],
        windows: [RecordingWindow],
        recordedFrames: [RecordingRect]
    ) {
        self.viewport = viewport
        self.windows = windows.filter(\.isOnScreen).sorted { $0.zOrder < $1.zOrder }
        recordedRegions = recordedFrames.map { viewport.normalizedRect(for: $0) }
        elements = steps.flatMap { step in
            let byID = Dictionary(uniqueKeysWithValues: step.nodes.map { ($0.id, $0) })
            return step.nodes.compactMap { node -> Candidate? in
                guard node.role != "AXApplication", let frame = node.frame else { return nil }
                let bounds = RecordingRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                guard bounds.isValid else { return nil }
                let region = viewport.normalizedRect(for: bounds)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !region.isNull, !region.isEmpty else { return nil }
                var ancestor: ReplayAccessibilityNode? = node
                var visited = Set<String>()
                var windowFrame: ReplayAccessibilityFrame?
                var windowNode: ReplayAccessibilityNode?
                while let parent = ancestor, visited.insert(parent.id).inserted {
                    if parent.role == "AXWindow" { windowFrame = parent.frame; windowNode = parent; break }
                    ancestor = parent.parentID.flatMap { byID[$0] }
                }
                return Candidate(
                    element: ReplayVideoElement(node: node, step: step, region: region),
                    windowFrame: windowFrame,
                    windowID: windowNode?.id,
                    windowTitle: windowNode?.title
                )
            }
        }
    }

    public func element(at point: CGPoint) -> ReplayVideoElement? {
        guard point.x.isFinite, point.y.isFinite,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(point),
              recordedRegions.contains(where: { $0.contains(point) }) else { return nil }
        let desktopPoint = CGPoint(
            x: viewport.x + point.x * viewport.width,
            y: viewport.y + point.y * viewport.height
        )
        // An uninspectable front window must not expose an element behind it.
        guard let window = windows.first(where: { $0.frame.cgRect.contains(desktopPoint) }) else { return nil }
        var candidates = elements.filter { candidate in
            let element = candidate.element
            guard element.step.applicationID == window.applicationID,
                  element.region.contains(point) else { return false }
            // Do not select a different AXWindow subtree from the same app.
            if let frame = candidate.windowFrame {
                return abs(frame.x - window.frame.x) < 2 && abs(frame.y - window.frame.y) < 2 &&
                    abs(frame.width - window.frame.width) < 2 && abs(frame.height - window.frame.height) < 2
            }
            return true
        }
        // Multiple windows of one app can have identical bounds. Use their
        // recorded titles to distinguish them, or leave the overlap uninspected.
        if Set(candidates.compactMap(\.windowID)).count > 1 {
            guard let title = window.title, !title.isEmpty else { return nil }
            candidates = candidates.filter { $0.windowTitle == title }
            guard Set(candidates.compactMap(\.windowID)).count == 1 else { return nil }
        }
        return candidates.map(\.element).min { lhs, rhs in
            let leftArea = lhs.region.width * lhs.region.height
            let rightArea = rhs.region.width * rhs.region.height
            if leftArea != rightArea { return leftArea < rightArea }
            if lhs.node.depth != rhs.node.depth { return lhs.node.depth > rhs.node.depth }
            return lhs.id < rhs.id
        }
    }
}

extension ReplayRecording {
    public func videoInspection(atVideoTime time: TimeInterval, viewport: RecordingRect) -> ReplayVideoInspection {
        let timestamp = sessionTimestampNs(forVideoTime: time)
        // Do not borrow a future workspace or accessibility snapshot before capture.
        let workspace = workspaceSteps.last { $0.timestampNs <= timestamp }
        return ReplayVideoInspection(
            viewport: viewport,
            steps: accessibilitySteps(atVideoTime: time),
            windows: workspace?.windows ?? [],
            recordedFrames: videoTracks.filter { $0.metadata.contains(timestampNs: timestamp) }.map(\.metadata.frame)
        )
    }
}
