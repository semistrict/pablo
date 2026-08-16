import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class PabloLiveActionController {
    private let inspectionManager: PabloLiveInspectionManager

    public init(inspectionManager: PabloLiveInspectionManager = PabloLiveInspectionManager()) {
        self.inspectionManager = inspectionManager
    }

    public func perform(_ request: PabloLiveActionRequest) async throws -> String {
        try PabloLiveActionValidator.validate(request)
        guard AXIsProcessTrusted() else {
            throw RecordingError.permission(
                "Accessibility access is required to control a live application. " +
                "Enable Pablo in System Settings > Privacy & Security > Accessibility."
            )
        }
        let requiresSnapshot = LiveActionSnapshotPolicy.requiresSnapshot(for: request)
        let context = try inspectionManager.actionContext(
            for: request.target,
            requiresSnapshot: requiresSnapshot
        )
        let target = context.target
        let reader = context.reader
        let snapshot = context.snapshot ?? AXTreeSnapshot(rootID: nil, nodes: [:], truncated: false)

        if request.kind == .perform {
            return try performAccessibilityAction(request, target: target, reader: reader)
        }
        if request.kind == .click,
           let result = try performBackgroundClickIfAvailable(request, target: target, reader: reader) {
            return result
        }

        try LiveActionForegroundPolicy.requireUnlock(for: request)
        guard CGPreflightPostEventAccess() else {
            throw RecordingError.permission(
                "Accessibility access is required to post foreground input. " +
                "Enable Pablo in System Settings > Privacy & Security > Accessibility."
            )
        }
        guard let application = NSRunningApplication(processIdentifier: target.pid) else {
            throw RecordingError.targetNotFound("The target application is no longer running.")
        }
        try await activate(application)

        switch request.kind {
        case .click:
            return try await click(request, target: target, reader: reader, snapshot: snapshot)
        case .drag:
            return try await drag(request, target: target, reader: reader, snapshot: snapshot)
        case .scroll:
            return try scroll(request, target: target, reader: reader, snapshot: snapshot)
        case .typeText:
            return try await typeText(request, target: target, reader: reader)
        case .key:
            return try await pressKey(request, target: target)
        case .perform:
            preconditionFailure("Accessibility actions return before foreground activation")
        }
    }

    private func performBackgroundClickIfAvailable(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader
    ) throws -> String? {
        guard let nodeID = request.nodeID,
              request.mouseButton == .left,
              request.clickCount == 1,
              let element = reader.element(id: nodeID),
              availableActions(for: element).contains(kAXPressAction as String) else {
            return nil
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw RecordingError.capture(
                "The target rejected AXPress for node \(nodeID) (error \(result.rawValue))."
            )
        }
        return "clicked  \(target.name)  node=\(nodeID)  action=AXPress"
    }

    private func click(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader,
        snapshot: AXTreeSnapshot
    ) async throws -> String {
        let windowFrame = request.point == nil
            ? .zero
            : try largestWindowFrame(in: snapshot, reader: reader)
        let point = try resolvedPoint(
            nodeID: request.nodeID,
            point: request.point,
            snapshot: snapshot,
            windowFrame: windowFrame
        )
        try await postClicks(
            at: point,
            button: request.mouseButton,
            count: request.clickCount
        )
        return String(
            format: "clicked  %@  at=(%.1f,%.1f)  button=%@  count=%d",
            target.name,
            point.x,
            point.y,
            request.mouseButton.rawValue,
            request.clickCount
        )
    }

    private func activate(_ application: NSRunningApplication) async throws {
        if application.isActive { return }
        guard let bundleURL = application.bundleURL else {
            throw RecordingError.capture("The target application has no launchable bundle URL.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            ) { openedApplication, error in
                if let error {
                    continuation.resume(throwing: RecordingError.capture(
                        "The target application could not be activated: \(error.localizedDescription)"
                    ))
                } else if openedApplication == nil {
                    continuation.resume(throwing: RecordingError.capture(
                        "The target application could not be activated."
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
        for _ in 0..<20 {
            if application.isActive { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RecordingError.capture("The target application did not become active.")
    }

    private func drag(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader,
        snapshot: AXTreeSnapshot
    ) async throws -> String {
        let windowFrame = request.fromPoint == nil && request.toPoint == nil
            ? .zero
            : try largestWindowFrame(in: snapshot, reader: reader)
        let start = try resolvedPoint(
            nodeID: request.fromNodeID,
            point: request.fromPoint,
            snapshot: snapshot,
            windowFrame: windowFrame
        )
        let end = try resolvedPoint(
            nodeID: request.toNodeID,
            point: request.toPoint,
            snapshot: snapshot,
            windowFrame: windowFrame
        )
        let source = CGEventSource(stateID: .hidSystemState)
        let eventTypes = mouseEventTypes(for: request.mouseButton)
        guard let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: start,
            mouseButton: eventTypes.button
        ), let down = CGEvent(
            mouseEventSource: source,
            mouseType: eventTypes.down,
            mouseCursorPosition: start,
            mouseButton: eventTypes.button
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: eventTypes.up,
            mouseCursorPosition: end,
            mouseButton: eventTypes.button
        ) else {
            throw RecordingError.capture("Could not create drag events.")
        }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)

        let stepCount = max(2, min(600, Int(request.duration * 60)))
        do {
            for step in 1...stepCount {
                let progress = Double(step) / Double(stepCount)
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: eventTypes.dragged,
                    mouseCursorPosition: point,
                    mouseButton: eventTypes.button
                ) else {
                    throw RecordingError.capture("Could not create a drag event.")
                }
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .seconds(request.duration / Double(stepCount)))
            }
        } catch {
            up.post(tap: .cghidEventTap)
            throw error
        }
        up.post(tap: .cghidEventTap)
        return String(
            format: "dragged  %@  from=(%.1f,%.1f)  to=(%.1f,%.1f)",
            target.name,
            start.x,
            start.y,
            end.x,
            end.y
        )
    }

    private func scroll(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader,
        snapshot: AXTreeSnapshot
    ) throws -> String {
        guard let direction = request.scrollDirection else {
            throw RecordingError.usage("The scroll request did not include a direction.")
        }
        let windowFrame = request.point == nil && request.nodeID != nil
            ? .zero
            : try largestWindowFrame(in: snapshot, reader: reader)
        let point: CGPoint
        if request.nodeID != nil || request.point != nil {
            point = try resolvedPoint(
                nodeID: request.nodeID,
                point: request.point,
                snapshot: snapshot,
                windowFrame: windowFrame
            )
        } else {
            point = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        }
        let vertical: Int32
        let horizontal: Int32
        switch direction {
        case .up: (vertical, horizontal) = (Int32(request.scrollAmount), 0)
        case .down: (vertical, horizontal) = (-Int32(request.scrollAmount), 0)
        case .left: (vertical, horizontal) = (0, Int32(request.scrollAmount))
        case .right: (vertical, horizontal) = (0, -Int32(request.scrollAmount))
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            throw RecordingError.capture("Could not create the scroll event.")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return "scrolled  \(target.name)  direction=\(direction.rawValue)  amount=\(request.scrollAmount)"
    }

    private func typeText(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader
    ) async throws -> String {
        guard let text = request.text, !text.isEmpty else {
            throw RecordingError.usage("The type request did not include text.")
        }
        if let nodeID = request.nodeID {
            guard let element = reader.element(id: nodeID) else {
                throw missingNode(nodeID)
            }
            let result = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            guard result == .success else {
                throw RecordingError.capture("The target could not focus node \(nodeID) (error \(result.rawValue)).")
            }
        }

        let utf16 = Array(text.utf16)
        for offset in stride(from: 0, to: utf16.count, by: 20) {
            try requireActiveTarget(target)
            let chunk = Array(utf16[offset..<min(offset + 20, utf16.count)])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw RecordingError.capture("Could not create keyboard events.")
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            await Task.yield()
        }
        return "typed  \(target.name)  characters=\(text.count)"
    }

    private func pressKey(
        _ request: PabloLiveActionRequest,
        target: TargetApplication
    ) async throws -> String {
        guard let key = request.key,
              let keyCode = PabloLiveKeyMap.keyCode(for: key) else {
            throw RecordingError.usage(
                "Unknown key. Use a letter, digit, or a supported named key such as return, tab, escape, delete, or an arrow key."
            )
        }
        let flags = request.modifiers.reduce(CGEventFlags()) { result, modifier in
            result.union(modifier.eventFlag)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw RecordingError.capture("Could not create key events.")
        }
        down.flags = flags
        up.flags = flags
        try requireActiveTarget(target)
        down.post(tap: .cghidEventTap)
        do {
            try await Task.sleep(for: .milliseconds(30))
        } catch {
            up.post(tap: .cghidEventTap)
            throw error
        }
        up.post(tap: .cghidEventTap)
        let modifiers = request.modifiers.map(\.rawValue).joined(separator: ",")
        return "pressed  \(target.name)  key=\(key)" + (modifiers.isEmpty ? "" : "  modifiers=\(modifiers)")
    }

    private func performAccessibilityAction(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader
    ) throws -> String {
        guard let nodeID = request.nodeID, let requested = request.accessibilityAction else {
            throw RecordingError.usage("The perform request requires a node and action.")
        }
        guard let element = reader.element(id: nodeID) else { throw missingNode(nodeID) }
        let actions = availableActions(for: element)
        guard let action = LiveAccessibilityActions.match(requested, in: actions) else {
            let available = actions.isEmpty ? "none" : actions.joined(separator: ", ")
            throw RecordingError.usage(
                "Node \(nodeID) does not expose \(requested). Available actions: \(available)."
            )
        }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw RecordingError.capture("The target rejected \(action) for node \(nodeID) (error \(result.rawValue)).")
        }
        return "performed  \(target.name)  node=\(nodeID)  action=\(action)"
    }

    private func resolvedPoint(
        nodeID: String?,
        point: PabloLivePoint?,
        snapshot: AXTreeSnapshot,
        windowFrame: CGRect
    ) throws -> CGPoint {
        if let nodeID {
            guard let node = snapshot.nodes[nodeID],
                  let position = node.position,
                  let size = node.size,
                  size.width > 0,
                  size.height > 0 else {
                throw missingNode(nodeID)
            }
            return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        }
        guard let point else {
            throw RecordingError.usage("The action did not include a node or point.")
        }
        return LiveActionGeometry.absolute(point, in: windowFrame)
    }

    private func largestWindowFrame(
        in snapshot: AXTreeSnapshot,
        reader: AccessibilityTreeReader
    ) throws -> CGRect {
        let frames: [CGRect] = snapshot.nodes.values
            .filter { $0.role == "AXWindow" && $0.position != nil && $0.size != nil }
            .compactMap { node -> CGRect? in
                guard let position = node.position, let size = node.size,
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
            }
        guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height })
                ?? reader.largestWindowFrame() else {
            throw RecordingError.capture("The target application has no accessible visible window.")
        }
        return frame
    }

    private func requireActiveTarget(_ target: TargetApplication) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw RecordingError.capture(
                "The target application lost focus before keyboard input could be delivered."
            )
        }
    }

    private func availableActions(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else { return [] }
        return names
    }

    private func missingNode(_ nodeID: String) -> RecordingError {
        .usage(
            "Live accessibility node \(nodeID) is unavailable. Run `pablo frames` again and use a node from the latest frame."
        )
    }

    private func postClicks(
        at point: CGPoint,
        button: PabloLiveMouseButton,
        count: Int
    ) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let eventTypes = mouseEventTypes(for: button)
        for click in 1...count {
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: eventTypes.down,
                mouseCursorPosition: point,
                mouseButton: eventTypes.button
            ), let up = CGEvent(
                mouseEventSource: source,
                mouseType: eventTypes.up,
                mouseCursorPosition: point,
                mouseButton: eventTypes.button
            ) else {
                throw RecordingError.capture("Could not create mouse events.")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if click < count { try await Task.sleep(for: .milliseconds(80)) }
        }
    }

    private func mouseEventTypes(
        for button: PabloLiveMouseButton
    ) -> (button: CGMouseButton, down: CGEventType, up: CGEventType, dragged: CGEventType) {
        switch button {
        case .left: return (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: return (.center, .otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }
}

enum LiveActionForegroundPolicy {
    static func requiresUnlock(for request: PabloLiveActionRequest) -> Bool {
        request.kind != .perform
    }

    static func requireUnlock(for request: PabloLiveActionRequest) throws {
        guard !requiresUnlock(for: request) || request.unlockForegroundActions else {
            throw RecordingError.usage(
                "This action requires Pablo to bring the target application to the foreground, " +
                "but foreground actions are locked by default. Set unlockForegroundActions to true " +
                "only when the user explicitly accepts the focus change. This option is NOT RECOMMENDED."
            )
        }
    }
}

enum PabloLiveActionValidator {
    static func validate(_ request: PabloLiveActionRequest) throws {
        let targetCount = [
            request.target.pid != nil,
            request.target.bundleIdentifier?.isEmpty == false,
            request.target.appName?.isEmpty == false,
        ].filter { $0 }.count
        guard targetCount == 1, request.target.pid.map({ $0 > 0 }) ?? true else {
            throw RecordingError.usage(
                "Choose exactly one live target with --app, --bundle-id, or --pid."
            )
        }
        try validate(point: request.point)
        try validate(point: request.fromPoint)
        try validate(point: request.toPoint)

        switch request.kind {
        case .click:
            guard (request.nodeID == nil) != (request.point == nil),
                  (1...3).contains(request.clickCount) else {
                throw RecordingError.usage(
                    "click requires one node or normalized point and a click count from 1 to 3."
                )
            }
        case .drag:
            guard (request.fromNodeID == nil) != (request.fromPoint == nil),
                  (request.toNodeID == nil) != (request.toPoint == nil),
                  request.duration.isFinite,
                  (0.05...10).contains(request.duration) else {
                throw RecordingError.usage(
                    "drag requires one valid source, one valid destination, and a duration from 0.05 to 10 seconds."
                )
            }
        case .scroll:
            guard request.scrollDirection != nil,
                  (1...100).contains(request.scrollAmount),
                  request.nodeID == nil || request.point == nil else {
                throw RecordingError.usage(
                    "scroll requires a direction, an amount from 1 to 100, and at most one location."
                )
            }
        case .typeText:
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 32 * 1_024 else {
                throw RecordingError.usage("type requires nonempty text of at most 32 KiB.")
            }
        case .key:
            guard let key = request.key, PabloLiveKeyMap.keyCode(for: key) != nil else {
                throw RecordingError.usage("key requires a supported key name.")
            }
        case .perform:
            guard request.nodeID?.isEmpty == false,
                  request.accessibilityAction?.isEmpty == false else {
                throw RecordingError.usage("perform requires a node and accessibility action.")
            }
        }
    }

    private static func validate(point: PabloLivePoint?) throws {
        guard let point else { return }
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw RecordingError.usage("Live action coordinates must be normalized from zero to one.")
        }
    }
}

enum LiveActionSnapshotPolicy {
    static func requiresSnapshot(for request: PabloLiveActionRequest) -> Bool {
        switch request.kind {
        case .key:
            false
        case .typeText:
            request.nodeID != nil
        case .click:
            request.nodeID != nil
        case .drag:
            request.fromNodeID != nil || request.toNodeID != nil
        case .scroll:
            request.nodeID != nil
        case .perform:
            true
        }
    }
}

enum LiveActionGeometry {
    static func absolute(_ point: PabloLivePoint, in windowFrame: CGRect) -> CGPoint {
        CGPoint(
            x: windowFrame.minX + windowFrame.width * point.x,
            y: windowFrame.minY + windowFrame.height * point.y
        )
    }
}

enum LiveAccessibilityActions {
    static func match(_ requested: String, in available: [String]) -> String? {
        available.first { normalize($0) == normalize(requested) }
    }

    static func normalize(_ value: String) -> String {
        var normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized.hasPrefix("ax") { normalized.removeFirst(2) }
        return normalized
    }
}

enum PabloLiveKeyMap {
    static func keyCode(for raw: String) -> CGKeyCode? {
        let key = raw.lowercased()
        if let code = named[key] { return code }
        if key.count == 1, let code = characters[key] { return code }
        return nil
    }

    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page-up": 116, "page-down": 121,
        "forward-delete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let characters: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}

private extension PabloLiveKeyModifier {
    var eventFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .shift: return .maskShift
        case .function: return .maskSecondaryFn
        }
    }
}
