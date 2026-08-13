import XCTest
@testable import PabloCore

final class CLITests: XCTestCase {
    func testParsesRecordOptions() throws {
        guard case .record(let options) = try CLI.parse([
            "record", "--bundle-id", "com.example.App", "--duration", "2.5", "--no-text",
        ]) else {
            return XCTFail("Expected record command")
        }
        XCTAssertEqual(options.bundleIdentifier, "com.example.App")
        XCTAssertEqual(options.duration, 2.5)
        XCTAssertFalse(options.captureText)
    }

    func testRequiresOneRecordingScope() {
        XCTAssertThrowsError(try CLI.parse(["record"]))
        XCTAssertThrowsError(try CLI.parse(["record", "--app", "Notes", "--pid", "42"]))
        XCTAssertThrowsError(try CLI.parse(["record", "--screen", "--app", "Notes"]))
    }

    func testParsesDisplayRecordingWithoutAnApplicationSelector() throws {
        guard case .record(let options) = try CLI.parse([
            "record", "--screen", "--display-id", "7", "--fps", "24",
        ]) else {
            return XCTFail("Expected record command")
        }
        XCTAssertEqual(options.scope, .display)
        XCTAssertEqual(options.displayID, 7)
        XCTAssertNil(options.pid)
        XCTAssertNil(options.bundleIdentifier)
        XCTAssertNil(options.appName)
        XCTAssertEqual(options.framesPerSecond, 24)
    }

    func testParsesReplayCommands() throws {
        guard case .workspace(recording: nil, json: true) = try CLI.parse(["workspace", "--json"]) else {
            return XCTFail("Expected workspace command")
        }
        guard case .frames(let frameSource, json: true) = try CLI.parse(["frames", "--json"]) else {
            return XCTFail("Expected frames command")
        }
        XCTAssertEqual(frameSource, .recording(nil))
        guard case .frame(let reference, let source, changedOnly: true, json: false) = try CLI.parse([
            "frame", "A11Y-012", "--changed",
        ]) else {
            return XCTFail("Expected frame command")
        }
        XCTAssertEqual(reference, "A11Y-012")
        XCTAssertEqual(source, .recording(nil))
        guard case .events(let eventSource, limit: 25, json: false) = try CLI.parse([
            "events", "--limit", "25",
        ]) else {
            return XCTFail("Expected events command")
        }
        XCTAssertEqual(eventSource, .recording(nil))
        guard case .annotations(let annotationSource, json: true) = try CLI.parse([
            "annotations", "--json",
        ]) else {
            return XCTFail("Expected annotations command")
        }
        XCTAssertEqual(annotationSource, .recording(nil))
    }

    func testParsesEveryLiveInspectionCommand() throws {
        let target = PabloLiveApplicationTarget(appName: "Notes")

        guard case .inspect(.live(let inspectTarget)) = try CLI.parse(["inspect", "--app", "Notes"]) else {
            return XCTFail("Expected live inspect command")
        }
        XCTAssertEqual(inspectTarget, target)
        guard case .frames(.live(let framesTarget), json: true) = try CLI.parse([
            "frames", "--app", "Notes", "--json",
        ]) else {
            return XCTFail("Expected live frames command")
        }
        XCTAssertEqual(framesTarget, target)
        guard case .frame(
            reference: "A11Y-001",
            source: .live(let frameTarget),
            changedOnly: true,
            json: false
        ) = try CLI.parse(["frame", "A11Y-001", "--app", "Notes", "--changed"]) else {
            return XCTFail("Expected live frame command")
        }
        XCTAssertEqual(frameTarget, target)
        guard case .events(.live(let eventsTarget), limit: 25, json: false) = try CLI.parse([
            "events", "--app", "Notes", "--limit", "25",
        ]) else {
            return XCTFail("Expected live events command")
        }
        XCTAssertEqual(eventsTarget, target)
        guard case .annotations(.live(let annotationsTarget), json: true) = try CLI.parse([
            "annotations", "--app", "Notes", "--json",
        ]) else {
            return XCTFail("Expected live annotations command")
        }
        XCTAssertEqual(annotationsTarget, target)
    }

    func testLiveInspectionRejectsAmbiguousSources() {
        XCTAssertThrowsError(try CLI.parse([
            "frames", "session.pablo", "--app", "Notes",
        ]))
        XCTAssertThrowsError(try CLI.parse([
            "events", "--pid", "42", "--bundle-id", "com.example.App",
        ]))
        XCTAssertThrowsError(try CLI.parse(["inspect", "--pid", "zero"]))
    }

