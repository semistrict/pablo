import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol LivePointerTarget {
    var name: String { get }
    func activate() async throws
    func requireActive() throws
    func point(nodeID: String?, normalized: PabloLivePoint?) throws -> CGPoint
}

enum LivePointerEvent: Equatable {
    case move(CGPoint)
    case down(CGPoint, PabloLiveMouseButton, Int)
    case up(CGPoint, PabloLiveMouseButton, Int)
    case drag(CGPoint, PabloLiveMouseButton)
    case scroll(CGPoint, PabloLiveScrollDirection, Int)
}

@MainActor
protocol LivePointerEventSink {
    func post(_ event: LivePointerEvent) throws
    func pause(seconds: Double) async throws
}

@MainActor
enum LivePointerExecutor {
    static func perform(
        _ request: PabloLiveActionRequest,
        target: any LivePointerTarget,
        events: any LivePointerEventSink
    ) async throws -> String {
        try PabloLiveActionValidator.validate(request)
        try LiveActionForegroundPolicy.requireUnlock(for: request)
        try await target.activate()
        try Task.checkCancellation()
        try target.requireActive()
        switch request.kind {
        case .click:
            var point = CGPoint.zero
            for click in 1...request.clickCount {
                // Resolve after activation and again for each click; never reuse an inspection snapshot's geometry.
                point = try target.point(nodeID: request.nodeID, normalized: request.point)
                try Task.checkCancellation()
                try target.requireActive()
                try events.post(.down(point, request.mouseButton, click))
                do { try events.post(.up(point, request.mouseButton, click)) }
                catch {
                    try? events.post(.up(point, request.mouseButton, click))
                    throw error
                }
                if click < request.clickCount { try await events.pause(seconds: 0.08) }
            }
            return String(format: "clicked  %@  at=(%.1f,%.1f)  button=%@  count=%d",
                          target.name, point.x, point.y, request.mouseButton.rawValue, request.clickCount)
        case .drag:
            let start = try target.point(nodeID: request.fromNodeID, normalized: request.fromPoint)
            let end = try target.point(nodeID: request.toNodeID, normalized: request.toPoint)
            try target.requireActive()
            try events.post(.move(start))
            try target.requireActive()
            try events.post(.down(start, request.mouseButton, 1))
            var lastPoint = start
            do {
                let steps = max(2, min(600, Int(request.duration * 60)))
                for step in 1...steps {
                    try Task.checkCancellation()
                    try target.requireActive()
                    let progress = Double(step) / Double(steps)
                    let point = CGPoint(x: start.x + (end.x - start.x) * progress,
                                        y: start.y + (end.y - start.y) * progress)
                    try events.post(.drag(point, request.mouseButton))
                    lastPoint = point
                    try await events.pause(seconds: request.duration / Double(steps))
                }
                try Task.checkCancellation()
                try target.requireActive()
                try events.post(.up(lastPoint, request.mouseButton, 1))
            } catch {
                // Button release is cleanup, even after the user takes focus. Never finish the drag at its old destination.
                try? events.post(.up(lastPoint, request.mouseButton, 1))
                throw error
            }
            return String(format: "dragged  %@  from=(%.1f,%.1f)  to=(%.1f,%.1f)",
                          target.name, start.x, start.y, end.x, end.y)
        case .scroll:
            guard let direction = request.scrollDirection else { throw RecordingError.usage("A scroll direction is required.") }
            let point = try target.point(nodeID: request.nodeID, normalized: request.point)
            try target.requireActive()
            try events.post(.scroll(point, direction, request.scrollAmount))
            return "scrolled  \(target.name)  direction=\(direction.rawValue)  amount=\(request.scrollAmount)"
        default:
            throw RecordingError.usage("This action is not a pointer operation.")
        }
    }
}

@MainActor
protocol LivePointerGeometry {
    func largestWindowFrame() -> CGRect?
    func windowFrame(id: String) -> CGRect?
    func currentFrame(id: String, windowID: String?) -> CGRect?
    func focusWindow(id: String) throws
    func isFocusedWindow(id: String) -> Bool
}

extension AccessibilityTreeReader: LivePointerGeometry {}

@MainActor
struct NativeLivePointerTarget: LivePointerTarget {
    let target: TargetApplication
    let reader: any LivePointerGeometry
    var windowID: String? = nil
    var validateContext: @MainActor () throws -> Void = {}
    let activation: @MainActor () async throws -> Void
    var name: String { target.name }
    func activate() async throws {
        try validateContext()
        try await activation()
        try validateContext()
        if let windowID { try reader.focusWindow(id: windowID) }
    }

    func requireActive() throws {
        try validateContext()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw RecordingError.interrupted("The target application lost focus; pointer input was interrupted.")
        }
        if let windowID, !reader.isFocusedWindow(id: windowID) {
            throw RecordingError.interrupted("The selected live window lost focus; pointer input was interrupted.")
        }
    }

    func point(nodeID: String?, normalized: PabloLivePoint?) throws -> CGPoint {
        if let nodeID {
            guard let frame = reader.currentFrame(id: nodeID, windowID: windowID) else {
                throw RecordingError.usage("Live accessibility node \(nodeID) is unavailable or outside its current window. Inspect the app again.")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let bounds: CGRect?
        if let windowID { bounds = reader.windowFrame(id: windowID) }
        else { bounds = reader.largestWindowFrame() }
        guard let frame = bounds else {
            throw RecordingError.capture("The target application has no accessible visible window.")
        }
        return LiveActionGeometry.absolute(normalized ?? .init(x: 0.5, y: 0.5), in: frame)
    }
}

@MainActor
struct NativeLivePointerEvents: LivePointerEventSink {
    func pause(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    func post(_ input: LivePointerEvent) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let event: CGEvent?
        switch input {
        case .scroll(let point, let direction, let amount):
            let vertical: Int32
            let horizontal: Int32
            switch direction {
            case .up: (vertical, horizontal) = (Int32(amount), 0)
            case .down: (vertical, horizontal) = (-Int32(amount), 0)
            case .left: (vertical, horizontal) = (0, Int32(amount))
            case .right: (vertical, horizontal) = (0, -Int32(amount))
            }
            event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.location = point
        case .move(let point):
            event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        case .down(let point, let button, let count), .up(let point, let button, let count):
            let types = eventTypes(button)
            let type: CGEventType
            if case .down = input { type = types.down } else { type = types.up }
            event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: types.button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        case .drag(let point, let button):
            let types = eventTypes(button)
            event = CGEvent(mouseEventSource: source, mouseType: types.dragged,
                            mouseCursorPosition: point, mouseButton: types.button)
        }
        guard let event else { throw RecordingError.capture("Could not create a pointer event.") }
        event.post(tap: .cghidEventTap)
    }

    private func eventTypes(_ button: PabloLiveMouseButton)
        -> (button: CGMouseButton, down: CGEventType, up: CGEventType, dragged: CGEventType) {
        switch button {
        case .left: return (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: return (.center, .otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }
}
