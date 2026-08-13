import ApplicationServices
import Foundation

struct AXTreeDiff {
    let upserts: [AXNode]
    let removed: [String]
}

enum AXTreeDiffer {
    static func diff(previous: [String: AXNode], current: [String: AXNode]) -> AXTreeDiff {
        let upserts = current.values
            .filter { previous[$0.id] != $0 }
            .sorted { $0.id < $1.id }
        let removed = previous.keys.filter { current[$0] == nil }.sorted()
        return AXTreeDiff(upserts: upserts, removed: removed)
    }
}

struct AXTreeSnapshot {
    let rootID: String?
    let nodes: [String: AXNode]
    let truncated: Bool
}

final class AccessibilityTreeReader {
    private let appElement: AXUIElement
    private let maxDepth: Int
    private let maxNodes: Int
    private var elementsByID: [String: AXUIElement] = [:]

    init(pid: pid_t, maxDepth: Int = 30, maxNodes: Int = 10_000) {
        appElement = AXUIElementCreateApplication(pid)
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    func read() -> AXTreeSnapshot {
        var nodes: [String: AXNode] = [:]
        var elements: [String: AXUIElement] = [:]
        var visited = Set<String>()
        var visitedCount = 0
        var truncated = false

        func visit(_ element: AXUIElement, parentID: String?, depth: Int) -> String? {
            guard depth <= maxDepth, visitedCount < maxNodes else {
                truncated = true
                return nil
            }
            let role = stringAttribute(element, kAXRoleAttribute)
            let identifier = stringAttribute(element, kAXIdentifierAttribute)
            let id = "ax-\(CFHash(element))"
            guard !visited.contains(id) else { return id }
            visited.insert(id)
            elements[id] = element
            visitedCount += 1

            let size = sizeAttribute(element, kAXSizeAttribute)
            let rawChildren: [AXUIElement]
            if depth < maxDepth,
               visitedCount < maxNodes,
               AccessibilityTraversalPolicy.shouldTraverseChildren(role: role, size: size) {
                let visibleChildren = attribute(element, kAXVisibleChildrenAttribute) as? [AXUIElement]
                rawChildren = AccessibilityTraversalPolicy.preferredChildren(
                    visible: visibleChildren,
                    all: { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                )
            } else {
                rawChildren = []
                if depth >= maxDepth { truncated = true }
            }
            let childIDs = rawChildren.compactMap {
                visit($0, parentID: id, depth: depth + 1)
            }

            let subrole = stringAttribute(element, kAXSubroleAttribute)
            let isSecure = role == kAXTextFieldRole as String &&
                subrole == kAXSecureTextFieldSubrole as String
            nodes[id] = AXNode(
                id: id,
                parentID: parentID,
                childIDs: childIDs,
                role: role,
                subrole: subrole,
                title: stringAttribute(element, kAXTitleAttribute),
                label: stringAttribute(element, kAXDescriptionAttribute),
                value: isSecure ? "<redacted>" : printableAttribute(element, kAXValueAttribute),
                identifier: identifier,
                help: stringAttribute(element, kAXHelpAttribute),
                enabled: boolAttribute(element, kAXEnabledAttribute),
                focused: boolAttribute(element, kAXFocusedAttribute),
                position: pointAttribute(element, kAXPositionAttribute),
                size: size
            )
            return id
        }

        let rootID = visit(appElement, parentID: nil, depth: 0)
        elementsByID = elements
        return AXTreeSnapshot(rootID: rootID, nodes: nodes, truncated: truncated)
    }

    func element(id: String) -> AXUIElement? {
        elementsByID[id]
    }

    func largestWindowFrame() -> CGRect? {
        let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { window -> CGRect? in
            guard let position = pointAttribute(window, kAXPositionAttribute),
                  let size = sizeAttribute(window, kAXSizeAttribute),
                  size.width > 0,
                  size.height > 0 else { return nil }
            return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }
}

enum AccessibilityTraversalPolicy {
    static func shouldTraverseChildren(role: String?, size: AXNode.Size?) -> Bool {
        guard role == kAXMenuRole as String else { return true }
        guard let size else { return false }
        return size.width > 0 && size.height > 0
    }

    static func preferredChildren<Element>(
        visible: [Element]?,
        all: () -> [Element]
    ) -> [Element] {
        visible ?? all()
    }
}

final class AccessibilityRecorder {
    private let treeReader: AccessibilityTreeReader
    private let clock: SessionClock
    private let writer: ProtobufStreamWriter<AXSnapshotRecord>
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "pablo.accessibility-recorder", qos: .userInitiated)
    private let stateLock = NSLock()
    private var previous: [String: AXNode] = [:]
    private var timer: DispatchSourceTimer?
    private var pendingWork: DispatchWorkItem?
    private var stopped = false
    private var paused = false

    init(
        pid: pid_t,
        clock: SessionClock,
        writer: ProtobufStreamWriter<AXSnapshotRecord>,
        interval: TimeInterval,
        maxDepth: Int = 30,
        maxNodes: Int = 10_000
    ) {
        treeReader = AccessibilityTreeReader(pid: pid, maxDepth: maxDepth, maxNodes: maxNodes)
        self.clock = clock
        self.writer = writer
        self.interval = interval
    }

    func start() {
        queue.sync { capture(reason: "initial") }
        guard interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.capture(reason: "periodic") }
        self.timer = timer
        timer.resume()
    }

    func requestSnapshot(reason: String) {
        stateLock.lock()
        guard !stopped, !paused else {
            stateLock.unlock()
            return
        }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.capture(reason: reason) }
        pendingWork = work
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(75), execute: work)
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        pendingWork?.cancel()
        pendingWork = nil
        stateLock.unlock()
        timer?.cancel()
        timer = nil
        queue.sync { capture(reason: "final") }
    }

    func pause() {
        stateLock.withLock {
            paused = true
            pendingWork?.cancel()
            pendingWork = nil
        }
    }

    func resume() {
        stateLock.withLock { paused = false }
        requestSnapshot(reason: "resume")
    }

    private func capture(reason: String) {
        let shouldSkip = stateLock.withLock { paused && reason != "final" }
        guard !shouldSkip else { return }
        let tree = treeReader.read()
        let diff = AXTreeDiffer.diff(previous: previous, current: tree.nodes)
        let isInitial = previous.isEmpty
        let record = AXSnapshotRecord(
            schemaVersion: 2,
            timestampNs: clock.nowNanoseconds(),
            reason: reason,
            kind: isInitial ? "full" : "delta",
            rootID: tree.rootID,
            upserts: isInitial ? tree.nodes.values.sorted { $0.id < $1.id } : diff.upserts,
            removed: isInitial ? [] : diff.removed,
            truncated: tree.truncated
        )
        do {
            try writer.append(record)
            previous = tree.nodes
        } catch {
            FileHandle.standardError.write(Data("Accessibility write failed: \(error)\n".utf8))
        }
    }

}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let string = value as? String { return truncate(string) }
    return nil
}

private func printableAttribute(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let string = value as? String { return truncate(string) }
    if let number = value as? NSNumber { return number.stringValue }
    if let array = value as? [Any] {
        return truncate(array.map { String(describing: $0) }.joined(separator: ", "))
    }
    return nil
}

private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    (attribute(element, name) as? NSNumber)?.boolValue
}

private func pointAttribute(_ element: AXUIElement, _ name: String) -> AXNode.Point? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    guard AXValueGetType(value) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return AXNode.Point(x: point.x, y: point.y)
}

private func sizeAttribute(_ element: AXUIElement, _ name: String) -> AXNode.Size? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    guard AXValueGetType(value) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return AXNode.Size(width: size.width, height: size.height)
}

private func truncate(_ value: String, length: Int = 2_048) -> String {
    value.count <= length ? value : String(value.prefix(length)) + "…"
}