    func testParsesEveryLiveActionCommand() throws {
        let target = PabloLiveApplicationTarget(appName: "Notes")

        let click = try liveAction(["click", "--app", "Notes", "--node", "ax-save", "--button", "right", "--count", "2"])
        XCTAssertEqual(click.kind, .click)
        XCTAssertEqual(click.target, target)
        XCTAssertEqual(click.nodeID, "ax-save")
        XCTAssertEqual(click.mouseButton, .right)
        XCTAssertEqual(click.clickCount, 2)

        let drag = try liveAction([
            "drag", "--app", "Notes", "--from", "0.1,0.2", "--to", "0.8,0.9",
            "--duration", "1.25",
        ])
        XCTAssertEqual(drag.kind, .drag)
        XCTAssertEqual(drag.fromPoint, PabloLivePoint(x: 0.1, y: 0.2))
        XCTAssertEqual(drag.toPoint, PabloLivePoint(x: 0.8, y: 0.9))
        XCTAssertEqual(drag.duration, 1.25)

        let scroll = try liveAction([
            "scroll", "--app", "Notes", "--direction", "down", "--amount", "8",
            "--node", "ax-list",
        ])
        XCTAssertEqual(scroll.kind, .scroll)
        XCTAssertEqual(scroll.scrollDirection, .down)
        XCTAssertEqual(scroll.scrollAmount, 8)
        XCTAssertEqual(scroll.nodeID, "ax-list")

        let type = try liveAction([
            "type", "--app", "Notes", "--node", "ax-editor", "--text", "Hello",
        ])
        XCTAssertEqual(type.kind, .typeText)
        XCTAssertEqual(type.nodeID, "ax-editor")
        XCTAssertEqual(type.text, "Hello")

        let key = try liveAction([
            "key", "--app", "Notes", "--key", "return", "--modifiers", "command,shift",
        ])
        XCTAssertEqual(key.kind, .key)
        XCTAssertEqual(key.key, "return")
        XCTAssertEqual(key.modifiers, [.command, .shift])

        let perform = try liveAction([
            "perform", "--app", "Notes", "--node", "ax-save", "--action", "press",
        ])
        XCTAssertEqual(perform.kind, .perform)
        XCTAssertEqual(perform.nodeID, "ax-save")
        XCTAssertEqual(perform.accessibilityAction, "press")
    }

    func testLiveActionsRejectInvalidOrIncompleteArguments() {
        XCTAssertThrowsError(try CLI.parse(["click", "--node", "ax-save"]))
        XCTAssertThrowsError(try CLI.parse([
            "click", "--app", "Notes", "--node", "ax-save", "--point", "0.5,0.5",
        ]))
        XCTAssertThrowsError(try CLI.parse([
            "drag", "--app", "Notes", "--from", "0.1,0.2", "--to", "2,0.5",
        ]))
        XCTAssertThrowsError(try CLI.parse([
            "scroll", "--app", "Notes", "--amount", "101", "--direction", "down",
        ]))
        XCTAssertThrowsError(try CLI.parse(["type", "--app", "Notes", "--text", ""]))
        XCTAssertThrowsError(try CLI.parse([
            "key", "--app", "Notes", "--key", "return", "--modifiers", "hyper",
        ]))
        XCTAssertThrowsError(try CLI.parse([
            "perform", "--app", "Notes", "--node", "ax-save",
        ]))
    }

    private func liveAction(_ arguments: [String]) throws -> PabloLiveActionRequest {
        guard case .liveAction(let action) = try CLI.parse(arguments) else {
            throw RecordingError.usage("Expected live action command")
        }
        return action
    }

    func testParsesAnnotationCommands() throws {
        guard case .annotate(let options) = try CLI.parse([
            "annotate", "session.pablo", "--kind", "issue", "--text", "Disabled",
            "--frame", "A11Y-012", "--node", "submit", "--line-width", "0.012",
            "--trace", "2.5,0.1,0.2", "--trace", "3.5,0.3,0.4",
        ]) else {
            return XCTFail("Expected annotate command")
        }
        XCTAssertEqual(options.recordingURL?.lastPathComponent, "session.pablo")
        XCTAssertEqual(options.kind, .issue)
        XCTAssertEqual(options.text, "Disabled")
        XCTAssertEqual(options.accessibilityReferences, ["A11Y-012"])
        XCTAssertEqual(options.accessibilityNodeIDs, ["submit"])
        XCTAssertEqual(options.lineWidth, 0.012)
        XCTAssertEqual(options.tracePoints, [
            AnnotationTracePoint(videoTime: 2.5, x: 0.1, y: 0.2),
            AnnotationTracePoint(videoTime: 3.5, x: 0.3, y: 0.4),
        ])

        guard case .annotate(let pointOptions) = try CLI.parse([
            "annotate", "--text", "One-frame point", "--point", "0.4,0.6", "--at", "1.25",
        ]) else {
            return XCTFail("Expected point annotation")
        }
        XCTAssertEqual(pointOptions.point, AnnotationPoint(x: 0.4, y: 0.6))
        XCTAssertEqual(pointOptions.at, 1.25)

        guard case .resolveAnnotation(let reference, let recording) = try CLI.parse([
            "resolve", "NOTE-007", "session.pablo",
        ]) else {
            return XCTFail("Expected resolve command")
        }
        XCTAssertEqual(reference, "NOTE-007")
        XCTAssertEqual(recording?.lastPathComponent, "session.pablo")

        XCTAssertThrowsError(try CLI.parse(["annotate", "--text", "Missing range end", "--from", "1"]))
        XCTAssertThrowsError(try CLI.parse(["annotate", "--text", "Bad point", "--point", "0,2", "--at", "1"]))
        XCTAssertThrowsError(try CLI.parse([
            "annotate", "--text", "Backward trace",
            "--trace", "2,0.1,0.1", "--trace", "1,0.2,0.2",
        ]))
    }

    func testParsesAppControlCommandsWithoutArguments() throws {
        guard case .status = try CLI.parse(["status"]) else {
            return XCTFail("Expected status command")
        }
        guard case .pause = try CLI.parse(["pause"]) else {
            return XCTFail("Expected pause command")
        }
        guard case .resume = try CLI.parse(["resume"]) else {
            return XCTFail("Expected resume command")
        }
        guard case .stop = try CLI.parse(["stop"]) else {
            return XCTFail("Expected stop command")
        }
        XCTAssertThrowsError(try CLI.parse(["status", "extra"]))
    }
}
