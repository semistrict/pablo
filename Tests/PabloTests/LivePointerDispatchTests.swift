import CoreGraphics
import Foundation
import Testing
@testable import PabloCore

@MainActor
private final class PointerTargetFixture: LivePointerTarget {
    let name = "Fixture"
    var frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var frameAfterActivation = CGRect(x: 400, y: 300, width: 200, height: 100)
    var active = true
    func activate() async throws { frame = frameAfterActivation }
    func requireActive() throws {
        guard active else { throw RecordingError.capture("fixture focus changed") }
    }
    func point(nodeID: String?, normalized: PabloLivePoint?) throws -> CGPoint {
        let point = normalized ?? PabloLivePoint(x: 0.5, y: 0.5)
        return LiveActionGeometry.absolute(point, in: frame)
    }
}

@MainActor
private final class PointerEventsFixture: LivePointerEventSink {
    var events: [LivePointerEvent] = []
    var duringPause: () -> Void = {}
    func post(_ event: LivePointerEvent) throws { events.append(event) }
    func pause(seconds: Double) async throws { duringPause() }
}

@MainActor
@Test("Pointer dispatch resolves current geometry after target activation")
func livePointerUsesGeometryAfterActivation() async throws {
    let target = PointerTargetFixture()
    let sink = PointerEventsFixture()
    _ = try await LivePointerExecutor.perform(
        .init(kind: .click, target: .init(pid: 123), point: .init(x: 0.25, y: 0.5), unlockForegroundActions: true),
        target: target, events: sink
    )
    #expect(sink.events == [
        .down(CGPoint(x: 450, y: 350), .left, 1),
        .up(CGPoint(x: 450, y: 350), .left, 1),
    ])
}

@MainActor
@Test("A drag stops on focus loss and releases the held button at its last position")
func livePointerDragStopsWhenHumanChangesFocus() async throws {
    let target = PointerTargetFixture()
    let sink = PointerEventsFixture()
    sink.duringPause = { target.active = false }
    do {
        _ = try await LivePointerExecutor.perform(
            .init(kind: .drag, target: .init(pid: 123), fromPoint: .init(x: 0, y: 0),
                  toPoint: .init(x: 1, y: 1), duration: 0.1, unlockForegroundActions: true),
            target: target, events: sink
        )
        Issue.record("Focus loss must interrupt the drag.")
    } catch {
        #expect(error.localizedDescription.contains("fixture focus changed"))
    }
    #expect(sink.events.count == 4)
    guard sink.events.count == 4, case .drag(let lastPoint, _) = sink.events[2] else { return }
    #expect(sink.events[3] == .up(lastPoint, .left, 1))
    #expect(lastPoint != CGPoint(x: 600, y: 400))
}

@MainActor
@Test("Focus changes between repeated clicks prevent the next click")
func livePointerRepeatedClickStopsWhenHumanChangesFocus() async throws {
    let target = PointerTargetFixture()
    let sink = PointerEventsFixture()
    sink.duringPause = { target.active = false }
    do {
        _ = try await LivePointerExecutor.perform(
            .init(kind: .click, target: .init(pid: 123), point: .init(x: 0.5, y: 0.5),
                  clickCount: 2, unlockForegroundActions: true),
            target: target, events: sink
        )
        Issue.record("Focus loss must interrupt repeated clicks.")
    } catch {
        #expect(error.localizedDescription.contains("fixture focus changed"))
    }
    #expect(sink.events.count == 2)
}

@MainActor
private final class WindowGeometryFixture: LivePointerGeometry {
    var selected: CGRect? = CGRect(x: 400, y: 300, width: 200, height: 100)
    func largestWindowFrame() -> CGRect? { CGRect(x: 0, y: 0, width: 1000, height: 1000) }
    func windowFrame(id: String) -> CGRect? { id == "selected" ? selected : nil }
    func currentFrame(id: String, windowID: String?) -> CGRect? {
        id == "selected-node" && windowID == "selected" ? selected : nil
    }
    func focusWindow(id: String) throws {}
    func isFocusedWindow(id: String) -> Bool { id == "selected" }
}

@MainActor
@Test("An explicit live window maps points to that window and never falls back after it closes")
func livePointerUsesExplicitWindowWithoutFallback() throws {
    let geometry = WindowGeometryFixture()
    let target = NativeLivePointerTarget(
        target: .init(pid: 42, bundleIdentifier: "example.fixture", name: "Fixture"),
        reader: geometry, windowID: "selected", activation: {}
    )
    #expect(try target.point(nodeID: nil, normalized: .init(x: 0.25, y: 0.5)) == CGPoint(x: 450, y: 350))
    #expect(try target.point(nodeID: "selected-node", normalized: nil) == CGPoint(x: 500, y: 350))
    geometry.selected = nil
    #expect(throws: RecordingError.self) { try target.point(nodeID: nil, normalized: .init(x: 0.25, y: 0.5)) }
}

@MainActor
@Test("Native focus loss reports an interruption while preserving uncertain partial effects")
func nativePointerFocusLossHasTypedInterruption() throws {
    let target = NativeLivePointerTarget(
        target: .init(pid: -1, bundleIdentifier: "example.absent", name: "Absent fixture"),
        reader: WindowGeometryFixture(), activation: {}
    )
    do {
        try target.requireActive()
        Issue.record("An absent target cannot own foreground input.")
    } catch {
        let failure = PabloControlFailure(afterDispatch: error)
        #expect(failure.code == .interrupted)
        #expect(failure.dispatchStatus == .outcomeUnknown)
    }
}
