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

    func testRequiresExactlyOneTarget() {
        XCTAssertThrowsError(try CLI.parse(["record"]))
        XCTAssertThrowsError(try CLI.parse(["record", "--app", "Notes", "--pid", "42"]))
    }

    func testParsesReplayCommands() throws {
        guard case .frames(nil, json: true) = try CLI.parse(["frames", "--json"]) else {
            return XCTFail("Expected frames command")
        }
        guard case .frame(let reference, nil, changedOnly: true, json: false) = try CLI.parse([
            "frame", "A11Y-012", "--changed",
        ]) else {
            return XCTFail("Expected frame command")
        }
        XCTAssertEqual(reference, "A11Y-012")
        guard case .events(nil, limit: 25, json: false) = try CLI.parse([
            "events", "--limit", "25",
        ]) else {
            return XCTFail("Expected events command")
        }
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
