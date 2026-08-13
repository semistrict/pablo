import AppKit
import ApplicationServices
import Foundation

final class InputRecorder {
    typealias EventHandler = (InputEventRecord) -> Void

    private let scope: RecordingScopeKind
    private let selectedPID: pid_t?
    private let registry: RecordingApplicationRegistry
    private let clock: SessionClock
    private let includeText: Bool
    private let targetFrame: () -> CGRect?
    private let handler: EventHandler
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var paused = false

    init(
        scope: RecordingScopeKind,
        selectedPID: pid_t?,
        registry: RecordingApplicationRegistry,
        clock: SessionClock,
        includeText: Bool,
        targetFrame: @escaping () -> CGRect?,
        handler: @escaping EventHandler
    ) {
        self.scope = scope
        self.selectedPID = selectedPID
        self.registry = registry
        self.clock = clock
        self.includeText = includeText
        self.targetFrame = targetFrame
        self.handler = handler
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var startupError: RecordingError?
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let mask = Self.eventTypes.reduce(CGEventMask(0)) {
                $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
            }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue()
                recorder.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                startupError = .permission(
                    "Unable to create the input event tap. Enable Accessibility and Input Monitoring for the terminal or built executable in System Settings > Privacy & Security."
                )
                ready.signal()
                return
            }

            let loop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.stateLock.lock()
            self.eventTap = tap
            self.runLoop = loop
            self.stateLock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "pablo.input-recorder"
        self.thread = thread
        thread.start()
        ready.wait()
        if let startupError { throw startupError }
    }

    func stop() {
        stateLock.lock()
        let loop = runLoop
        runLoop = nil
        eventTap = nil
        stateLock.unlock()
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    func pause() {
        stateLock.withLock { paused = true }
    }

    func resume() {
        stateLock.withLock { paused = false }
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = eventTap
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard shouldRecord(type: type, event: event) else { return }

        let location = event.location
        let isPointer = Self.pointerTypes.contains(type)
        let isScroll = type == .scrollWheel
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        let text = includeText && type == .keyDown ? keyboardText(from: event) : nil
        let timestampNs = clock.nowNanoseconds()
        let rawPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let attributedPID = rawPID > 0 ? rawPID : NSWorkspace.shared.frontmostApplication?.processIdentifier
        let application = attributedPID.flatMap { registry.application(for: $0, timestampNs: timestampNs) }
        let windowID: String?
        if isPointer || isScroll {
            let workspace = registry.snapshot(
                timestampNs: timestampNs,
                reason: "input-attribution",
                captureFrame: targetFrame(),
                tracksLifecycle: false
            )
            windowID = workspace.windows.first(where: {
                $0.applicationID == application?.id && CGRect(
                    x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height
                ).contains(location)
            })?.id
        } else {
            windowID = nil
        }
        let record = InputEventRecord(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            timestampNs: timestampNs,
            type: Self.name(for: type),
            targetPID: attributedPID.map(Int64.init),
            applicationID: application?.id,
            windowID: windowID,
            x: isPointer || isScroll ? location.x : nil,
            y: isPointer || isScroll ? location.y : nil,
            deltaX: isScroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : nil,
            deltaY: isScroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : nil,
            keyCode: isKeyboard ? event.getIntegerValueField(.keyboardEventKeycode) : nil,
            text: text,
            flags: event.flags.rawValue,
            button: isPointer ? event.getIntegerValueField(.mouseEventButtonNumber) : nil,
            clickCount: isPointer ? event.getIntegerValueField(.mouseEventClickState) : nil,
            automationAction: nil
        )
        handler(record)
    }

    private func shouldRecord(type: CGEventType, event: CGEvent) -> Bool {
        guard !stateLock.withLock({ paused }) else { return false }
        if scope == .display { return true }
        guard let selectedPID else { return false }
        let eventPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if eventPID == selectedPID { return true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedPID { return true }
        if Self.pointerTypes.contains(type) || type == .scrollWheel,
           let frame = targetFrame(), frame.contains(event.location) {
            return true
        }
        return false
    }

    private func keyboardText(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    private static let eventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
        .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        .keyDown, .keyUp, .flagsChanged,
    ]

    private static let pointerTypes: Set<CGEventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
        .rightMouseDragged, .otherMouseDragged,
    ]

    private static func name(for type: CGEventType) -> String {
        switch type {
        case .leftMouseDown: return "mouseDown"
        case .leftMouseUp: return "mouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .mouseMoved: return "mouseMove"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return "mouseDrag"
        case .scrollWheel: return "scroll"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .flagsChanged: return "flagsChanged"
        default: return "event-\(type.rawValue)"
        }
    }
}
