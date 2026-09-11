import Foundation
import Testing
@testable import PabloCore

@Test("Observation settling restarts its quiet interval when the sampled state changes")
@MainActor
func liveObservationWaitsForQuietState() async throws {
    var time: UInt64 = 0
    var reads = 0
    let result = try await LiveObservationSampler.sample(
        options: .init(quietMilliseconds: 100, timeoutMilliseconds: 500),
        now: { time }, pause: { time += UInt64($0) }, read: {
            reads += 1
            return observationSample(title: time < 100 ? "Loading" : "Ready")
        })
    #expect(result.status == .settled)
    #expect(result.elapsedMilliseconds == 200)
    #expect(result.sampleCount == 5)
    #expect(reads == 5)
    #expect(result.tree.nodes["root"]?.title == "Ready")
}

@Test("Continuously changing observations return the final sampled state with timeout status")
@MainActor
func liveObservationReportsTimeout() async throws {
    var time: UInt64 = 0
    let result = try await LiveObservationSampler.sample(
        options: .init(quietMilliseconds: 100, timeoutMilliseconds: 200),
        now: { time }, pause: { time += UInt64($0) },
        read: { observationSample(title: String(time)) })
    #expect(result.status == .timedOut)
    #expect(result.elapsedMilliseconds == 200)
    #expect(result.tree.nodes["root"]?.title == "200")
    var reads = 0
    let immediate = try await LiveObservationSampler.sample(options: .init(quietMilliseconds: 0, timeoutMilliseconds: 0),
        now: { time }, pause: { _ in Issue.record("Immediate observations must not wait") },
        read: { reads += 1; return observationSample(title: "One") })
    #expect(immediate.status == .sampled)
    #expect(reads == 1)
}

@Test("Observation sampling stops after cancellation and never returns stale success")
@MainActor
func liveObservationCancellationStopsReads() async throws {
    var reads = 0
    do {
        _ = try await LiveObservationSampler.sample(options: .init(),
            pause: { _ in throw CancellationError() },
            read: { reads += 1; return observationSample(title: "Ready") })
        Issue.record("Cancellation must escape observation sampling")
    } catch is CancellationError {}
    #expect(reads == 1)
}

@Test("Screenshot matching requires one matching window owned by the selected process")
func liveScreenshotRejectsAmbiguousOrForeignWindows() throws {
    let frame = CGRect(x: 20, y: 30, width: 500, height: 400)
    let own = LiveScreenshotWindow(id: 10, pid: 42, frame: frame, title: "Document")
    let foreign = LiveScreenshotWindow(id: 11, pid: 43, frame: frame, title: "Document")
    #expect(try LiveScreenshotMatching.match(pid: 42, frame: frame, title: "Document", windows: [foreign, own]) == 10)
    #expect(throws: RecordingError.self) { try LiveScreenshotMatching.match(pid: 42, frame: frame, title: nil, windows: [foreign]) }
    #expect(throws: RecordingError.self) {
        try LiveScreenshotMatching.match(pid: 42, frame: frame, title: "Document", windows: [own, .init(id: 12, pid: 42, frame: frame, title: "Document")])
    }
    #expect(throws: RecordingError.self) {
        try LiveScreenshotMatching.match(pid: 42, frame: frame.offsetBy(dx: 1, dy: 0), title: "Document", windows: [own])
    }
}

private func observationSample(title: String) -> AXTreeSnapshot {
    .init(rootID: "root", nodes: ["root": .init(id: "root", parentID: nil, childIDs: [], role: "AXApplication",
        subrole: nil, title: title, label: nil, value: nil, identifier: nil, help: nil, enabled: true,
        focused: false, position: nil, size: nil)], truncated: false)
}
