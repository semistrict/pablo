import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class PabloLiveActionController {
    private let inspectionManager: PabloLiveInspectionManager

    public init(inspectionManager: PabloLiveInspectionManager? = nil) {
        self.inspectionManager = inspectionManager ?? PabloLiveInspectionManager()
    }

    public func perform(_ request: PabloLiveActionRequest, actionID: UUID = UUID()) async throws -> PabloLiveActionResult {
        try PabloLiveActionValidator.validate(request)
        var result = try await dispatch(request, actionID: actionID)
        if let options = request.observation {
            do {
                // Pin the process and session from dispatch. The old frame precondition was consumed by the action.
                result.observation = try await inspectionManager.observe(target: .init(
                    pid: result.target.pid, sessionID: result.target.sessionID, windowID: result.target.windowID
                ), options: options)
            } catch {
                result.observationFailure = .init(error)
            }
        }
        return result
    }

    private func dispatch(_ request: PabloLiveActionRequest, actionID: UUID) async throws -> PabloLiveActionResult {
        guard AXIsProcessTrusted() else {
            throw RecordingError.permission(
                "Accessibility access is required to control a live application. " +
                "Enable Pablo in System Settings > Privacy & Security > Accessibility."
            )
        }
        let requiresSnapshot = LiveActionSnapshotPolicy.requiresSnapshot(for: request) || request.target.windowID != nil || request.target.frameReference != nil
        let context = try inspectionManager.actionContext(
            for: request.target,
            requiresSnapshot: requiresSnapshot
        )
        let target = context.target
        let reader = context.reader
        func result(_ summary: String, method: PabloLiveActionResult.DispatchMethod) -> PabloLiveActionResult {
            .init(actionID: actionID, target: .init(
                pid: target.pid, bundleIdentifier: target.bundleIdentifier, applicationName: target.name,
                sessionID: context.sessionID, windowID: request.target.windowID,
                inspectionFrameReference: context.frameReference
            ), dispatchMethod: method, characterCount: request.text?.count, summary: summary)
        }
        for nodeID in [request.nodeID, request.fromNodeID, request.toNodeID].compactMap({ $0 }) {
            guard reader.validatedElement(id: nodeID, windowID: request.target.windowID) != nil else { throw missingNode(nodeID) }
        }
        try Task.checkCancellation()

        if request.kind == .selectText || request.kind == .setValue {
            guard let nodeID = request.nodeID, let text = request.text else {
                throw RecordingError.usage("Precise text editing requires a node and text.")
            }
            let editable = NativeLiveTextEditingTarget(reader: reader, nodeID: nodeID,
                windowID: request.target.windowID, validateContext: context.validate)
            if request.kind == .selectText {
                try LiveTextEditor.select(text, options: request.selection ?? .init(), target: editable)
            } else {
                try LiveTextEditor.replace(with: text, target: editable)
            }
            return result("\(request.kind.rawValue)  \(target.name)  node=\(nodeID)  characters=\(text.count)", method: .accessibility)
        }
        if request.kind == .perform {
            return result(try performAccessibilityAction(request, target: target, reader: reader), method: .accessibility)
        }
        if request.kind == .click,
           let summary = try performBackgroundClickIfAvailable(request, target: target, reader: reader) {
            return result(summary, method: .accessibility)
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
        switch request.kind {
        case .click, .drag, .scroll:
            return result(try await LivePointerExecutor.perform(
                request,
                target: NativeLivePointerTarget(target: target, reader: reader, windowID: request.target.windowID, validateContext: context.validate, activation: {
                    try await self.activate(application)
                }),
                events: NativeLivePointerEvents()
            ), method: .foregroundInput)
        case .typeText:
            try await activate(application)
            try context.validate()
            if let windowID = request.target.windowID { try reader.focusWindow(id: windowID) }
            return result(try await typeText(request, target: target, reader: reader, validateContext: context.validate), method: .foregroundInput)
        case .paste:
            try await activate(application)
            try context.validate()
            if let windowID = request.target.windowID { try reader.focusWindow(id: windowID) }
            try focusTextNode(request, reader: reader)
            let restoration = try await LivePasteTransaction.perform(
                items: LivePasteTransaction.items(text: request.text!, format: request.pasteFormat ?? .text, plainText: request.plainText),
                pasteboard: NativeLivePasteboard(), validate: {
                    try context.validate()
                    try self.requireActiveTarget(target, reader: reader, windowID: request.target.windowID)
                    if let nodeID = request.nodeID, !reader.isFocused(id: nodeID) {
                        throw RecordingError.interrupted("The selected live text field lost focus; paste was interrupted.")
                    }
                }, paste: {
                    let key = PabloLiveActionRequest(kind: .key, target: request.target, key: "v", modifiers: [.command], unlockForegroundActions: true)
                    _ = try await self.pressKey(key, target: target, reader: reader, validateContext: context.validate)
                    // Event posting is asynchronous. Keep representations available while the app handles the shortcut.
                    try await Task.sleep(for: .milliseconds(500))
                })
            var pasted = result("pasted  \(target.name)  characters=\(request.text!.count)", method: .foregroundInput)
            pasted.clipboardRestoration = restoration
            return pasted
        case .key:
            try await activate(application)
            try context.validate()
            if let windowID = request.target.windowID { try reader.focusWindow(id: windowID) }
            return result(try await pressKey(request, target: target, reader: reader, validateContext: context.validate), method: .foregroundInput)
        case .perform, .selectText, .setValue:
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
              let element = reader.validatedElement(id: nodeID, windowID: request.target.windowID),
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

    private func activate(_ application: NSRunningApplication) async throws {
        guard !application.isTerminated else { throw RecordingError.targetNotFound("The target application stopped running before activation.") }
        if application.isActive { return }
        // Activate the existing process directly. Opening its bundle could restart an app the human just quit.
        guard application.activate(options: []) else {
            throw RecordingError.capture("The target application did not accept activation.")
        }
        for _ in 0..<20 {
            if application.isActive { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RecordingError.capture("The target application did not become active.")
    }

    private func typeText(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader,
        validateContext: @MainActor () throws -> Void
    ) async throws -> String {
        guard let text = request.text, !text.isEmpty else {
            throw RecordingError.usage("The type request did not include text.")
        }
        try focusTextNode(request, reader: reader)

        for chunk in LiveTextInput.chunks(text) {
            try validateContext()
            try requireActiveTarget(target, reader: reader, windowID: request.target.windowID)
            if let nodeID = request.nodeID, !reader.isFocused(id: nodeID) {
                throw RecordingError.interrupted("The selected live text field lost focus; typing was interrupted.")
            }
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

    private func focusTextNode(_ request: PabloLiveActionRequest, reader: AccessibilityTreeReader) throws {
        if let nodeID = request.nodeID {
            guard let element = reader.validatedElement(id: nodeID, windowID: request.target.windowID) else {
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

    }

    private func pressKey(
        _ request: PabloLiveActionRequest,
        target: TargetApplication,
        reader: AccessibilityTreeReader,
        validateContext: @MainActor () throws -> Void
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
        try validateContext()
        try requireActiveTarget(target, reader: reader, windowID: request.target.windowID)
        down.post(tap: .cghidEventTap)
        do {
            try await Task.sleep(for: .milliseconds(30))
            try validateContext()
            try requireActiveTarget(target, reader: reader, windowID: request.target.windowID)
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
        guard let element = reader.validatedElement(id: nodeID, windowID: request.target.windowID) else { throw missingNode(nodeID) }
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

    private func requireActiveTarget(_ target: TargetApplication, reader: AccessibilityTreeReader, windowID: String?) throws {
        if let windowID, !reader.isFocusedWindow(id: windowID) {
            throw RecordingError.interrupted("The selected live window lost focus; keyboard input was interrupted.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw RecordingError.interrupted(
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


}

enum LiveActionForegroundPolicy {
    static func requiresUnlock(for request: PabloLiveActionRequest) -> Bool {
        ![.perform, .selectText, .setValue].contains(request.kind)
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
        try request.target.validate()
        try request.observation?.validate()
        try request.selection?.validate()
        guard request.selection == nil || request.kind == .selectText,
              (request.pasteFormat == nil && request.plainText == nil) || request.kind == .paste,
              request.plainText == nil || request.pasteFormat == .html else {
            throw RecordingError.usage("Selection and paste options apply only to their respective actions.")
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
        case .typeText, .paste:
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 32 * 1_024 else {
                throw RecordingError.usage("type requires nonempty text of at most 32 KiB.")
            }
            if request.kind == .paste, request.pasteFormat == .html {
                guard let fallback = request.plainText, !fallback.isEmpty, fallback.utf8.count <= 16 * 1_024 else {
                    throw RecordingError.usage("HTML paste requires a nonempty plainText fallback of at most 16 KiB.")
                }
            }
        case .selectText, .setValue:
            guard request.nodeID?.isEmpty == false, let text = request.text, text.utf8.count <= 32 * 1_024,
                  request.kind == .setValue || !text.isEmpty else {
                throw RecordingError.usage("Precise text editing requires a node and at most 32 KiB of text; only setValue accepts an empty value.")
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
        case .typeText, .paste:
            request.nodeID != nil
        case .click:
            request.nodeID != nil
        case .drag:
            request.fromNodeID != nil || request.toNodeID != nil
        case .scroll:
            request.nodeID != nil
        case .perform, .selectText, .setValue:
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


enum LiveTextInput {
    static func chunks(_ text: String) -> [[UInt16]] {
        let utf16 = Array(text.utf16)
        var result: [[UInt16]] = []
        var offset = 0
        while offset < utf16.count {
            var end = min(offset + 20, utf16.count)
            // CGEvent receives UTF-16; keep each scalar intact across event pairs.
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) { end -= 1 }
            result.append(Array(utf16[offset..<end]))
            offset = end
        }
        return result
    }
}
