import Foundation
import WebKit
import XCTest
@testable import PabloApp

@MainActor
final class RRWebPlaybackRendererTests: XCTestCase {
    func testPlayerReportsTimeAndStateThroughItsRealEventEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pablo-player-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["player.js", "player.css"] {
            try FileManager.default.copyItem(
                at: project.appendingPathComponent("Sources/PabloApp/Resources/RRWebPlayer/\(name)"),
                to: directory.appendingPathComponent(name)
            )
        }
        let events = Data(#"""
        [
          {"type":4,"timestamp":1000,"data":{"href":"https://example.com","width":800,"height":600}},
          {"type":2,"timestamp":1001,"data":{"node":{"type":0,"id":1,"childNodes":[{"type":2,"id":2,"tagName":"html","attributes":{},"childNodes":[{"type":2,"id":3,"tagName":"head","attributes":{},"childNodes":[]},{"type":2,"id":4,"tagName":"body","attributes":{},"childNodes":[{"type":3,"id":5,"textContent":"Replay test"}]}]}]},"initialOffset":{"left":0,"top":0}}},
          {"type":5,"timestamp":11000,"data":{"tag":"end","payload":{}}}
        ]
        """#.utf8)
        let html = directory.appendingPathComponent("index.html")
        try RRWebPlayerWebView.playerHTML(events: events).write(to: html, atomically: true, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadFileURL(html, allowingReadAccessTo: directory)
        try await waitUntil(view, expression: "!!window.pabloPlayer")
        let initiallyPlaying = try await evaluate(view, "window.pabloPlaying") as? Bool
        XCTAssertEqual(initiallyPlaying, false)

        _ = try await evaluate(view, "window.pabloPlayer.goto(1250, false); true")
        try await waitUntil(view, expression: "window.pabloTime === 1250")
        _ = try await evaluate(view, "window.pabloPlayer.play(); true")
        try await waitUntil(view, expression: "window.pabloPlaying === true")
        _ = try await evaluate(view, "window.pabloPlayer.pause(); true")
        try await waitUntil(view, expression: "window.pabloPlaying === false")
        let time = try await evaluate(view, "window.pabloTime / 1000") as? Double
        XCTAssertNotNil(time)
        XCTAssertTrue(time?.isFinite == true)
        XCTAssertGreaterThanOrEqual(time ?? 0, 1.25)
    }

    private func evaluate(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func waitUntil(_ view: WKWebView, expression: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await evaluate(view, expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Player did not reach expected state: \(expression)")
        throw NSError(domain: "RRWebPlaybackRendererTests", code: 1)
    }
}
